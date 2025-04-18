const std = @import("std");
const ExitCode = @import("exitCode.zig").ExitCode;
const Options = @import("options.zig").Options;
const ArgumentParser = @import("arguments.zig").Parser;
const Utf8Output = @import("Utf8Output.zig");
const config = @import("config.zig");
const FileReader = @import("FileReader.zig");
const LineSet = @import("LineSet.zig");
const FieldSet = @import("FieldSet.zig");
const CsvLine = @import("CsvLine.zig");
const builtin = @import("builtin");

pub fn main() !void {
    Utf8Output.init();
    defer Utf8Output.deinit();

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

    if (options.listHeader) {
        try listHeader(options, allocator);
    } else if (options.keyFields == null) {
        try lineDiff(options, allocator);
    } else {
        try uniqueDiff(&options, allocator);
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

fn castArgs(args: [][:0]u8, allocator: std.mem.Allocator) ![][]const u8 {
    var ret = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        ret[i] = arg[0..];
    }
    return ret;
}

fn listHeader(options: Options, allocator: std.mem.Allocator) !void {
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

fn lineDiff(options: Options, allocator: std.mem.Allocator) !void {
    var fileA = try FileReader.init(options.inputFiles.items[0]);
    defer fileA.deinit();

    var fileB = try FileReader.init(options.inputFiles.items[1]);
    defer fileB.deinit();

    var lineSet = try LineSet.init(try fileA.getAproximateLineCount(100), allocator);
    defer lineSet.deinit();
    while (try fileA.getLine()) |line| {
        try lineSet.put(line);
    }

    const writer = std.io.getStdOut().writer();
    while (try fileB.getLine()) |line| {
        if (lineSet.get(line)) |entry| {
            if (entry.count > 0) {
                entry.count -= 1;
            } else {
                _ = try writer.print("+ {s}\n", .{line});
            }
        } else {
            _ = try writer.print("+ {s}\n", .{line});
        }
    }
    for (lineSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("- {s}\n", .{entry.line.?});
            }
        }
    }
}

fn uniqueDiff(options: *Options, allocator: std.mem.Allocator) !void {
    const writer = std.io.getStdOut().writer();

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
        _ = try fileB.getLine(); //skip header;
    }

    while (try fileB.getLine()) |line| {
        if (try fieldSet.get(line)) |entry| {
            if (entry.count > 0) {
                if (!try fieldSet.valueMatches(entry, line)) {
                    _ = try writer.print("< {s}\n", .{entry.line.?});
                    _ = try writer.print("> {s}\n", .{line});
                }
                entry.count -= 1;
            } else {
                _ = try writer.print("+ {s}\n", .{line});
            }
        } else {
            _ = try writer.print("+ {s}\n", .{line});
        }
    }
    for (fieldSet.data) |entry| {
        if (entry.line != null and entry.count > 0) {
            for (0..entry.count) |_| {
                _ = try writer.print("- {s}\n", .{entry.line.?});
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
