const std = @import("std");
const MemMapper = @import("MemMapper").MemMapper;
const ExitCode = @import("exitCode.zig").ExitCode;

const Self = @This();

file: std.fs.File,
memMapper: MemMapper,
data: []const u8,
pos: usize,

pub fn init(fileName: []const u8) !Self {
    var file = std.fs.cwd().openFile(fileName, .{}) catch |err| ExitCode.couldNotOpenInputFile.printErrorAndExit(.{ fileName, err });
    errdefer file.close();
    var memMapper = try MemMapper.init(file, false);
    errdefer memMapper.deinit();

    return .{
        .file = file,
        .memMapper = memMapper,
        .data = try memMapper.map(u8, .{}),
        .pos = 0,
    };
}

pub fn deinit(self: *Self) void {
    self.memMapper.unmap(self.data);
    self.memMapper.deinit();
    self.file.close();
}

pub fn getLine(self: *Self) !?[]const u8 {
    if (self.pos >= self.data.len) {
        return null;
    }
    const start = self.pos;
    while (self.pos < self.data.len and self.data[self.pos] != '\r' and self.data[self.pos] != '\n') {
        self.pos += 1;
    }
    if (self.data[self.pos] == '\r') {
        const end = self.pos;
        self.pos += 1;
        if (self.data[self.pos] == '\n') {
            self.pos += 1;
        }
        return self.data[start..end];
    } else if (self.data[self.pos] == '\n') {
        const end = self.pos;
        self.pos += 1;
        return self.data[start..end];
    } else {
        return self.data[start .. self.pos - 1];
    }
}

pub fn reset(self: *Self) void {
    self.pos = 0;
}

pub fn getAproximateLineCount(self: *Self, samples: usize) !usize {
    var len: usize = 0;
    var count: usize = 0;
    while (try self.getLine()) |line| {
        len += line.len;
        count += 1;
        if (count == samples) break;
    }
    self.reset();
    const average = len / count;
    return (self.data.len / average);
}
