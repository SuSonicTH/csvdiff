const std = @import("std");
const runtime = @import("runtime.zig");
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

pub fn main(init: std.process.Init) !void {
    runtime.io = init.io;
    runtime.allocator = init.arena.allocator();
    runtime.environ = init.environ_map;

    _main(init) catch |err| switch (err) {
        error.OutOfMemory => ExitCode.outOfMemory.printErrorAndExit(.{}),
        error.InvalidFieldSelection => ExitCode.invalidFieldSelection.printErrorAndExit(.{}),
        error.NoSuchField => ExitCode.noSuchField.printErrorAndExit(.{}),
        error.NoHeader => ExitCode.noHeader.printErrorAndExit(.{}),
        error.differentHeaderLengths => ExitCode.differentHeaderLengths.printErrorAndExit(.{}),
        else => ExitCode.genericError.printErrorAndExit(.{err}),
    };
}

fn _main(init: std.process.Init) !void {
    const allocator = runtime.allocator;
    const timerStart = std.Io.Clock.awake.now(runtime.io);

    var options = try Options.init(allocator);
    defer options.deinit();

    if (config.readConfigFromFile(runtime.io, init.environ_map, "default.config", allocator) catch null) |defaultArguments| {
        try ArgumentParser.parse(&options, defaultArguments.items, allocator);
    }
    const args = try init.minimal.args.toSlice(allocator);
    const arguments = try castArgs(args, allocator);
    defer allocator.free(arguments);

    try ArgumentParser.parse(&options, arguments, allocator);
    try options.finalize();
    try ArgumentParser.validateArguments(&options);

    try doDiff(&options, allocator);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(runtime.io, &stderr_buffer);
    var stderr = &stderr_writer.interface;

    if (options.stats) {
        try stats.print(options.inputFiles, stderr);
    }

    if (options.time) {
        const elapsed = timerStart.durationTo(std.Io.Clock.awake.now(runtime.io));
        const timeNeeded = @as(f32, @floatFromInt(elapsed.toNanoseconds())) / 1000000.0;

        if (timeNeeded > 1000) {
            _ = try stderr.print("time needed: {d:0.2}s\n", .{timeNeeded / 1000.0});
        } else {
            _ = try stderr.print("time needed: {d:0.2}ms\n", .{timeNeeded});
        }
    }
    try stderr.flush();

    if (stats.hasDifferences()) {
        try ExitCode.differencesFound.exit();
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

    fn hasDifferences(self: Stats) bool {
        return self.added > 0 or self.removed > 0 or self.changed > 0;
    }

    fn print(self: Stats, inputFiles: std.array_list.Managed([]const u8), writer: *std.Io.Writer) !void {
        _ = try writer.print("\n", .{});
        _ = try writer.print("[Stats]\n", .{});
        if (inputFiles.items.len > 0) {
            _ = try writer.print("fileA: {s}\n", .{inputFiles.items[0]});
        }
        if (inputFiles.items.len > 1) {
            _ = try writer.print("fileB: {s}\n", .{inputFiles.items[1]});
        }
        _ = try writer.print("\n", .{});
        _ = try writer.print("linesA:  {d: >13}\n", .{self.linesA});
        _ = try writer.print("linesB:  {d: >13}\n", .{self.linesB});
        _ = try writer.print("\n", .{});
        _ = try writer.print("equal:   {d: >13}\n", .{self.equal});
        _ = try writer.print("added:   {d: >13}\n", .{self.added});
        _ = try writer.print("removed: {d: >13}\n", .{self.removed});
        _ = try writer.print("changed: {d: >13}\n", .{self.changed});
    }
};

fn castArgs(args: []const [:0]const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var ret = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        ret[i] = arg[0..];
    }
    return ret;
}

fn doDiff(options: *Options, allocator: std.mem.Allocator) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(runtime.io, &stdout_buffer);
    var stdout = &stdout_writer.interface;

    if (options.listHeader) {
        try listHeader(options, stdout, allocator);
    } else if (options.keyFields == null) {
        try lineDiff(options, stdout, allocator);
    } else {
        try keyDiff(options, stdout, allocator);
    }
    try stdout.flush();
}

fn listHeader(options: *Options, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    var csvLine = try CsvLine.init(allocator, .{ .separator = options.inputSeparator[0], .trim = options.trim, .quote = if (options.inputQuote) |quote| quote[0] else null });
    defer csvLine.deinit();
    var file = try FileReader.init(options.inputFiles.items[0]);
    defer file.deinit();

    if (try file.getLine()) |line| {
        const fields = try csvLine.parse(line);
        for (fields, 1..) |field, i| {
            _ = try writer.print("{d}: {s}\n", .{ i, field });
        }
    }
}

fn lineDiff(options: *Options, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
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

fn writeHeader(options: *Options, writer: *std.Io.Writer) !void {
    const header = options.header orelse return;
    _ = try writer.print("DIFF", .{});
    for (header) |field| {
        _ = try writer.print("{c}{s}", .{ options.inputSeparator[0], field });
    }
    _ = try writer.print("\n", .{});
}

fn keyDiff(options: *Options, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    var fileB = try FileReader.init(options.inputFiles.items[1]);
    defer fileB.deinit();

    var csvLine = try CsvLine.init(allocator, .{ .separator = options.inputSeparator[0], .trim = options.trim, .quote = if (options.inputQuote) |quote| quote[0] else null });
    defer csvLine.deinit();

    if (options.header == null) {
        if (options.fileHeader) {
            if (try fileA.getLine()) |line| {
                try options.setHeaderFields(try csvLine.parse(line));
            }
            if (try fileB.getLine()) |header_line| {
                const header = try csvLine.parse(header_line);
                if (options.header) |known_header| {
                    if (known_header.len != header.len) {
                        return error.differentHeaderLengths;
                    }
                }
            }
        } else {
            // Without a header the first line is data. Peek at it to learn the
            // column count, then put it back for the actual diff.
            if (try fileA.getLine()) |line| {
                options.columnCount = (try csvLine.parse(line)).len;
            }
            fileA.reset();
            fileB.reset();
        }
    }

    if (options.asCsv and options.header != null) {
        try writeHeader(options, writer);
    }

    try options.calculateFieldIndices();

    var fieldSet = try FieldSet.init(try fileA.getAproximateLineCount(10000), options.keyIndices.?, options.valueIndices.?, &csvLine, allocator);
    defer fieldSet.deinit();

    while (try fileA.getLine()) |line| {
        try fieldSet.put(line);
    }
    stats.linesA = fileA.lines;

    if (options.fieldDiff) {
        var csvLineB = try CsvLine.init(allocator, .{ .separator = options.inputSeparator[0], .trim = options.trim, .quote = if (options.inputQuote) |quote| quote[0] else null });
        defer csvLineB.deinit();
        try keyDiffPerField(&fileB, &fieldSet, writer, options, &csvLine, &csvLineB, allocator);
    } else {
        try keyDiffPerLine(&fileB, &fieldSet, writer, options, allocator);
    }
}

const ExactMatches = struct {
    exact: std.array_list.Managed(bool),
    startPos: usize,
    lines: usize,

    fn init(fileB: *FileReader, fieldSet: *FieldSet, allocator: std.mem.Allocator) !ExactMatches {
        const startPos = fileB.pos;
        var exact = std.array_list.Managed(bool).init(allocator);
        errdefer exact.deinit();

        while (try fileB.getLine()) |line| {
            try exact.append(try fieldSet.matchExact(line));
        }

        return .{
            .exact = exact,
            .startPos = startPos,
            .lines = fileB.lines,
        };
    }

    fn deinit(self: *ExactMatches) void {
        self.exact.deinit();
    }
};

const RemovedContext = struct {
    writer: *std.Io.Writer,
    options: *Options,
    color: Colors,
};

fn printRemoved(context: RemovedContext, entry: *FieldSet.SetEntry) anyerror!void {
    for (0..entry.count) |_| {
        _ = try context.writer.print("{s}-{c}{s}{s}\n", .{ context.color.red, context.options.diffSpaceing, entry.line.?, context.color.reset });
        stats.removed += 1;
    }
}

const DeferredList = struct {
    // The process allocator is an arena, so growing an ArrayList would leave
    // every intermediate buffer behind. Fixed chunks keep memory proportional
    // to the number of deferred rows.
    const chunk_size = 16384;

    allocator: std.mem.Allocator,
    lineChunks: std.array_list.Managed([][]const u8),
    slotChunks: std.array_list.Managed([]u32),
    currentLines: [][]const u8 = &.{},
    currentSlots: []u32 = &.{},
    used: usize = 0,

    fn init(allocator: std.mem.Allocator) DeferredList {
        return .{
            .allocator = allocator,
            .lineChunks = std.array_list.Managed([][]const u8).init(allocator),
            .slotChunks = std.array_list.Managed([]u32).init(allocator),
        };
    }

    fn deinit(self: *DeferredList) void {
        for (self.lineChunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        for (self.slotChunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.lineChunks.deinit();
        self.slotChunks.deinit();
    }

    fn append(self: *DeferredList, line: []const u8, slot: u32) !void {
        if (self.used == self.currentLines.len) {
            const lines = try self.allocator.alloc([]const u8, chunk_size);
            errdefer self.allocator.free(lines);
            const slots = try self.allocator.alloc(u32, chunk_size);
            errdefer self.allocator.free(slots);

            try self.lineChunks.append(lines);
            errdefer _ = self.lineChunks.pop();
            try self.slotChunks.append(slots);

            self.currentLines = lines;
            self.currentSlots = slots;
            self.used = 0;
        }

        self.currentLines[self.used] = line;
        self.currentSlots[self.used] = slot;
        self.used += 1;
    }
};

fn printChangedLine(writer: *std.Io.Writer, options: *Options, color: Colors, entry: *FieldSet.SetEntry, line: []const u8) !void {
    _ = try writer.print("{s}<{c}{s}{s}\n", .{ color.red, options.diffSpaceing, entry.line.?, color.reset });
    _ = try writer.print("{s}>{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
    stats.changed += 1;
}

fn printChangedFields(writer: *std.Io.Writer, options: *Options, color: Colors, csvLineA: *CsvLine, csvLineB: *CsvLine, entry: *FieldSet.SetEntry, line: []const u8) !void {
    _ = try writer.print("{s}~{s}{c}", .{ color.blue, color.reset, options.diffSpaceing });
    const fieldsA = try csvLineA.parse(entry.line.?);
    const fieldsB = try csvLineB.parse(line);
    for (fieldsA, 0..) |fieldA, index| {
        const fieldB = if (index < fieldsB.len) fieldsB[index] else "";
        const fieldType: FieldType = if (options.fieldTypes) |types|
            (if (index < types.len) types[index] else .EXCLUDED)
        else
            .EXCLUDED;

        switch (fieldType) {
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
}

fn printAdded(writer: *std.Io.Writer, options: *Options, color: Colors, line: []const u8) !void {
    _ = try writer.print("{s}+{c}{s}{s}\n", .{ color.green, options.diffSpaceing, line, color.reset });
    stats.added += 1;
}

fn keyDiffPerLine(fileB: *FileReader, fieldSet: *FieldSet, writer: *std.Io.Writer, options: *Options, allocator: std.mem.Allocator) !void {
    const color = options.getColors();

    if (!options.outputAll) {
        // Exact matches produce no output, so only the non-exact lines need
        // to be revisited. This avoids a second pass over the whole file.
        const noSlot: u32 = std.math.maxInt(u32);
        var deferred = DeferredList.init(allocator);
        defer deferred.deinit();

        while (try fileB.getLine()) |line| {
            const match = try fieldSet.match(line);
            switch (match.result) {
                .exact => stats.equal += 1,
                .existing => try deferred.append(line, match.slot),
                .missing => try deferred.append(line, noSlot),
            }
        }
        stats.linesB = fileB.lines;

        for (deferred.lineChunks.items, deferred.slotChunks.items, 0..) |lines, slots, chunkIndex| {
            const count = if (chunkIndex + 1 == deferred.lineChunks.items.len) deferred.used else DeferredList.chunk_size;
            for (lines[0..count], slots[0..count]) |line, slot| {
                if (slot != noSlot) {
                    if (fieldSet.takeFromSlot(slot)) |entry| {
                        try printChangedLine(writer, options, color, entry, line);
                        entry.count -= 1;
                        continue;
                    }
                }
                try printAdded(writer, options, color, line);
            }
        }
    } else {
        var matches = try ExactMatches.init(fileB, fieldSet, allocator);
        defer matches.deinit();
        fileB.rewindTo(matches.startPos);

        var lineIndex: usize = 0;
        while (try fileB.getLine()) |line| : (lineIndex += 1) {
            if (matches.exact.items[lineIndex]) {
                _ = try writer.print("={c}{s}\n", .{ options.diffSpaceing, line });
                stats.equal += 1;
                continue;
            }

            if (try fieldSet.getFallback(line)) |entry| {
                try printChangedLine(writer, options, color, entry, line);
                entry.count -= 1;
            } else {
                try printAdded(writer, options, color, line);
            }
        }
        stats.linesB = matches.lines;
    }

    try fieldSet.eachRemaining(RemovedContext{ .writer = writer, .options = options, .color = color }, printRemoved);
}

fn keyDiffPerField(fileB: *FileReader, fieldSet: *FieldSet, writer: *std.Io.Writer, options: *Options, csvLineA: *CsvLine, csvLineB: *CsvLine, allocator: std.mem.Allocator) !void {
    const color = options.getColors();

    if (!options.outputAll) {
        const noSlot: u32 = std.math.maxInt(u32);
        var deferred = DeferredList.init(allocator);
        defer deferred.deinit();

        while (try fileB.getLine()) |line| {
            const match = try fieldSet.match(line);
            switch (match.result) {
                .exact => stats.equal += 1,
                .existing => try deferred.append(line, match.slot),
                .missing => try deferred.append(line, noSlot),
            }
        }
        stats.linesB = fileB.lines;

        for (deferred.lineChunks.items, deferred.slotChunks.items, 0..) |lines, slots, chunkIndex| {
            const count = if (chunkIndex + 1 == deferred.lineChunks.items.len) deferred.used else DeferredList.chunk_size;
            for (lines[0..count], slots[0..count]) |line, slot| {
                if (slot != noSlot) {
                    if (fieldSet.takeFromSlot(slot)) |entry| {
                        try printChangedFields(writer, options, color, csvLineA, csvLineB, entry, line);
                        entry.count -= 1;
                        continue;
                    }
                }
                try printAdded(writer, options, color, line);
            }
        }
    } else {
        var matches = try ExactMatches.init(fileB, fieldSet, allocator);
        defer matches.deinit();
        fileB.rewindTo(matches.startPos);

        var lineIndex: usize = 0;
        while (try fileB.getLine()) |line| : (lineIndex += 1) {
            if (matches.exact.items[lineIndex]) {
                _ = try writer.print("={c}{s}\n", .{ options.diffSpaceing, line });
                stats.equal += 1;
                continue;
            }

            if (try fieldSet.getFallback(line)) |entry| {
                try printChangedFields(writer, options, color, csvLineA, csvLineB, entry, line);
                entry.count -= 1;
            } else {
                try printAdded(writer, options, color, line);
            }
        }
        stats.linesB = matches.lines;
    }

    try fieldSet.eachRemaining(RemovedContext{ .writer = writer, .options = options, .color = color }, printRemoved);
}

// Test
const testing = std.testing;

const TestRun = struct {
    output: std.Io.Writer.Allocating,
    options: Options,
    expected: []const u8,

    fn init(comptime file1: []const u8, comptime file2: []const u8, comptime expected: []const u8) !TestRun {
        runtime.io = testing.io;
        runtime.allocator = testing.allocator;

        var testRun: TestRun = .{
            .output = std.Io.Writer.Allocating.init(testing.allocator),
            .options = try Options.init(testing.allocator),
            .expected = @embedFile("test/" ++ expected),
        };
        try testRun.options.inputFiles.append("./src/test/" ++ file1);
        try testRun.options.inputFiles.append("./src/test/" ++ file2);
        return testRun;
    }

    fn runLineDiff(self: *TestRun) !void {
        defer self.deinit();
        try lineDiff(&self.options, &self.output.writer, testing.allocator);
        try testing.expectEqualStrings(self.expected, self.output.written());
    }

    fn runKeyDiff(self: *TestRun) !void {
        defer self.deinit();
        try keyDiff(&self.options, &self.output.writer, testing.allocator);
        try testing.expectEqualStrings(self.expected, self.output.written());
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
    var testRun = try TestRun.init("people.csv", "lessPeople.csv", "expect_lineDiff_people_vs_lessPeople");
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

test "lineDiff with empty files" {
    var testRun = try TestRun.init("empty", "empty", "empty");
    try testRun.runLineDiff();
}

test "lineDiff without trailing newline" {
    var testRun = try TestRun.init("noTrailingNewline.csv", "noTrailingNewline.csv", "empty");
    try testRun.runLineDiff();
}

test "lineDiff with blank lines" {
    var testRun = try TestRun.init("blankLines.csv", "blankLines.csv", "empty");
    try testRun.runLineDiff();
}

test "lineDiff with crlf line endings" {
    var testRun = try TestRun.init("crlf.csv", "crlf.csv", "empty");
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

test "keyDiff duplicate keys with different values" {
    var testRun = try TestRun.init("duplicateValuesA.csv", "duplicateValuesB.csv", "expect_keyDiff_duplicate_values");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff prefers exact matches over earlier changed candidates" {
    var testRun = try TestRun.init("exactMatchA.csv", "exactMatchB.csv", "expect_keyDiff_exact_match_wins");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff with values containing the join separator" {
    var testRun = try TestRun.init("pipeValuesA.csv", "pipeValuesB.csv", "expect_keyDiff_pipe_values");
    try testRun.options.addKey("1");
    try testRun.runKeyDiff();
}

test "keyDiff with a quoted trailing empty field" {
    var testRun = try TestRun.init("quotedA.csv", "quotedB.csv", "expect_keyDiff_quoted_trailing_field");
    try testRun.options.addKey("1");
    testRun.options.inputQuote = .{'"'};
    try testRun.runKeyDiff();
}

test "keyDiff fieldDiff with ragged rows" {
    var testRun = try TestRun.init("raggedA.csv", "raggedB.csv", "expect_keyDiff_ragged_fieldDiff");
    try testRun.options.addKey("1");
    testRun.options.fieldDiff = true;
    try testRun.runKeyDiff();
}

test "keyDiff pople vs people with more columns" {
    var testRun = try TestRun.init("people.csv", "peopleMoreColumns.csv", "empty");
    try testRun.options.addKey("1");
    try testing.expectError(error.differentHeaderLengths, testRun.runKeyDiff());
}

test "keyDiff people with more columns vs people" {
    var testRun = try TestRun.init("peopleMoreColumns.csv", "people.csv", "empty");
    try testRun.options.addKey("1");
    try testing.expectError(error.differentHeaderLengths, testRun.runKeyDiff());
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

test "stats counts lines in fieldDiff mode" {
    stats = Stats.init();

    var testRun = try TestRun.init("people.csv", "differentPeople.csv", "expect_keyDiff_people_vs_differentPeople_fieldDiff");
    try testRun.options.addKey("1");
    testRun.options.fieldDiff = true;
    try testRun.runKeyDiff();

    try testing.expectEqual(11, stats.linesA);
    try testing.expectEqual(11, stats.linesB);
    try testing.expectEqual(2, stats.changed);
}

test "stats print uses the right line counts" {
    var files = std.array_list.Managed([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.append("a.csv");
    try files.append("b.csv");

    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    const value = Stats{
        .linesA = 11,
        .linesB = 22,
        .equal = 3,
        .added = 2,
        .removed = 1,
        .changed = 4,
    };
    try value.print(files, &output.writer);

    var foundA = false;
    var foundB = false;
    var lines = std.mem.splitScalar(u8, output.written(), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "linesA:")) {
            try testing.expect(std.mem.endsWith(u8, line, "11"));
            foundA = true;
        } else if (std.mem.startsWith(u8, line, "linesB:")) {
            try testing.expect(std.mem.endsWith(u8, line, "22"));
            foundB = true;
        }
    }
    try testing.expect(foundA and foundB);
}

test {
    std.testing.refAllDecls(@This());
}
