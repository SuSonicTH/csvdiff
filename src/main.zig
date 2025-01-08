const std = @import("std");
const ExitCode = @import("exitCode.zig").ExitCode;
const Options = @import("options.zig").Options;
const ArgumentParser = @import("arguments.zig").Parser;
const Utf8Output = @import("Utf8Output.zig");
const config = @import("config.zig");
const FileReader = @import("FileReader.zig");
const LineSet = @import("LineSet.zig");
const FieldSet = @import("FieldSet.zig");
const CsvLine = @import("CsvLine").CsvLine;

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

    options = try Options.init(allocator);
    defer options.deinit();

    if (config.readConfigFromFile("default.config", allocator) catch null) |defaultArguments| {
        try ArgumentParser.parse(&options, defaultArguments.items, allocator);
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try ArgumentParser.parse(&options, args, allocator);
    try ArgumentParser.validateArguments(&options);

    if (options.listHeader) {
        try listHeader(allocator);
    } else if (options.keyFields == null) {
        try lineDiff(allocator);
    } else {
        try uniqueDiff(allocator);
    }

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

fn listHeader(allocator: std.mem.Allocator) !void {
    var csvLine = try CsvLine.init(allocator, .{ .trim = options.trim }); //todo: use options from arguments
    var file = try FileReader.init(options.inputFiles.items[0]);
    defer file.deinit();

    const writer = std.io.getStdOut().writer();
    if (try file.getLine()) |line| {
        const fields = try csvLine.parse(line);
        for (fields) |field| {
            _ = try writer.print("{s}\n", .{field});
        }
    }
}

fn lineDiff(allocator: std.mem.Allocator) !void {
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();
    var set = try LineSet.init(try fileA.getAproximateLineCount(100), allocator);
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

fn uniqueDiff(allocator: std.mem.Allocator) !void {
    const writer = std.io.getStdOut().writer();

    var csvLine = try CsvLine.init(allocator, .{ .trim = options.trim }); //todo: use options from arguments
    defer csvLine.free();

    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    if (options.fileHeader) {
        if (try fileA.getLine()) |line| {
            try options.setHeaderFields(try csvLine.parse(line));
        }
    }
    try options.calculateFieldIndices();

    var set = try FieldSet.init(try fileA.getAproximateLineCount(100), options.keyIndices.?, options.valueIndices.?, csvLine, allocator);
    defer set.deinit();

    if (options.fileHeader) {
        _ = try fileA.getLine(); //skip header;
    }

    while (try fileA.getLine()) |line| {
        try set.put(line);
    }

    var fileB = try FileReader.init(options.inputFiles.items[1]);
    defer fileB.deinit();

    if (options.fileHeader) {
        _ = try fileB.getLine(); //skip header;
    }

    while (try fileB.getLine()) |line| {
        if (try set.get(line)) |entry| {
            if (entry.count > 0) {
                if (!try set.valueMatches(entry, line)) {
                    _ = try writer.print("- {s}\n", .{entry.line.?});
                    _ = try writer.print("+ {s}\n", .{line});
                }
                entry.count -= 1;
            } else {
                _ = try writer.print("+ {s}\n", .{line});
            }
        } else {
            _ = try writer.print("+ {s}\n", .{line});
        }
    }
    for (set.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("- {s}\n", .{entry.line.?});
            }
        }
    }
    _ = try writer.print("setStat: {d},{d},{d}\n", .{ set.count, set.data.len, set.load() });
}

test {
    std.testing.refAllDecls(@This());
}
