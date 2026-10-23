const std = @import("std");
const runtime = @import("runtime.zig");

pub const version = "csvdiff v0.1.4-beta";

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
        return @backingInt(self);
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

            .couldNotOpenInputFile => return "could not open input file '{s}' reason: {}",
            .couldNotOpenOutputFile => return "could not open output file '{s}' reason: {}",
            .outOfMemory => return "could not allocate more memory",
            .genericError => return "unhandled error '{any}'",
        }
    }

    pub fn exit(self: ExitCode) !noreturn {
        std.process.exit(self.code());
    }

    pub fn printExitCodes() !void {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(runtime.io, &stdout_buffer);
        var stdout = &stdout_writer.interface;
        _ = try stdout.print("{s}\n\nExit Codes:\n", .{version});

        const enum_info = @typeInfo(ExitCode).@"enum";
        inline for (enum_info.field_names, enum_info.field_values) |name, value| {
            try stdout.print("{d}: {s}\n", .{ value, name });
        }
        try stdout.flush();
        try ExitCode.OK.exit();
    }

    fn _printErrorAndExit(comptime self: ExitCode, values: anytype) !noreturn {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(runtime.io, &stdout_buffer);
        var stdout = &stdout_writer.interface;
        _ = try stdout.print("{s}\n\nError #{d}: ", .{ version, self.code() });
        _ = try stdout.print(self.message(), values);
        _ = try stdout.write("\n");
        try stdout.flush();
        _ = try self.exit();
    }

    pub fn printErrorAndExit(comptime self: ExitCode, values: anytype) noreturn {
        _printErrorAndExit(self, values) catch @panic("could not print error message");
    }
};
