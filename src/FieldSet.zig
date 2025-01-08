const std = @import("std");
const CsvLine = @import("CsvLine").CsvLine;

const Self = @This();

pub const SetEntry = struct {
    line: ?[]const u8,
    hash: u64,
    count: u64,
};

const KEY: u3 = 0;
const KEY2: u3 = 1;
const VALUE: u3 = 2;
const VALUE2: u3 = 3;

allocator: std.mem.Allocator,
csvLine: CsvLine,
keyIndices: []usize,
valueIndices: []usize,
data: []SetEntry,
mask: u64,
count: u64 = 0,
size: u6,
fieldValue: [4]std.ArrayList(u8) = undefined,

pub fn init(initialSize: usize, keyIndices: []usize, valueIndices: []usize, csvLine: CsvLine, allocator: std.mem.Allocator) !Self {
    const size = getNumberOfBits(initialSize);
    var set: Self = .{
        .allocator = allocator,
        .csvLine = csvLine,
        .keyIndices = keyIndices,
        .valueIndices = valueIndices,
        .data = try allocator.alloc(SetEntry, @as(u64, 1) << size),
        .mask = (@as(u64, 1) << size) - 1,
        .size = size,
    };

    inline for (KEY..VALUE2 + 1) |index| {
        set.fieldValue[index] = std.ArrayList(u8).init(allocator);
    }

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
    const key = try self.getSelectedFields(KEY, line);
    const hash = std.hash.XxHash64.hash(0, key);
    try self.putHash(line, hash, key, 1);
    if (self.load() > 0.7) {
        try self.resize();
    }
}

pub fn get(self: *Self, line: []const u8) !?*SetEntry {
    const key = try self.getSelectedFields(KEY, line);
    const hash = std.hash.XxHash64.hash(0, key);
    const index = hash & self.mask;
    const entry = &self.data[index];
    if (entry.line == null) {
        return null;
    } else if (try self.keyMatches(entry, hash, key)) {
        return entry;
    } else if (try self.linearProbe(index + 1, self.data.len, hash, key)) |nextEntry| {
        if (nextEntry.line == null) {
            return null;
        } else {
            return nextEntry;
        }
    } else if (try self.linearProbe(0, index, hash, key)) |nextEntry| {
        if (nextEntry.line == null) {
            return null;
        } else {
            return nextEntry;
        }
    }
    return null;
}

fn putHash(self: *Self, line: []const u8, hash: u64, key: []const u8, count: u64) !void {
    const index = hash & self.mask;
    var entry: *SetEntry = &self.data[index];

    if (entry.line == null) {
        updateEntry(entry, hash, line, count);
        self.count += 1;
    } else if (try self.keyMatches(entry, hash, key)) {
        if (!try self.valueMatches(entry, line)) {
            return error.duplicateKeyDifferentValues;
        }
        entry.count += 1;
        return;
    } else {
        if (try self.linearProbe(index + 1, self.data.len, hash, key)) |nextEntry| {
            if (nextEntry.line != null and !try self.valueMatches(nextEntry, line)) {
                return error.duplicateKeyDifferentValues;
            }
            updateEntry(nextEntry, hash, line, count);
        } else if (try self.linearProbe(0, index, hash, key)) |nextEntry| {
            if (nextEntry.line != null and !try self.valueMatches(nextEntry, line)) {
                return error.duplicateKeyDifferentValues;
            }
            updateEntry(nextEntry, hash, line, count);
        } else {
            @panic("HashSet is full");
        }
        self.count += 1;
    }
}

fn linearProbe(self: *Self, start: u64, end: u64, hash: u64, key: []const u8) !?*SetEntry {
    var index: u64 = start;
    while (index < end) {
        const entry = &self.data[index];
        if (entry.line == null) {
            return entry;
        } else if (try self.keyMatches(entry, hash, key)) {
            return entry;
        }
        index += 1;
    }
    return null;
}

pub fn load(self: *Self) f32 {
    if (self.count == 0) {
        return 0.0;
    }
    return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.data.len));
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
            const storedKey = try self.getSelectedFields(KEY2, entry.line.?);
            try self.putHash(entry.line.?, entry.hash, storedKey, entry.count);
        }
    }

    self.allocator.free(old);
}

pub fn getSelectedFields(self: *Self, comptime what: u3, line: []const u8) ![]const u8 {
    var list: *std.ArrayList(u8) = &self.fieldValue[what];
    list.clearRetainingCapacity();
    const fields = try self.csvLine.parse(line);
    if (what < VALUE) {
        for (self.keyIndices) |index| {
            try list.appendSlice(fields[index]);
            try list.append('|');
        }
    } else {
        for (self.valueIndices) |index| {
            try list.appendSlice(fields[index]);
            try list.append('|');
        }
    }
    return list.items;
}

fn keyMatches(self: *Self, entry: *SetEntry, hash: u64, key: []const u8) !bool {
    if (entry.hash == hash) {
        const storedKey = try self.getSelectedFields(KEY2, entry.line.?);
        if (std.mem.eql(u8, key, storedKey)) { //todo also chek values for equal -> error if not
            return true;
        }
    }
    return false;
}

pub fn valueMatches(self: *Self, entry: *SetEntry, line: []const u8) !bool {
    const value = try self.getSelectedFields(VALUE, line);
    const entryValue = try self.getSelectedFields(VALUE2, entry.line.?);
    return std.mem.eql(u8, value, entryValue);
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