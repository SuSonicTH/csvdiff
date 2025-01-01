const std = @import("std");

const Self = @This();

pub const SetEntry = struct {
    line: ?[]const u8,
    hash: u64,
    count: usize,
};

//todo: implement resizing
//todo: implement initial size to bitcount(size of data/mask)

allocator: std.mem.Allocator,
data: []SetEntry,
mask: u64,
count: u64 = 0,
size: u6,

pub fn init(initialSize: usize, allocator: std.mem.Allocator) !Self {
    const size = getNumberOfBits(initialSize);
    const map: Self = .{
        .allocator = allocator,
        .data = try allocator.alloc(SetEntry, @as(u64, 1) << size),
        .mask = (@as(u64, 1) << size) - 1,
        .size = size,
    };
    @memset(map.data, .{
        .line = null,
        .hash = 0,
        .count = 0,
    });
    return map;
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
    const index = hash & self.mask;
    var entry: *SetEntry = &self.data[index];

    if (entry.line == null) {
        updateEntry(entry, hash, line);
        self.count += 1;
    } else if (isSame(entry, hash, line)) {
        entry.count += 1;
        return;
    } else {
        if (self.linearProbe(index + 1, self.data.len, hash, line)) |nextEntry| {
            updateEntry(nextEntry, hash, line);
        } else if (self.linearProbe(0, index, hash, line)) |nextEntry| {
            updateEntry(nextEntry, hash, line);
        } else {
            @panic("HashSet is full");
        }
        self.count += 1;
    }
}

fn isSame(entry: *SetEntry, hash: u64, line: []const u8) bool {
    if (entry.hash == hash and entry.line.?.len == line.len and std.mem.eql(u8, entry.line.?, line)) {
        return true;
    }
    return false;
}

fn updateEntry(entry: *SetEntry, hash: u64, line: []const u8) void {
    if (entry.line == null) {
        entry.line = line;
        entry.count = 1;
        entry.hash = hash;
    } else {
        entry.count += 1;
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
