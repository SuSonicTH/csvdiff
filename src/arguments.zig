const std = @import("std");
const Options = @import("options.zig").Options;
const OutputFormat = @import("options.zig").OutputFormat;
const readConfigFromFile = @import("config.zig").readConfigFromFile;
const ExitCode = @import("exitCode.zig").ExitCode;
const version = @import("exitCode.zig").version;

const Argument = enum {
    @"--help",
    @"-v",
    @"--version",
    @"-s",
    @"--separator",
    @"-q",
    @"--quoute",
    @"-h",
    @"--header",
    @"-n",
    @"--noHeader",
    @"-I",
    @"--include",
    @"-E",
    @"--exclude",
    @"--trim",
    @"-l",
    @"--listHeader",
    @"--exitCodes",
    @"--config",
    @"-o",
    @"--output",
    @"--time",
    @"--memory",
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

const Quoute = enum {
    no,
    single,
    @"'",
    double,
    @"\"",
};

pub const Parser = struct {
    var skip_next: bool = false;

    pub fn parse(options: *Options, args: [][]const u8, allocator: std.mem.Allocator) !void {
        if (args.len == 1) {
            try ExitCode.noArgumentError.printErrorAndExit(.{});
        }

        for (args[1..], 1..) |arg, index| {
            if (skip_next) {
                skip_next = false;
                continue;
            }
            if (arg[0] == '-') {
                switch (std.meta.stringToEnum(Argument, arg) orelse {
                    try ExitCode.unknownArgumentError.printErrorAndExit(.{arg});
                }) {
                    .@"--help" => try printUsage(),
                    .@"-v", .@"--version" => try printVersion(),
                    .@"-s", .@"--separator" => options.inputSeparator = try getSeparator(args, index, arg),
                    .@"-q", .@"--quoute" => options.inputQuoute = try getQuoute(args, index, arg),
                    .@"--trim" => options.trim = true,
                    .@"-l", .@"--listHeader" => options.listHeader = true,
                    .@"-o", .@"--output" => {
                        options.outputName = try argumentValue(args, index, arg);
                        skipNext();
                    },
                    .@"-h", .@"--header" => {
                        try options.setHeader(try argumentValue(args, index, arg));
                        options.fileHeader = false;
                        skipNext();
                    },
                    .@"-n", .@"--noHeader" => options.fileHeader = false,
                    .@"-I", .@"--include" => {
                        options.addInclude(try argumentValue(args, index, arg)) catch |err| {
                            switch (err) {
                                error.IncludeAndExcludeTogether => try ExitCode.includeAndExcludeTogether.printErrorAndExit(.{}),
                                else => return err,
                            }
                        };
                        skipNext();
                    },
                    .@"-E", .@"--exclude" => {
                        options.addExclude(try argumentValue(args, index, arg)) catch |err| {
                            switch (err) {
                                error.IncludeAndExcludeTogether => try ExitCode.includeAndExcludeTogether.printErrorAndExit(.{}),
                                else => return err,
                            }
                            return err;
                        };
                        skipNext();
                    },
                    .@"--exitCodes" => try ExitCode.printExitCodes(),
                    .@"--config" => {
                        const arguments = try readConfigFromFile(try argumentValue(args, index, arg), allocator);
                        try parse(options, arguments.items, allocator);
                        skipNext();
                    },
                    .@"--time" => {
                        options.time = true;
                    },
                    .@"--memory" => {
                        options.memory = true;
                    },
                }
            } else {
                try options.inputFiles.append(arg);
            }
        }
    }

    fn getSeparator(args: [][]const u8, index: usize, arg: []const u8) ![1]u8 {
        const sep = try argumentValue(args, index, arg);
        skipNext();
        switch (std.meta.stringToEnum(Separator, sep) orelse {
            try ExitCode.argumentWithUnknownValueError.printErrorAndExit(.{ arg, sep });
        }) {
            .comma, .@"," => return .{','},
            .semicolon, .@";" => return .{';'},
            .tab, .@"\t" => return .{'\t'},
            .pipe, .@"|" => return .{'|'},
        }
    }

    fn getQuoute(args: [][]const u8, index: usize, arg: []const u8) !?[1]u8 {
        const quoute = try argumentValue(args, index, arg);
        skipNext();
        switch (std.meta.stringToEnum(Quoute, quoute) orelse {
            try ExitCode.argumentWithUnknownValueError.printErrorAndExit(.{ arg, quoute });
        }) {
            .no => return null,
            .single, .@"'" => return .{'\''},
            .double, .@"\"" => return .{'"'},
        }
    }

    inline fn skipNext() void {
        skip_next = true;
    }

    fn argumentValue(args: [][]const u8, index: usize, argument: []const u8) ![]const u8 {
        const pos = index + 1;
        if (pos >= args.len) {
            try ExitCode.argumentValueMissingError.printErrorAndExit(.{argument});
        }
        return args[pos];
    }

    fn printUsage() !void {
        const help = @embedFile("USAGE.txt");
        try std.io.getStdOut().writeAll(version ++ help);
        try ExitCode.OK.exit();
    }

    fn printVersion() !void {
        const license = @embedFile("LICENSE.txt");
        try std.io.getStdOut().writeAll(version ++ "\n\n" ++ license);
        try ExitCode.exit(.OK);
    }

    pub fn validateArguments(options: *Options) !void {
        if (options.inputFiles.items.len != 2) {
            ExitCode.needTwoInputFiles.printErrorAndExit(.{options.inputFiles.items.len});
        }
    }
};
