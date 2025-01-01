const std = @import("std");
const ExitCode = @import("exitCode.zig").ExitCode;
const Options = @import("options.zig").Options;
const ArgumentParser = @import("arguments.zig").Parser;
const Utf8Output = @import("Utf8Output.zig");
const config = @import("config.zig");
const MemMapper = @import("MemMapper").MemMapper;

pub fn main() !void {
    _main() catch |err| switch (err) {
        error.OutOfMemory => ExitCode.outOfMemory.printErrorAndExit(.{}),
        else => ExitCode.genericError.printErrorAndExit(.{err}),
    };
}

var allocator: std.mem.Allocator = undefined;
var options: Options = undefined;

fn _main() !void {
    var timer = try std.time.Timer.start();
    Utf8Output.init();
    defer Utf8Output.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    options = try Options.init(allocator);
    defer options.deinit();

    if (config.readConfigFromFile("default.config", allocator) catch null) |defaultArguments| {
        try ArgumentParser.parse(&options, defaultArguments.items, allocator);
    }
    try ArgumentParser.parse(&options, args, allocator);
    try ArgumentParser.validateArguments(&options);

    try calculateDiff();

    const stderr = std.io.getStdOut().writer();
    if (options.time) {
        const timeNeeded = @as(f32, @floatFromInt(timer.lap())) / 1000000.0;
        if (timeNeeded > 1000) {
            _ = try stderr.print("time needed: {d:0.2}s\n", .{timeNeeded / 1000.0});
        } else {
            _ = try stderr.print("time needed: {d:0.2}ms\n", .{timeNeeded});
        }
    }

    if (options.memory) {
        const used = @as(f64, @floatFromInt(arena.queryCapacity()));
        if (used > 1024 * 1024 * 1024) {
            _ = try stderr.print("memory allocated: {d:0.2} GB\n", .{used / 1024.0 / 1024.0 / 1024.0});
        } else if (used > 1024 * 1024) {
            _ = try stderr.print("memory allocated: {d:0.2} MB\n", .{used / 1024.0 / 1024.0});
        } else if (used > 1024) {
            _ = try stderr.print("memory allocated: {d:0.2} KB\n", .{used / 1024.0});
        } else {
            _ = try stderr.print("memory allocated: {d:0} B\n", .{used});
        }
    }
}

const MapEntry = struct {
    line: ?[]const u8,
    hash: u64,
    count: usize,
};

const Seeds: []u64 = .{
    9628788404228902345,
    3600497308183539549,
    5095947213571367657,
    7333372431925412309,
    8402791880033648526,
};

const Map = struct {
    allocator: std.mem.Allocator,
    data: []MapEntry,
    mask: u64,

    fn init(initialSize: usize, alloc: std.mem.Allocator) !Map {
        _ = initialSize;
        const map: Map = .{
            .allocator = alloc,
            .data = try allocator.alloc(MapEntry, 1 << 24),
            .mask = (1 << 24) - 1,
        };
        @memset(map.data, .{
            .line = null,
            .hash = 0,
            .count = 0,
        });
        return map;
    }

    fn deinit(self: *Map) void {
        self.allocator.free(self.data);
    }

    fn put(self: *Map, line: []const u8) !void {
        const hash = std.hash.XxHash64.hash(0, line);
        const index = hash & self.mask;
        //try std.io.getStdOut().writer().print("{s}:{d}:{d}:{d}\n", .{ line, hash, self.mask, index });
        var entry: *MapEntry = &self.data[index];

        if (entry.line == null) {
            setEntry(entry, hash, line);
            //_ = try std.io.getStdOut().writer().print("OK {s}:{d}:{d}\n", .{ line, hash, index });
        } else if (isSame(entry, hash, line)) {
            //_ = try std.io.getStdOut().writer().print("SAME {s}:{d}:{d}\n", .{ line, hash, index });
            entry.count += 1;
            return;
        } else {
            //_ = try std.io.getStdOut().writer().print("COLLISION {s}:{d}:{d}\n", .{ line, hash, index });
            if (!self.linearProbe(index + 1, self.data.len, hash, line)) {
                if (!self.linearProbe(0, index, hash, line)) {
                    @panic("No space left");
                }
            }
        }
    }

    fn isSame(entry: *MapEntry, hash: u64, line: []const u8) bool {
        if (entry.hash == hash and entry.line.?.len == line.len and std.mem.eql(u8, entry.line.?, line)) {
            return true;
        }
        return false;
    }

    fn setEntry(entry: *MapEntry, hash: u64, line: []const u8) void {
        entry.line = line;
        entry.count = 1;
        entry.hash = hash;
    }

    inline fn linearProbe(self: *Map, start: u64, end: u64, hash: u64, line: []const u8) bool {
        var index: u64 = start;
        while (index < end) {
            const entry = &self.data[index];
            if (entry.line == null) {
                setEntry(entry, hash, line);
                return true;
            } else if (isSame(entry, hash, line)) {
                entry.count += 1;
                return true;
            }
            index += 1;
        }
        return false;
    }

    fn get(self: *Map, line: []const u8) MapEntry {
        const hash = std.hash.XxHash64.hash(0, line);
        const index = hash & self.mask;
        return self.data[index];
    }
};

fn printEntry(entry: *MapEntry) !void {
    _ = try std.io.getStdOut().writer().print("hash: {d}, index: {d}, count: {d}, line: {s}", .{ entry.*.hash, entry.*.hash & ((1 << 24) - 1), entry.*.count, entry.*.line.? });
}

//std.hash.XxHash64.init(seed: u64)
const FileReader = struct {
    file: std.fs.File,
    memMapper: MemMapper,
    data: []const u8,
    pos: usize,

    fn init(fileName: []const u8) !FileReader {
        var file = std.fs.cwd().openFile(options.inputFiles.items[0], .{}) catch |err| ExitCode.couldNotOpenInputFile.printErrorAndExit(.{ fileName, err });
        errdefer file.close();
        var memMapper = try MemMapper.init(file, false);
        errdefer memMapper.deinit();

        return .{
            .file = file,
            .memMapper = memMapper,
            .data = try memMapper.map(u8, .{}),
            .pos = 0,
        };
    }

    fn getLine(self: *FileReader) !?[]const u8 {
        if (self.pos >= self.data.len) {
            return null;
        }
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\r' and self.data[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.data[self.pos] == '\r') {
            const end = self.pos;
            self.pos += 1;
            if (self.data[self.pos] == '\n') {
                self.pos += 1;
            }
            return self.data[start..end];
        } else if (self.data[self.pos] == '\n') {
            const end = self.pos;
            self.pos += 1;
            return self.data[start..end];
        } else {
            return self.data[start .. self.pos - 1];
        }
    }

    fn deinit(self: *FileReader) void {
        self.memMapper.unmap(self.data);
        self.memMapper.deinit();
        self.file.close();
    }
};

fn calculateDiff() !void {
    var map = try Map.init(16777216, allocator);
    defer map.deinit();
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    //const writer = std.io.getStdOut().writer();
    while (try fileA.getLine()) |line| {
        try map.put(line);
        //_ = try writer.print("{s}:{any}\n", .{ line, map.get(line) });
    }

    //_ = try std.io.getStdOut().writer().print(">{any}<\n", .{map});
}

//fn calculateDiff() !void {
//    var map = std.StringHashMap(MapEntry).init(allocator);
//    defer map.deinit();
//    var fileA = try FileReader.init(options.inputFiles.items[0]);
//    defer fileA.deinit();
//
//    while (try fileA.getLine()) |line| {
//        try map.put(line, .{ .line = line });
//    }
//
//    //_ = try std.io.getStdOut().writer().print(">{any}<\n", .{map});
//}

test "hasher" {
    try std.testing.expectEqual(16777215, (1 << 24) - 1);
}
