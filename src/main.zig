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

    const stderr = std.io.getStdOut().writer();

    if (options.stats) {
        try stats.print(options.inputFiles, stderr);
    }

    if (options.time) {
        const timeNeeded = @as(f32, @floatFromInt(timer.lap())) / 1000000.0;
        if (timeNeeded > 1000) {
            _ = try stderr.print("time needed: {d:0.2}s\n", .{timeNeeded / 1000.0});
        } else {
            _ = try stderr.print("time needed: {d:0.2}ms\n", .{timeNeeded});
        }
    }
}

var stats: Stats = Stats.init();

const Stats = struct {
    linesA: usize = 0,
    linesB: usize = 0,
    equal: usize = 0,
    added: usize = 0,
    removed: usize = 0,
    changed: usize = 0,

    fn init() Stats {
        return .{};
    }

    fn print(self: Stats, inputFiles: std.ArrayList([]const u8), writer: std.io.AnyWriter) !void {
        _ = try writer.print("\n", .{});
        _ = try writer.print("[Stats]\n", .{});
        _ = try writer.print("fileA: {s}\n", .{inputFiles.items[0]});
        _ = try writer.print("fileB: {s}\n", .{inputFiles.items[1]});
        _ = try writer.print("\n", .{});
        _ = try writer.print("linesA:  {d: >13}\n", .{self.linesA});
        _ = try writer.print("linesB:  {d: >13}\n", .{self.linesA});
        _ = try writer.print("\n", .{});
        _ = try writer.print("equal:   {d: >13}\n", .{self.equal});
        _ = try writer.print("added:   {d: >13}\n", .{self.added});
        _ = try writer.print("removed: {d: >13}\n", .{self.removed});
        _ = try writer.print("changed: {d: >13}\n", .{self.changed});
    }
};

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

    if (options.asCsv) {
        if (options.header != null) {
            try writeHeader(options, writer);
        } else if (options.fileHeader) {
            if (try fileA.getLine()) |header| {
                _ = try writer.print("DIFF{c}{s}\n", .{ options.inputSeparator[0], header });
            }
            _ = try fileB.getLine();
        }
    }

    while (try fileA.getLine()) |line| {
        try lineSet.put(line);
    }
    stats.linesA = fileA.lines;

    const color = options.getColors();

    while (try fileB.getLine()) |line| {
        if (lineSet.get(line)) |entry| {
            if (entry.count > 0) {
                if (options.outputAll) {
                    _ = try writer.print("={c}{s}\n", .{ options.diffSpaceing, line });
                }
                entry.count -= 1;
                stats.equal += 1;
            } else {
                _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
                stats.added += 1;
            }
        } else {
            _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
            stats.added += 1;
        }
    }
    stats.linesB = fileB.lines;

    for (lineSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("{s}-{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.reset });
                stats.removed += 1;
            }
        }
    }
}

fn writeHeader(options: *Options, writer: std.io.AnyWriter) !void {
    _ = try writer.print("DIFF", .{});
    for (options.header.?) |field| {
        _ = try writer.print("{c}{s}", .{ options.inputSeparator[0], field });
    }
    _ = try writer.print("\n", .{});
}

fn keyDiff(options: *Options, writer: std.io.AnyWriter, allocator: std.mem.Allocator) !void {
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    var fileB = try FileReader.init(options.inputFiles.items[1]);
    defer fileB.deinit();

    var csvLine = try CsvLine.init(allocator, .{ .separator = options.inputSeparator[0], .trim = options.trim, .quoute = if (options.inputQuoute) |quote| quote[0] else null });
    defer csvLine.deinit();

    if (options.header == null) {
        if (try fileA.getLine()) |line| {
            try options.setHeaderFields(try csvLine.parse(line));
        }
        if (try fileB.getLine()) |line| {
            const header = try csvLine.parse(line);
            if (options.header.?.len != header.len) {
                return error.differentHeaderLenghts;
            }
        }
    }

    if (options.asCsv and options.header != null) {
        try writeHeader(options, writer);
    }

    try options.calculateFieldIndices();

    var fieldSet = try FieldSet.init(try fileA.getAproximateLineCount(10000), options.keyIndices.?, options.valueIndices.?, csvLine, allocator);
    defer fieldSet.deinit();

    if (options.fileHeader and options.asCsv) {
        _ = try fileA.getLine(); //skip header
    } else {
        fileB.reset();
    }

    while (try fileA.getLine()) |line| {
        try fieldSet.put(line);
    }
    stats.linesA = fileA.lines;

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
                    stats.changed += 1;
                } else {
                    if (options.outputAll) {
                        _ = try writer.print("={c}{s}\n", .{ options.diffSpaceing, entry.line.? });
                    }
                    stats.equal += 1;
                }
                entry.count -= 1;
            } else {
                _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
                stats.added += 1;
            }
        } else {
            _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
            stats.added += 1;
        }
        stats.linesB += 1;
    }

    for (fieldSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("{s}-{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.green });
                stats.removed += 1;
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
                                    _ = try writer.print("{s}", .{fieldA});
                                } else {
                                    _ = try writer.print("{s}{s}{s}/{s}{s}{s}", .{ color.red, fieldA, color.reset, color.green, fieldB, color.reset });
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
                    stats.changed += 1;
                } else {
                    if (options.outputAll) {
                        _ = try writer.print("={c}{s}\n", .{ options.diffSpaceing, line });
                    }
                    stats.equal += 1;
                }
                entry.count -= 1;
            } else {
                _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
                stats.added += 1;
            }
        } else {
            _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
            stats.added += 1;
        }
    }
    stats.linesB += 1;

    for (fieldSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("{s}-{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.reset });
                stats.removed += 1;
            }
        }
    }
}

// Test
const testing = std.testing;

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

test "lineDiff pople vs people with more columns" {
    var testRun = try TestRun.init("people.csv", "peopleMoreColumns.csv", "expect_lineDiff_people_vs_people_with_more_columns");
    try testRun.runLineDiff();
}

test "lineDiff people with more columns vs people" {
    var testRun = try TestRun.init("peopleMoreColumns.csv", "people.csv", "expect_lineDiff_people_with_more_columns_vs_people");
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

test "keyDiff with added/removeed/changed lines without header" {
    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople");
    try testRun.options.addKey("1");
    testRun.options.fileHeader = false;
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

test "keyDiff pople vs people with more columns" {
    var testRun = try TestRun.init("people.csv", "peopleMoreColumns.csv", "empty");
    try testRun.options.addKey("1");
    try testing.expectError(error.differentHeaderLenghts, testRun.runKeyDiff());
}

test "keyDiff people with more columns vs people" {
    var testRun = try TestRun.init("peopleMoreColumns.csv", "people.csv", "empty");
    try testRun.options.addKey("1");
    try testing.expectError(error.differentHeaderLenghts, testRun.runKeyDiff());
}

test "keyDiff with no header and diff in 1st line" {
    var testRun = try TestRun.init("people.csv", "peoplewithDifferentHeader.csv", "expect_keyDiff_people_vs_peoplewithDifferentHeader");
    try testRun.options.addKey("1");
    testRun.options.fieldDiff = true;
    testRun.options.outputAll = true;
    testRun.options.fileHeader = false;
    try testRun.runKeyDiff();
}

test "keyDiff with given header csv output" {
    var testRun = try TestRun.init("people.csv", "peoplewithDifferentHeader.csv", "expect_keyDiff_with_given_header_csv_output");
    try testRun.options.addKey("A");
    try testRun.options.setHeader("A,B,C");
    testRun.options.fileHeader = false;
    testRun.options.setAsCsv(true);
    testRun.options.fieldDiff = true;
    try testRun.runKeyDiff();
}

test {
    std.testing.refAllDecls(@This());
}
