const std = @import("std");
const ExitCode = @import("exitCode.zig").ExitCode;
const Options = @import("options.zig").Options;
const ArgumentParser = @import("arguments.zig").Parser;
const Utf8Output = @import("Utf8Output.zig");
const config = @import("config.zig");
const FileReader = @import("FileReader.zig");
const HashSet = @import("HashSet.zig");

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

fn calculateDiff() !void {
    var set = try HashSet.init(16777216, allocator);
    defer set.deinit();
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    //const writer = std.io.getStdOut().writer();
    while (try fileA.getLine()) |line| {
        try set.put(line);
        //_ = try writer.print("{s}:{any}\n", .{ line, map.get(line) });
    }

    _ = try std.io.getStdOut().writer().print("{d},{d},{d}\n", .{ set.count, set.data.len, set.load() });
}
