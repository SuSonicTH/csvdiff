const std = @import("std");
const CsvLine = @import("CsvLine").CsvLine;
const StringJoiner = @import("StringJoiner.zig");

const Self = @This();

pub const SetEntry = struct {
    line: ?[]const u8,
    hash: u32,
    count: u32,
};

const FieldType = enum(u3) {
    KEY,
    KEY2,
    KEY3,
    VALUE,
    VALUE2,
};

const LoadFactor = 0.7;

allocator: std.mem.Allocator,
csvLine: CsvLine,
keyIndices: []usize,
valueIndices: []usize,
data: []SetEntry,
mask: u32,
count: u32 = 0,
size: u5,
fieldValue: [5]StringJoiner = undefined,

pub fn init(initialSize: usize, keyIndices: []usize, valueIndices: []usize, csvLine: CsvLine, allocator: std.mem.Allocator) !Self {
    const size = getNumberOfBits(initialSize);
    var set: Self = .{
        .allocator = allocator,
        .csvLine = csvLine,
        .keyIndices = keyIndices,
        .valueIndices = valueIndices,
        .data = try allocator.alloc(SetEntry, @as(u32, 1) << size),
        .mask = (@as(u32, 1) << size) - 1,
        .size = size,
    };

    inline for (0..@intFromEnum(FieldType.VALUE2) + 1) |index| {
        set.fieldValue[index] = try StringJoiner.init(allocator, '|', 1024);
    }

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
    if (@as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(@as(u32, 1) << bits)) > LoadFactor) {
        bits += 1;
    }
    return bits;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.data);
    inline for (0..@intFromEnum(FieldType.VALUE2) + 1) |index| {
        self.fieldValue[index].deinit();
    }
}

pub inline fn put(self: *Self, line: []const u8) !void {
    const key = try self.getSelectedFields(.KEY, line);
    const hash: u32 = @truncate(std.hash.RapidHash.hash(0, key));
    try self.putHash(line, hash, key, 1);
    if (self.load() > LoadFactor) {
        try self.resize();
    }
}

pub fn get(self: *Self, line: []const u8) !?*SetEntry {
    const key = try self.getSelectedFields(.KEY, line);
    const hash: u32 = @truncate(std.hash.RapidHash.hash(0, key));
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

fn putHash(self: *Self, line: []const u8, hash: u32, key: []const u8, count: u32) !void {
    const index = hash & self.mask;
    var entry: *SetEntry = &self.data[index];

    if (entry.line == null) {
        updateEntry(entry, hash, line, count);
        self.count += 1;
    } else if (try self.keyMatches(entry, hash, key)) {
        if (!try self.valueMatches(entry, line)) {
            _ = try std.io.getStdOut().writer().print("{s}\n{s}\n", .{ line, entry.line.? });
            return error.duplicateKeyDifferentValues1;
        }
        entry.count += 1;
        return;
    } else {
        if (try self.linearProbe(index + 1, self.data.len, hash, key)) |nextEntry| {
            if (nextEntry.line != null and !try self.valueMatches(nextEntry, line)) {
                return error.duplicateKeyDifferentValues2;
            }
            updateEntry(nextEntry, hash, line, count);
        } else if (try self.linearProbe(0, index, hash, key)) |nextEntry| {
            if (nextEntry.line != null and !try self.valueMatches(nextEntry, line)) {
                return error.duplicateKeyDifferentValues3;
            }
            updateEntry(nextEntry, hash, line, count);
        } else {
            @panic("HashSet is full");
        }
        self.count += 1;
    }
}

inline fn linearProbe(self: *Self, start: u64, end: u64, hash: u32, key: []const u8) !?*SetEntry {
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

pub inline fn load(self: *Self) f32 {
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
    self.mask = (@as(u32, 1) << self.size) - 1;
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
            const storedKey = try self.getSelectedFields(.KEY3, entry.line.?);
            try self.putHash(entry.line.?, entry.hash, storedKey, entry.count);
        }
    }

    self.allocator.free(old);
}

pub inline fn getSelectedFields(self: *Self, comptime fieldType: FieldType, line: []const u8) ![]const u8 {
    const indices: []usize = if (fieldType == .VALUE or fieldType == .VALUE2) self.valueIndices else self.keyIndices;

    var joiner: *StringJoiner = &self.fieldValue[@intFromEnum(fieldType)];
    joiner.clear();

    const fields = try self.csvLine.parse(line);

    try joiner.add(fields[indices[0]]);
    for (1..indices.len) |index| {
        try joiner.add(fields[indices[index]]);
    }
    return joiner.get();
}

inline fn keyMatches(self: *Self, entry: *SetEntry, hash: u32, key: []const u8) !bool {
    if (entry.hash == hash) {
        const storedKey = try self.getSelectedFields(.KEY2, entry.line.?);
        if (std.mem.eql(u8, key, storedKey)) { //todo also chek values for equal -> error if not
            return true;
        }
    }
    return false;
}

pub inline fn valueMatches(self: *Self, entry: *SetEntry, line: []const u8) !bool {
    const value = try self.getSelectedFields(.VALUE, line);
    const entryValue = try self.getSelectedFields(.VALUE2, entry.line.?);
    return std.mem.eql(u8, value, entryValue);
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
