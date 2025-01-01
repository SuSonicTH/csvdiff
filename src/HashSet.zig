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

pub fn init(initialSize: usize, allocator: std.mem.Allocator) !Self {
    _ = initialSize;
    const map: Self = .{
        .allocator = allocator,
        .data = try allocator.alloc(SetEntry, 1 << 25),
        .mask = (1 << 25) - 1,
    };
    @memset(map.data, .{
        .line = null,
        .hash = 0,
        .count = 0,
    });
    return map;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.data);
}

pub fn put(self: *Self, line: []const u8) !void {
    const hash = std.hash.XxHash64.hash(0, line);
    const index = hash & self.mask;
    var entry: *SetEntry = &self.data[index];

    if (entry.line == null) {
        setEntry(entry, hash, line);
        self.count += 1;
    } else if (isSame(entry, hash, line)) {
        entry.count += 1;
        return;
    } else {
        if (!self.linearProbe(index + 1, self.data.len, hash, line)) {
            if (!self.linearProbe(0, index, hash, line)) {
                @panic("No space left");
            }
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

fn setEntry(entry: *SetEntry, hash: u64, line: []const u8) void {
    entry.line = line;
    entry.count = 1;
    entry.hash = hash;
}

inline fn linearProbe(self: *Self, start: u64, end: u64, hash: u64, line: []const u8) bool {
    var index: u64 = start;
    while (index < end) {
        const entry = &self.data[index];
        if (entry.line == null) {
            setEntry(entry, hash, line);
            return true;
        } else if (isSame(entry, hash, line)) {
            entry.count += 1;
            return true;
        }
        index += 1;
    }
    return false;
}

pub fn get(self: *Self, line: []const u8) SetEntry {
    const hash = std.hash.XxHash64.hash(0, line);
    const index = hash & self.mask;
    return self.data[index];
}

pub fn load(self: *Self) f32 {
    if (self.count == 0) {
        return 0.0;
    }
    return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.data.len));
}
