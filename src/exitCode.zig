const std = @import("std");
const runtime = @import("runtime.zig");

pub const version = "csvdiff v0.1.6-beta";

pub const ExitCode = enum(u8) {
    OK,
    differencesFound,
    noArgumentError,
    needTwoInputFiles,
    unknownArgumentError,
    argumentWithUnknownValueError,
    argumentValueMissingError,
    invalidFieldSelection,
    noSuchField,
    noHeader,
    differentHeaderLengths,
    keyRequired,
    configRecursion,

    couldNotOpenConfigFile,
    couldNotOpenInputFile,
    outOfMemory,
    genericError = 255,

    pub fn code(self: ExitCode) u8 {
        return @backingInt(self);
    }

    pub fn message(self: ExitCode) []const u8 {
        switch (self) {
            .OK => return "",
            .differencesFound => return "the files are different",
            .noArgumentError => return "no argument given, expecting at least 2 input files as arguments",
            .needTwoInputFiles => return "exactly 2 input files are needed got {d}",
            .unknownArgumentError => return "argument '{s}' is unknown",
            .argumentWithUnknownValueError => return "argument '{s}' got unknown value '{s}'",
            .argumentValueMissingError => return "value for argument '{s}' is missing",
            .invalidFieldSelection => return "field selections must be non-empty, 1-based indices or names (ranges like 1-3 are allowed)",
            .noSuchField => return "a selected field was not found in the header",
            .noHeader => return "a header is required to select fields by name, use indices or --header",
            .differentHeaderLengths => return "the files have a different number of header fields",
            .keyRequired => return "--fieldDiff and --exclude can only be used together with --key",
            .configRecursion => return "the config files reference each other too deeply",

            .couldNotOpenConfigFile => return "could not open config file '{s}' reason: {}",
            .couldNotOpenInputFile => return "could not open input file '{s}' reason: {}",
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
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(runtime.io, &stderr_buffer);
        var stderr = &stderr_writer.interface;
        _ = try stderr.print("{s}\n\nError #{d}: ", .{ version, self.code() });
        _ = try stderr.print(self.message(), values);
        _ = try stderr.write("\n");
        try stderr.flush();
        _ = try self.exit();
    }

    pub fn printErrorAndExit(comptime self: ExitCode, values: anytype) noreturn {
        _printErrorAndExit(self, values) catch @panic("could not print error message");
    }
};
