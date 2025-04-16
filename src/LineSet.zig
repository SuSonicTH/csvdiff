const std = @import("std");

const Self = @This();

pub const SetEntry = struct {
    line: ?[]const u8,
    hash: u32,
    count: u32,
};

allocator: std.mem.Allocator,
data: []SetEntry,
mask: u32,
count: u32 = 0,
size: u5,

pub fn init(initialSize: usize, allocator: std.mem.Allocator) !Self {
    const size = getNumberOfBits(initialSize);
    const set: Self = .{
        .allocator = allocator,
        .data = try allocator.alloc(SetEntry, @as(u32, 1) << size),
        .mask = (@as(u32, 1) << size) - 1,
        .size = size,
    };
    @memset(set.data, .{
        .line = null,
        .hash = 0,
        .count = 0,
    });
    return set;
}

fn getNumberOfBits(size: usize) u5 {
    var reminder = size;
    var bits: u5 = 0;
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
    const hash:u32 = @truncate(std.hash.RapidHash.hash(0, line));
    try self.putHash(line, hash, 1);
    if (self.load() > 0.7) {
        try self.resize();
    }
}

inline fn putHash(self: *Self, line: []const u8, hash: u32, count: u32) !void {
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
    self.mask = (@as(u32, 1) << self.size) - 1;
    self.count = 0;

    const old = self.data;
    self.data = try self.allocator.alloc(SetEntry, @as(u32, 1) << self.size);
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

fn isSame(entry: *SetEntry, hash: u32, line: []const u8) bool {
    if (entry.hash == hash and entry.line.?.len == line.len and std.mem.eql(u8, entry.line.?, line)) {
        return true;
    }
    return false;
}

fn updateEntry(entry: *SetEntry, hash: u32, line: []const u8, count: u32) void {
    if (entry.line == null) {
        entry.line = line;
        entry.count = count;
        entry.hash = hash;
    } else {
        entry.count += count;
    }
}

inline fn linearProbe(self: *Self, start: usize, end: usize, hash: u32, line: []const u8) ?*SetEntry {
    var index: usize = start;
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
    const hash:u32 = @truncate(std.hash.RapidHash.hash(0, line));
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

test "put/get" {
    var set = try init(16, std.testing.allocator);
    defer set.deinit();

    try set.put("one");
    try set.put("two");
    try set.put("three");
    try set.put("four");

    try std.testing.expectEqual("one", set.get("one").?.line.?);
    try std.testing.expectEqual("two", set.get("two").?.line.?);
    try std.testing.expectEqual("three", set.get("three").?.line.?);
    try std.testing.expectEqual("four", set.get("four").?.line.?);

    try std.testing.expectEqual(null, set.get("not therer"));
    try std.testing.expectEqual(null, set.get("also not therer"));
    try std.testing.expectEqual(null, set.get("one1"));
    try std.testing.expectEqual(null, set.get("2two"));

    try set.put("two");
    try set.put("three");
    try set.put("three");
    try set.put("four");
    try set.put("four");
    try set.put("four");

    try std.testing.expectEqual(1, set.get("one").?.count);
    try std.testing.expectEqual(2, set.get("two").?.count);
    try std.testing.expectEqual(3, set.get("three").?.count);
    try std.testing.expectEqual(4, set.get("four").?.count);
}

test "resize" {
    var set = try init(2, std.testing.allocator);
    defer set.deinit();

    try set.put("one");
    try std.testing.expectEqual("one", set.get("one").?.line.?);
    try std.testing.expectEqual(1, set.count);
    try std.testing.expectEqual(2, set.size);

    try set.put("two");
    try std.testing.expectEqual("two", set.get("two").?.line.?);
    try std.testing.expectEqual(2, set.count);
    try std.testing.expectEqual(2, set.size);

    try set.put("three"); //triggers resize
    try std.testing.expectEqual("three", set.get("three").?.line.?);
    try std.testing.expectEqual(3, set.count);
    try std.testing.expectEqual(3, set.size);

    //one and two are still there after resize
    try std.testing.expectEqual("one", set.get("one").?.line.?);
    try std.testing.expectEqual("two", set.get("two").?.line.?);
}
