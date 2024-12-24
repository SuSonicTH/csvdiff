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

    if (options.time) {
        const timeNeeded = @as(f32, @floatFromInt(timer.lap())) / 1000000.0;
        const stderr = std.io.getStdErr().writer();
        if (timeNeeded > 1000) {
            _ = try stderr.print("time needed: {d:0.2}s\n", .{timeNeeded / 1000.0});
        } else {
            _ = try stderr.print("time needed: {d:0.2}ms\n", .{timeNeeded});
        }
    }
}

const MapEntry = struct {
    line: []const u8,
};

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
    var map = std.StringHashMap(MapEntry).init(allocator);
    defer map.deinit();
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    while (try fileA.getLine()) |line| {
        try map.put(line, .{ .line = line });
    }

    _ = try std.io.getStdOut().writer().print(">{any}<\n", .{map});
}
