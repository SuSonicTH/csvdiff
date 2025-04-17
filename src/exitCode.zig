const std = @import("std");

pub const version = "csvdiff v0.1";

pub const ExitCode = enum(u8) {
    OK,
    noArgumentError,
    needTwoInputFiles,
    stdinOrFileError,
    unknownArgumentError,
    argumentWithUnknownValueError,
    argumentValueMissingError,
    includeAndExcludeTogether,

    couldNotOpenInputFile,
    couldNotOpenOutputFile,
    outOfMemory,
    genericError = 255,

    pub fn code(self: ExitCode) u8 {
        return @intFromEnum(self);
    }

    pub fn message(self: ExitCode) []const u8 {
        switch (self) {
            .OK => return "",
            .noArgumentError => return "no argument given, expecting at least 2 input files as arguments",
            .needTwoInputFiles => return "exactly 2 input files are needed got {d}",
            .stdinOrFileError => return "use either --stdin or input file(s) not both",
            .unknownArgumentError => return "argument '{s}' is unknown",
            .argumentWithUnknownValueError => return "argument '{s}' got unknown value '{s}'",
            .argumentValueMissingError => return "value for argument '{s}' is missing",
            .includeAndExcludeTogether => return "--include and --exclude cannot be used together",

            .couldNotOpenInputFile => return "could not open input file '{s}' reason: {!}",
            .couldNotOpenOutputFile => return "could not open output file '{s}' reason: {!}",
            .outOfMemory => return "could not allocate more memory",
            .genericError => return "unhandled error '{any}'",
        }
    }

    pub fn exit(self: ExitCode) !noreturn {
        std.process.exit(self.code());
    }

    pub fn printExitCodes() !void {
        const writer = std.io.getStdOut().writer();
        _ = try writer.print("{s}\n\nExit Codes:\n", .{version});

        inline for (std.meta.fields(ExitCode)) |exitCode| {
            try writer.print("{d}: {s}\n", .{ exitCode.value, exitCode.name });
        }
        try ExitCode.OK.exit();
    }

    fn _printErrorAndExit(comptime self: ExitCode, values: anytype) !noreturn {
        const writer = std.io.getStdErr().writer();
        _ = try writer.print("{s}\n\nError #{d}: ", .{ version, self.code() });
        _ = try writer.print(self.message(), values);
        _ = try writer.write("\n");
        _ = try self.exit();
    }

    pub fn printErrorAndExit(comptime self: ExitCode, values: anytype) noreturn {
        _printErrorAndExit(self, values) catch @panic("could not print error message");
    }
};
