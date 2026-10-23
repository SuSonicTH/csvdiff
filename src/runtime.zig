const std = @import("std");

/// Process-wide state, initialized once at startup by `main`.
pub var io: std.Io = undefined;
pub var allocator: std.mem.Allocator = undefined;
pub var environ: *std.process.Environ.Map = undefined;
