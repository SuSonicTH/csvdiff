const std = @import("std");
const runtime = @import("runtime.zig");
const Options = @import("options.zig").Options;
const readConfigFromFile = @import("config.zig").readConfigFromFile;
const ExitCode = @import("exitCode.zig").ExitCode;
const version = @import("exitCode.zig").version;

const Argument = enum {
    @"-h",
    @"--help",
    @"-v",
    @"--version",
    @"-s",
    @"--separator",
    @"-q",
    @"--quote",
    @"--header",
    @"-n",
    @"--noHeader",
    @"-k",
    @"--key",
    @"-e",
    @"--exclude",
    @"--trim",
    @"-l",
    @"--listHeader",
    @"--exitCodes",
    @"--config",
    @"-t",
    @"--time",
    @"--stats",
    @"-c",
    @"--color",
    @"--asCsv",
    @"-f",
    @"--fieldDiff",
    @"-a",
    @"--outputAll",
};

const Separator = enum {
    comma,
    @",",
    semicolon,
    @";",
    pipe,
    @"|",
    tab,
    @"\t",
};

const Quote = enum {
    no,
    single,
    @"'",
    double,
    @"\"",
};

const maxConfigDepth = 10;

pub const Parser = struct {
    pub fn parse(options: *Options, args: [][]const u8, allocator: std.mem.Allocator) !void {
        try parseDepth(options, args, allocator, 0);
    }

    fn parseDepth(options: *Options, args: [][]const u8, allocator: std.mem.Allocator, depth: usize) !void {
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (arg.len == 0) {
                try ExitCode.unknownArgumentError.printErrorAndExit(.{arg});
            }

            if (std.mem.eql(u8, arg, "--")) {
                index += 1;
                while (index < args.len) : (index += 1) {
                    try options.inputFiles.append(args[index]);
                }
                break;
            }

            if (arg[0] == '-') {
                switch (std.meta.stringToEnum(Argument, arg) orelse {
                    try ExitCode.unknownArgumentError.printErrorAndExit(.{arg});
                }) {
                    .@"-h", .@"--help" => try printUsage(),
                    .@"-v", .@"--version" => try printVersion(),
                    .@"-s", .@"--separator" => {
                        options.inputSeparator = try getSeparator(try argumentValue(args, index, arg), arg);
                        index += 1;
                    },
                    .@"-q", .@"--quote" => {
                        options.inputQuote = try getQuote(try argumentValue(args, index, arg), arg);
                        index += 1;
                    },
                    .@"--trim" => options.trim = true,
                    .@"-l", .@"--listHeader" => options.listHeader = true,
                    .@"--header" => {
                        options.setPendingHeader(try argumentValue(args, index, arg));
                        index += 1;
                    },
                    .@"-n", .@"--noHeader" => options.fileHeader = false,
                    .@"-k", .@"--key" => {
                        try options.addPendingKey(try argumentValue(args, index, arg));
                        index += 1;
                    },
                    .@"-e", .@"--exclude" => {
                        try options.addPendingExclude(try argumentValue(args, index, arg));
                        index += 1;
                    },
                    .@"--exitCodes" => try ExitCode.printExitCodes(),
                    .@"--config" => {
                        if (depth >= maxConfigDepth) {
                            try ExitCode.configRecursion.printErrorAndExit(.{});
                        }
                        const configName = try argumentValue(args, index, arg);
                        const configArguments = readConfigFromFile(runtime.io, runtime.environ, configName, allocator) catch |err| {
                            ExitCode.couldNotOpenConfigFile.printErrorAndExit(.{ configName, err });
                        };
                        try parseDepth(options, configArguments.items, allocator, depth + 1);
                        index += 1;
                    },
                    .@"-t", .@"--time" => options.time = true,
                    .@"--stats" => options.stats = true,
                    .@"-c", .@"--color" => options.color = true,
                    .@"--asCsv" => options.setAsCsv(true),
                    .@"-f", .@"--fieldDiff" => options.fieldDiff = true,
                    .@"-a", .@"--outputAll" => options.outputAll = true,
                }
            } else {
                try options.inputFiles.append(arg);
            }
        }
    }

    fn getSeparator(value: []const u8, arg: []const u8) ![1]u8 {
        if (std.mem.eql(u8, value, "\\t")) {
            return .{'\t'};
        }
        switch (std.meta.stringToEnum(Separator, value) orelse {
            try ExitCode.argumentWithUnknownValueError.printErrorAndExit(.{ arg, value });
        }) {
            .comma, .@"," => return .{','},
            .semicolon, .@";" => return .{';'},
            .tab, .@"\t" => return .{'\t'},
            .pipe, .@"|" => return .{'|'},
        }
    }

    fn getQuote(value: []const u8, arg: []const u8) !?[1]u8 {
        switch (std.meta.stringToEnum(Quote, value) orelse {
            try ExitCode.argumentWithUnknownValueError.printErrorAndExit(.{ arg, value });
        }) {
            .no => return null,
            .single, .@"'" => return .{'\''},
            .double, .@"\"" => return .{'"'},
        }
    }

    fn argumentValue(args: [][]const u8, index: usize, argument: []const u8) ![]const u8 {
        const pos = index + 1;
        if (pos >= args.len) {
            try ExitCode.argumentValueMissingError.printErrorAndExit(.{argument});
        }
        return args[pos];
    }

    fn printUsage() !void {
        const help = @embedFile("./USAGE.txt");
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(runtime.io, &stdout_buffer);
        var stdout = &stdout_writer.interface;
        try stdout.writeAll(version ++ "\n" ++ help);
        try stdout.flush();
        try ExitCode.OK.exit();
    }

    fn printVersion() !void {
        const license = @embedFile("LICENSE.txt");
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(runtime.io, &stdout_buffer);
        var stdout = &stdout_writer.interface;
        try stdout.writeAll(version ++ "\n\n" ++ license);
        try stdout.flush();
        try ExitCode.exit(.OK);
    }

    pub fn validateArguments(options: *Options) !void {
        if (options.asCsv) {
            options.diffSpaceing = options.inputSeparator[0];
        }

        if (!options.listHeader and (options.fieldDiff or options.excludedFields != null) and options.keyFields == null) {
            try ExitCode.keyRequired.printErrorAndExit(.{});
        }

        const count = options.inputFiles.items.len;
        if (options.listHeader) {
            if (count == 0) {
                try ExitCode.needTwoInputFiles.printErrorAndExit(.{count});
            }
            return;
        }

        if (count == 0) {
            try ExitCode.noArgumentError.printErrorAndExit(.{});
        }
        if (count != 2) {
            try ExitCode.needTwoInputFiles.printErrorAndExit(.{count});
        }
    }
};

const testing = std.testing;

test "parses aliases and separator escapes" {
    var options = try Options.init(testing.allocator);
    defer options.deinit();

    var args = [_][]const u8{ "csvdiff", "-t", "--quote", "single", "-s", "\\t", "a.csv", "b.csv" };
    try Parser.parse(&options, &args, testing.allocator);

    try testing.expect(options.time);
    try testing.expectEqual(@as(u8, '\''), options.inputQuote.?[0]);
    try testing.expectEqual(@as(u8, '\t'), options.inputSeparator[0]);
    try testing.expectEqual(2, options.inputFiles.items.len);
}

test "supports end of options marker" {
    var options = try Options.init(testing.allocator);
    defer options.deinit();

    var args = [_][]const u8{ "csvdiff", "--", "-a.csv", "b.csv" };
    try Parser.parse(&options, &args, testing.allocator);

    try testing.expectEqual(2, options.inputFiles.items.len);
    try testing.expectEqualStrings("-a.csv", options.inputFiles.items[0]);
}

test "empty config argument list is a no-op" {
    var options = try Options.init(testing.allocator);
    defer options.deinit();

    var args = [_][]const u8{"empty.config"};
    try Parser.parse(&options, &args, testing.allocator);

    try testing.expectEqual(0, options.inputFiles.items.len);
}
