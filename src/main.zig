const std = @import("std");
const ExitCode = @import("exitCode.zig").ExitCode;
const Options = @import("options.zig").Options;
const Colors = @import("options.zig").Colors;
const FieldType = @import("options.zig").FieldType;
const ArgumentParser = @import("arguments.zig").Parser;
const config = @import("config.zig");
const FileReader = @import("FileReader.zig");
const LineSet = @import("LineSet.zig");
const FieldSet = @import("FieldSet.zig");
const CsvLine = @import("CsvLine.zig");
const builtin = @import("builtin");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    _main(allocator) catch |err| switch (err) {
        error.OutOfMemory => ExitCode.outOfMemory.printErrorAndExit(.{}),
        else => ExitCode.genericError.printErrorAndExit(.{err}),
    };
}

fn _main(allocator: std.mem.Allocator) !void {
    var timer = try std.time.Timer.start();

    var options = try Options.init(allocator);
    defer options.deinit();

    if (config.readConfigFromFile("default.config", allocator) catch null) |defaultArguments| {
        try ArgumentParser.parse(&options, defaultArguments.items, allocator);
    }
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const arguments = try castArgs(args, allocator);
    defer allocator.free(arguments);

    try ArgumentParser.parse(&options, arguments, allocator);
    try ArgumentParser.validateArguments(&options);

    try doDiff(&options, allocator);

    if (options.time) {
        const timeNeeded = @as(f32, @floatFromInt(timer.lap())) / 1000000.0;
        const stderr = std.io.getStdOut().writer();
        if (timeNeeded > 1000) {
            _ = try stderr.print("time needed: {d:0.2}s\n", .{timeNeeded / 1000.0});
        } else {
            _ = try stderr.print("time needed: {d:0.2}ms\n", .{timeNeeded});
        }
    }
}

fn castArgs(args: [][:0]u8, allocator: std.mem.Allocator) ![][]const u8 {
    var ret = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        ret[i] = arg[0..];
    }
    return ret;
}

fn doDiff(options: *Options, allocator: std.mem.Allocator) !void {
    var bufferedWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer bufferedWriter.flush() catch {};
    const writer = bufferedWriter.writer().any();

    if (options.listHeader) {
        try listHeader(options, allocator);
    } else if (options.keyFields == null) {
        try lineDiff(options, writer, allocator);
    } else {
        try keyDiff(options, writer, allocator);
    }
}

fn listHeader(options: *Options, allocator: std.mem.Allocator) !void {
    var csvLine = try CsvLine.init(allocator, .{ .separator = options.inputSeparator[0], .trim = options.trim, .quoute = if (options.inputQuoute) |quote| quote[0] else null });
    defer csvLine.deinit();
    var file = try FileReader.init(options.inputFiles.items[0]);
    defer file.deinit();

    const writer = std.io.getStdOut().writer();
    if (try file.getLine()) |line| {
        const fields = try csvLine.parse(line);
        for (fields, 1..) |field, i| {
            _ = try writer.print("{d}: {s}\n", .{ i, field });
        }
    }
}

fn lineDiff(options: *Options, writer: std.io.AnyWriter, allocator: std.mem.Allocator) !void {
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    var fileB = try FileReader.init(options.inputFiles.items[1]);
    defer fileB.deinit();

    var lineSet = try LineSet.init(try fileA.getAproximateLineCount(100), allocator);
    defer lineSet.deinit();
    while (try fileA.getLine()) |line| {
        try lineSet.put(line);
    }

    if (options.asCsv and options.fileHeader) {
        if (try fileB.getLine()) |header| {
            _ = try writer.print("DIFF{c}{s}\n", .{ options.diffSpaceing, header });
        }
        fileB.reset();
    }

    const color = options.getColors();

    while (try fileB.getLine()) |line| {
        if (lineSet.get(line)) |entry| {
            if (entry.count > 0) {
                if (options.outputAll) {
                    _ = try writer.print(" {c}{s}\n", .{ options.diffSpaceing, line });
                }
                entry.count -= 1;
            } else {
                _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
            }
        } else {
            _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
        }
    }

    for (lineSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("{s}-{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.reset });
            }
        }
    }
}

fn keyDiff(options: *Options, writer: std.io.AnyWriter, allocator: std.mem.Allocator) !void {
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    var fileB = try FileReader.init(options.inputFiles.items[1]);
    defer fileB.deinit();

    var csvLine = try CsvLine.init(allocator, .{ .separator = options.inputSeparator[0], .trim = options.trim, .quoute = if (options.inputQuoute) |quote| quote[0] else null });
    defer csvLine.deinit();

    if (options.fileHeader) {
        if (try fileA.getLine()) |line| {
            try options.setHeaderFields(try csvLine.parse(line));
        }
    }
    try options.calculateFieldIndices();

    var fieldSet = try FieldSet.init(try fileA.getAproximateLineCount(10000), options.keyIndices.?, options.valueIndices.?, csvLine, allocator);
    defer fieldSet.deinit();

    if (options.fileHeader) {
        _ = try fileA.getLine(); //skip header;
    }

    while (try fileA.getLine()) |line| {
        try fieldSet.put(line);
    }

    if (options.fileHeader) {
        const header = try fileB.getLine(); //skip header;
        if (options.asCsv and header != null) {
            _ = try writer.print("DIFF{c}{s}\n", .{ options.diffSpaceing, header.? });
        }
    }

    if (options.fieldDiff) {
        var csvLineB = try CsvLine.init(allocator, .{ .separator = options.inputSeparator[0], .trim = options.trim, .quoute = if (options.inputQuoute) |quote| quote[0] else null });
        defer csvLineB.deinit();
        try keyDiffPerField(&fileB, &fieldSet, writer, options, &csvLine, &csvLineB);
    } else {
        try keyDiffPerLine(&fileB, &fieldSet, writer, options);
    }
}

fn keyDiffPerLine(fileB: *FileReader, fieldSet: *FieldSet, writer: std.io.AnyWriter, options: *Options) !void {
    const color = options.getColors();
    while (try fileB.getLine()) |line| {
        if (try fieldSet.get(line)) |entry| {
            if (entry.count > 0) {
                if (!try fieldSet.valueMatches(entry, line)) {
                    _ = try writer.print("{s}<{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.reset });
                    _ = try writer.print("{s}>{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
                } else if (options.outputAll) {
                    _ = try writer.print(" {c}{s}\n", .{ options.diffSpaceing, entry.line.? });
                }
                entry.count -= 1;
            } else {
                _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
            }
        } else {
            _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
        }
    }

    for (fieldSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("{s}-{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.green });
            }
        }
    }
}

fn keyDiffPerField(fileB: *FileReader, fieldSet: *FieldSet, writer: std.io.AnyWriter, options: *Options, csvLineA: *CsvLine, csvLineB: *CsvLine) !void {
    const color = options.getColors();
    while (try fileB.getLine()) |line| {
        if (try fieldSet.get(line)) |entry| {
            if (entry.count > 0) {
                if (!try fieldSet.valueMatches(entry, line)) {
                    _ = try writer.print("{s}~{s}{c}", .{ color.blue, color.reset, options.diffSpaceing });
                    const fieldsA = try csvLineA.parse(entry.line.?);
                    const fieldsB = try csvLineB.parse(line);
                    for (fieldsA, 0..) |fieldA, index| {
                        const fieldB = fieldsB[index];
                        switch (options.fieldTypes.?[index]) {
                            .KEY => {
                                _ = try writer.print("{s}{s}{s}", .{ color.blue, fieldA, color.reset });
                            },
                            .VALUE => {
                                if (std.mem.eql(u8, fieldA, fieldB)) {
                                    _ = try writer.print("{s}{s}{s}", .{ color.blue, fieldA, color.reset });
                                } else {
                                    _ = try writer.print("{s}{s}|{s}{s}{s}", .{ color.red, fieldA, color.green, fieldB, color.reset });
                                }
                            },
                            .EXCLUDED => {
                                _ = try writer.print("{s}", .{fieldB});
                            },
                        }
                        if (index < fieldsA.len - 1) {
                            _ = try writer.print("{c}", .{options.inputSeparator[0]});
                        }
                    }
                    _ = try writer.print("\n", .{});
                } else if (options.outputAll) {
                    _ = try writer.print(" {c}{s}\n", .{ options.diffSpaceing, line });
                }
                entry.count -= 1;
            } else {
                _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
            }
        } else {
            _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
        }
    }

    for (fieldSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("{s}-{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.reset });
            }
        }
    }
}

// Test
const testing = std.testing;
const NO_DIFF = "";

const TestRun = struct {
    output: std.ArrayList(u8),
    options: Options,
    expected: []const u8,

    fn init(comptime file1: []const u8, comptime file2: []const u8, comptime expected: []const u8) !TestRun {
        var testRun: TestRun = .{
            .output = std.ArrayList(u8).init(testing.allocator),
            .options = try Options.init(testing.allocator),
            .expected = @embedFile("test/" ++ expected),
        };
        try testRun.options.inputFiles.append("./src/test/" ++ file1);
        try testRun.options.inputFiles.append("./src/test/" ++ file2);
        return testRun;
    }

    fn writer(self: *TestRun) !std.io.AnyWriter {
        return self.output.writer().any();
    }

    fn runLineDiff(self: *TestRun) !void {
        defer self.deinit();
        try lineDiff(&self.options, self.output.writer().any(), testing.allocator);
        try testing.expectEqualStrings(self.expected, self.output.items);
    }

    fn runKeyDiff(self: *TestRun) !void {
        defer self.deinit();
        try keyDiff(&self.options, self.output.writer().any(), testing.allocator);
        try testing.expectEqualStrings(self.expected, self.output.items);
    }

    fn deinit(self: *TestRun) void {
        self.output.deinit();
        self.options.deinit();
    }
};

test "lineDiff with equal files" {
    var testRun = try TestRun.init("people.csv", "people.csv", "empty");
    try testRun.runLineDiff();
}

test "lineDiff with more lines" {
    var testRun = try TestRun.init("people.csv", "morePeople.csv", "expect_diff_people_vs_morePeople");
    try testRun.runLineDiff();
}

test "lineDiff with less lines" {
    var testRun = try TestRun.init("people.csv", "lessPeople.csv", "expect_diff_people_vs_lessPeople");
    try testRun.runLineDiff();
}

test "lineDiff with equal duplicate lines" {
    var testRun = try TestRun.init("duplicatePeople.csv", "duplicatePeople.csv", "empty");
    try testRun.runLineDiff();
}

test "lineDiff with added/removeed/changed lines" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_lineDiff_people_vs_differentPeople");
    try testRun.runLineDiff();
}

test "lineDiff with added/removeed/changed lines asCsv" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_lineDiff_people_vs_differentPeople_asCsv");
    testRun.options.setAsCsv(true);
    try testRun.runLineDiff();
}

test "lineDiff with added/removeed/changed lines output all lines" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_lineDiff_people_vs_differentPeople_all");
    testRun.options.outputAll = true;
    try testRun.runLineDiff();
}

test "keyDiff with equal files" {
    var testRun = try TestRun.init("people.csv", "people.csv", "empty");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff with more lines" {
    var testRun = try TestRun.init("people.csv", "morePeople.csv", "expect_diff_people_vs_morePeople");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff with less lines" {
    var testRun = try TestRun.init("people.csv", "lessPeople.csv", "expect_diff_people_vs_lessPeople");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff with equal duplicate lines" {
    var testRun = try TestRun.init("duplicatePeople.csv", "duplicatePeople.csv", "empty");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff with added/removeed/changed lines with index key" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff with added/removeed/changed lines asCsv" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople_asCsv");
    try testRun.options.addKey("1");
    testRun.options.setAsCsv(true);
    try testRun.runKeyDiff();
}

test "keyDiff with added/removeed/changed lines outputAll" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople_all");
    try testRun.options.addKey("1");
    testRun.options.outputAll = true;
    try testRun.runKeyDiff();
}

test "keyDiff with added/removeed/changed lines with named key" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople");
    try testRun.options.addKey("Customer Id");
    try testRun.runKeyDiff();
}

test "keyDiff with added/removeed/changed lines with 2 named keys" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople_2_keys");
    try testRun.options.addKey("Customer Id,Last Name");
    try testRun.runKeyDiff();
}

test "keyDiff with added/removeed/changed lines fieldDiff" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople_fieldDiff");
    try testRun.options.addKey("1");
    testRun.options.fieldDiff = true;
    try testRun.runKeyDiff();
}

test "keyDiff with added/removeed/changed lines outputAll fieldDiff" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople_all_fieldDiff");
    try testRun.options.addKey("1");
    testRun.options.fieldDiff = true;
    testRun.options.outputAll = true;
    try testRun.runKeyDiff();
}

test {
    std.testing.refAllDecls(@This());
}
