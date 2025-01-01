const std = @import("std");
const ExitCode = @import("exitCode.zig").ExitCode;
const Options = @import("options.zig").Options;
const ArgumentParser = @import("arguments.zig").Parser;
const Utf8Output = @import("Utf8Output.zig");
const config = @import("config.zig");
const FileReader = @import("FileReader.zig");

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

//todo: implement resizing
//todo: implement initial size to bitcount(size of data/mask)
const Map = struct {
    allocator: std.mem.Allocator,
    data: []MapEntry,
    mask: u64,
    count: u64 = 0,

    pub fn init(initialSize: usize, alloc: std.mem.Allocator) !Map {
        _ = initialSize;
        const map: Map = .{
            .allocator = alloc,
            .data = try allocator.alloc(MapEntry, 1 << 25),
            .mask = (1 << 25) - 1,
        };
        @memset(map.data, .{
            .line = null,
            .hash = 0,
            .count = 0,
        });
        return map;
    }

    pub fn deinit(self: *Map) void {
        self.allocator.free(self.data);
    }

    pub fn put(self: *Map, line: []const u8) !void {
        const hash = std.hash.XxHash64.hash(0, line);
        const index = hash & self.mask;
        var entry: *MapEntry = &self.data[index];

        if (entry.line == null) {
            setEntry(entry, hash, line);
            self.count += 1;
        } else if (isSame(entry, hash, line)) {
            entry.count += 1;
            return;
        } else {
            if (!self.linearProbe(index + 1, self.data.len, hash, line)) {
                if (!self.linearProbe(0, index, hash, line)) {
                    @panic("No space left");
                }
            }
            self.count += 1;
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

    pub fn get(self: *Map, line: []const u8) MapEntry {
        const hash = std.hash.XxHash64.hash(0, line);
        const index = hash & self.mask;
        return self.data[index];
    }

    pub fn load(self: *Map) f32 {
        if (self.count == 0) {
            return 0.0;
        }
        return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.data.len));
    }
};

fn printEntry(entry: *MapEntry) !void {
    _ = try std.io.getStdOut().writer().print("hash: {d}, index: {d}, count: {d}, line: {s}", .{ entry.*.hash, entry.*.hash & ((1 << 24) - 1), entry.*.count, entry.*.line.? });
}

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

    _ = try std.io.getStdOut().writer().print("{d},{d},{d}\n", .{ map.count, map.data.len, map.load() });
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
