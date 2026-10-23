const std = @import("std");
const runtime = @import("runtime.zig");
const MemMapper = @import("MemMapper.zig");
const ExitCode = @import("exitCode.zig").ExitCode;

const Self = @This();

file: std.Io.File,
memMapper: MemMapper,
data: []const u8,
pos: usize = 0,
lines: usize = 0,

pub fn init(fileName: []const u8) !Self {
    var file = std.Io.Dir.cwd().openFile(runtime.io, fileName, .{}) catch |err| ExitCode.couldNotOpenInputFile.printErrorAndExit(.{ fileName, err });
    errdefer file.close(runtime.io);
    var memMapper = try MemMapper.init(file, runtime.io, false);
    errdefer memMapper.deinit();

    return .{
        .file = file,
        .memMapper = memMapper,
        .data = try memMapper.map(u8, .{}),
    };
}

pub fn deinit(self: *Self) void {
    self.memMapper.unmap(self.data);
    self.memMapper.deinit();
    self.file.close(runtime.io);
}

pub fn getLine(self: *Self) !?[]const u8 {
    if (self.pos >= self.data.len) {
        return null;
    }
    self.lines += 1;

    const start = self.pos;
    while (self.pos < self.data.len and self.data[self.pos] != '\r' and self.data[self.pos] != '\n') {
        self.pos += 1;
    }
    const end = self.pos;

    if (self.pos < self.data.len and self.data[self.pos] == '\r') {
        self.pos += 1;
        if (self.pos < self.data.len and self.data[self.pos] == '\n') {
            self.pos += 1;
        }
    } else if (self.pos < self.data.len and self.data[self.pos] == '\n') {
        self.pos += 1;
    }

    return self.data[start..end];
}

/// Rewind to the beginning, keeping the line statistics.
pub fn rewind(self: *Self) void {
    self.pos = 0;
}

/// Move the read position without changing the line statistics.
pub fn rewindTo(self: *Self, position: usize) void {
    self.pos = position;
}

pub fn reset(self: *Self) void {
    self.pos = 0;
    self.lines = 0;
}

/// Counts the number of lines in the file. This is a cheap scan over the
/// memory mapped data and does not change the read position.
pub fn getAproximateLineCount(self: *Self, samples: usize) !usize {
    // Sampling was only ever used to estimate the hash set size. A full scan is
    // both exact and cheap on memory mapped files.
    _ = samples;

    var count: usize = 0;
    var pos: usize = 0;
    while (pos < self.data.len) {
        count += 1;
        while (pos < self.data.len and self.data[pos] != '\r' and self.data[pos] != '\n') {
            pos += 1;
        }
        if (pos < self.data.len and self.data[pos] == '\r') {
            pos += 1;
            if (pos < self.data.len and self.data[pos] == '\n') {
                pos += 1;
            }
        } else if (pos < self.data.len) {
            pos += 1;
        }
    }
    return count;
}

test "reads last line without trailing newline" {
    runtime.io = std.testing.io;

    var file = try Self.init("./src/test/noTrailingNewline.csv");
    defer file.deinit();

    try std.testing.expectEqualStrings("A,B", (try file.getLine()).?);
    try std.testing.expectEqualStrings("1,2", (try file.getLine()).?);
    try std.testing.expectEqual(null, try file.getLine());
    try std.testing.expectEqual(2, file.lines);
}

test "reads empty file" {
    runtime.io = std.testing.io;

    var file = try Self.init("./src/test/empty");
    defer file.deinit();

    try std.testing.expectEqual(null, try file.getLine());
    try std.testing.expectEqual(0, file.lines);
    try std.testing.expectEqual(0, try file.getAproximateLineCount(100));
}

test "counts blank lines" {
    runtime.io = std.testing.io;

    var file = try Self.init("./src/test/blankLines.csv");
    defer file.deinit();

    try std.testing.expectEqual(3, try file.getAproximateLineCount(100));
    try std.testing.expectEqualStrings("", (try file.getLine()).?);
    try std.testing.expectEqualStrings("", (try file.getLine()).?);
    try std.testing.expectEqualStrings("", (try file.getLine()).?);
    try std.testing.expectEqual(null, try file.getLine());
}

test "reads crlf lines" {
    runtime.io = std.testing.io;

    var file = try Self.init("./src/test/crlf.csv");
    defer file.deinit();

    try std.testing.expectEqualStrings("A,B", (try file.getLine()).?);
    try std.testing.expectEqualStrings("1,2", (try file.getLine()).?);
    try std.testing.expectEqual(null, try file.getLine());
    try std.testing.expectEqual(2, try file.getAproximateLineCount(100));
}

test "rewind keeps line count, reset clears it" {
    runtime.io = std.testing.io;

    var file = try Self.init("./src/test/people.csv");
    defer file.deinit();

    _ = try file.getLine();
    _ = try file.getLine();
    try std.testing.expectEqual(2, file.lines);

    file.rewind();
    try std.testing.expectEqual(2, file.lines);
    try std.testing.expectEqualStrings("Customer Id,First Name,Last Name", (try file.getLine()).?);

    file.reset();
    try std.testing.expectEqual(0, file.lines);
}
