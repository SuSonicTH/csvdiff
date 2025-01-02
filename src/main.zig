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

var options: Options = undefined;

fn _main() !void {
    var timer = try std.time.Timer.start();
    Utf8Output.init();
    defer Utf8Output.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    options = try Options.init(allocator);
    defer options.deinit();

    if (config.readConfigFromFile("default.config", allocator) catch null) |defaultArguments| {
        try ArgumentParser.parse(&options, defaultArguments.items, allocator);
    }
    try ArgumentParser.parse(&options, args, allocator);
    try ArgumentParser.validateArguments(&options);

    try calculateDiff(allocator);

    const stderr = std.io.getStdOut().writer();
    if (options.time) {
        const timeNeeded = @as(f32, @floatFromInt(timer.lap())) / 1000000.0;
        if (timeNeeded > 1000) {
            _ = try stderr.print("time needed: {d:0.2}s\n", .{timeNeeded / 1000.0});
        } else {
            _ = try stderr.print("time needed: {d:0.2}ms\n", .{timeNeeded});
        }
    }
}

fn calculateDiff(allocator: std.mem.Allocator) !void {
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();
    var set = try HashSet.init(try fileA.getAproximateLineCount(100), allocator);
    defer set.deinit();

    while (try fileA.getLine()) |line| {
        try set.put(line);
    }

    var fileB = try FileReader.init(options.inputFiles.items[1]);
    defer fileB.deinit();

    const writer = std.io.getStdOut().writer();
    while (try fileB.getLine()) |line| {
        if (set.get(line)) |entry| {
            if (entry.count > 0) {
                entry.count -= 1;
            } else {
                _ = try writer.print("> {s}\n", .{line});
            }
        } else {
            _ = try writer.print("> {s}\n", .{line});
        }
    }
    for (set.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("< {s}\n", .{entry.line.?});
            }
        }
    }
    _ = try writer.print("setStat: {d},{d},{d}\n", .{ set.count, set.data.len, set.load() });
}

test {
    std.testing.refAllDecls(@This());
}
