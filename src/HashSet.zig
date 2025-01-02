const std = @import("std");

const Self = @This();

pub const SetEntry = struct {
    line: ?[]const u8,
    hash: u64,
    count: u64,
};

allocator: std.mem.Allocator,
data: []SetEntry,
mask: u64,
count: u64 = 0,
size: u6,

pub fn init(initialSize: usize, allocator: std.mem.Allocator) !Self {
    const size = getNumberOfBits(initialSize);
    const set: Self = .{
        .allocator = allocator,
        .data = try allocator.alloc(SetEntry, @as(u64, 1) << size),
        .mask = (@as(u64, 1) << size) - 1,
        .size = size,
    };
    @memset(set.data, .{
        .line = null,
        .hash = 0,
        .count = 0,
    });
    return set;
}

fn getNumberOfBits(size: usize) u6 {
    var reminder = size;
    var bits: u6 = 0;
    while (reminder > 0) {
        reminder = reminder >> 1;
        bits += 1;
    }
    return bits;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.data);
}

pub fn put(self: *Self, line: []const u8) !void {
    const hash = std.hash.XxHash64.hash(0, line);
    try self.putHash(line, hash, 1);
    if (self.load() > 0.7) {
        try self.resize();
    }
}

inline fn putHash(self: *Self, line: []const u8, hash: u64, count: u64) !void {
    const index = hash & self.mask;
    var entry: *SetEntry = &self.data[index];

    if (entry.line == null) {
        updateEntry(entry, hash, line, count);
        self.count += 1;
    } else if (isSame(entry, hash, line)) {
        entry.count += 1;
        return;
    } else {
        if (self.linearProbe(index + 1, self.data.len, hash, line)) |nextEntry| {
            updateEntry(nextEntry, hash, line, count);
        } else if (self.linearProbe(0, index, hash, line)) |nextEntry| {
            updateEntry(nextEntry, hash, line, count);
        } else {
            @panic("HashSet is full");
        }
        self.count += 1;
    }
}

fn resize(self: *Self) !void {
    if (self.size >= 64) {
        return error.MaximumHashSetSizeReached;
    }

    self.size += 1;
    self.mask = (@as(u64, 1) << self.size) - 1;
    self.count = 0;

    const old = self.data;
    self.data = try self.allocator.alloc(SetEntry, @as(u64, 1) << self.size);
    @memset(self.data, .{
        .line = null,
        .hash = 0,
        .count = 0,
    });

    for (old) |entry| {
        if (entry.line != null) {
            try self.putHash(entry.line.?, entry.hash, entry.count);
        }
    }

    self.allocator.free(old);
}

fn isSame(entry: *SetEntry, hash: u64, line: []const u8) bool {
    if (entry.hash == hash and entry.line.?.len == line.len and std.mem.eql(u8, entry.line.?, line)) {
        return true;
    }
    return false;
}

fn updateEntry(entry: *SetEntry, hash: u64, line: []const u8, count: u64) void {
    if (entry.line == null) {
        entry.line = line;
        entry.count = count;
        entry.hash = hash;
    } else {
        entry.count += count;
    }
}

inline fn linearProbe(self: *Self, start: u64, end: u64, hash: u64, line: []const u8) ?*SetEntry {
    var index: u64 = start;
    while (index < end) {
        const entry = &self.data[index];
        if (entry.line == null) {
            return entry;
        } else if (isSame(entry, hash, line)) {
            return entry;
        }
        index += 1;
    }
    return null;
}

pub fn get(self: *Self, line: []const u8) ?*SetEntry {
    const hash = std.hash.XxHash64.hash(0, line);
    const index = hash & self.mask;
    const entry = &self.data[index];
    if (entry.line == null) {
        return null;
    } else if (isSame(entry, hash, line)) {
        return entry;
    } else if (self.linearProbe(index + 1, self.data.len, hash, line)) |nextEntry| {
        if (nextEntry.line == null) {
            return null;
        } else {
            return nextEntry;
        }
    } else if (self.linearProbe(0, index, hash, line)) |nextEntry| {
        if (nextEntry.line == null) {
            return null;
        } else {
            return nextEntry;
        }
    }
    return null;
}

pub fn load(self: *Self) f32 {
    if (self.count == 0) {
        return 0.0;
    }
    return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.data.len));
}

test "getNumberOfBits" {
    try std.testing.expectEqual(0, getNumberOfBits(0));
    try std.testing.expectEqual(1, getNumberOfBits(1));
    try std.testing.expectEqual(2, getNumberOfBits(2));
    try std.testing.expectEqual(2, getNumberOfBits(3));
    try std.testing.expectEqual(3, getNumberOfBits(4));
    try std.testing.expectEqual(4, getNumberOfBits(8));
    try std.testing.expectEqual(4, getNumberOfBits(15));
    try std.testing.expectEqual(11, getNumberOfBits(1 << 10));
    try std.testing.expectEqual(24, getNumberOfBits(14976460));
}
