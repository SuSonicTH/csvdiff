const std = @import("std");
const CsvLine = @import("CsvLine.zig");

const Self = @This();

pub const SetEntry = struct {
    line: ?[]const u8,
    hash: u32,
    count: u32,
};

/// Extra rows for a key that occurs with more than one value. The common case
/// (one row per key) never allocates any of this.
const OverflowEntry = struct {
    entry: SetEntry,
    next: u32, // 1-based index into overflow, 0 terminates the chain
};

const LoadFactor = 0.7;

allocator: std.mem.Allocator,
csvLine: *CsvLine,
compareCsvLine: CsvLine,
keyIndices: []usize,
valueIndices: []usize,
data: []SetEntry,
mask: u32,
count: u32 = 0,
size: u5,
overflow: std.array_list.Managed(OverflowEntry),
overflowHeads: ?[]u32 = null,
hasOverflow: bool = false,

pub fn init(initialSize: usize, keyIndices: []usize, valueIndices: []usize, csvLine: *CsvLine, allocator: std.mem.Allocator) !Self {
    // Keep the table within 32 bit index/mask limits even for absurd input
    // sizes; it will grow via resize when needed.
    const size: u5 = @min(getNumberOfBits(initialSize), 30);

    const set: Self = .{
        .allocator = allocator,
        .csvLine = csvLine,
        .compareCsvLine = try CsvLine.init(allocator, csvLine.options),
        .keyIndices = keyIndices,
        .valueIndices = valueIndices,
        .data = try allocator.alloc(SetEntry, @as(u32, 1) << size),
        .mask = (@as(u32, 1) << size) - 1,
        .size = size,
        .overflow = std.array_list.Managed(OverflowEntry).init(allocator),
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
    if (@as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(@as(u32, 1) << bits)) > LoadFactor) {
        bits += 1;
    }
    return bits;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.data);
    self.overflow.deinit();
    if (self.overflowHeads) |heads| {
        self.allocator.free(heads);
    }
    self.compareCsvLine.deinit();
}

pub fn put(self: *Self, line: []const u8) !void {
    const fields = try self.csvLine.parse(line);
    const hash = self.computeKeyHash(fields);

    try self.putRow(line, fields, hash, 1);

    if (self.load() > LoadFactor) {
        try self.resize();
    }
}

/// Inserts a row without checking the load factor. Existing key+value rows
/// only get their count increased; a new value for an existing key is stored
/// in the overflow chain.
fn putRow(self: *Self, line: []const u8, fields: [][]const u8, hash: u32, count: u32) !void {
    const slot = try self.findSlot(hash, fields);

    if (!slot.found) {
        self.data[slot.index] = .{
            .line = line,
            .hash = hash,
            .count = count,
        };
        self.count += 1;
        return;
    }

    const primary = &self.data[slot.index];
    if (try self.valuesMatchFields(primary.line.?, fields)) {
        primary.count += count;
        return;
    }

    if (self.hasOverflow) {
        var head = self.overflowHeads.?[slot.index];
        while (head != 0) {
            const overflowEntry = &self.overflow.items[head - 1];
            if (try self.valuesMatchFields(overflowEntry.entry.line.?, fields)) {
                overflowEntry.entry.count += count;
                return;
            }
            head = overflowEntry.next;
        }
    }

    try self.appendOverflow(slot.index, line, hash, count);
}

pub fn get(self: *Self, line: []const u8) !?*SetEntry {
    const fields = try self.csvLine.parse(line);
    const hash = self.computeKeyHash(fields);
    const slot = try self.findSlot(hash, fields);
    if (!slot.found) return null;

    const primary = &self.data[slot.index];

    // Prefer an exact value match so that duplicate keys pair up correctly.
    if (primary.count > 0 and try self.valuesMatchFields(primary.line.?, fields)) {
        return primary;
    }

    if (self.hasOverflow) {
        var head = self.overflowHeads.?[slot.index];
        while (head != 0) {
            const overflowEntry = &self.overflow.items[head - 1];
            if (overflowEntry.entry.count > 0 and try self.valuesMatchFields(overflowEntry.entry.line.?, fields)) {
                return &overflowEntry.entry;
            }
            head = overflowEntry.next;
        }
    }

    // No exact match left: any remaining row with this key is a change
    // candidate.
    return self.takeFromSlot(slot.index);
}

/// Returns any remaining row with the same key, without comparing values.
/// Used after the exact-match pass, where all exact matches are already
/// consumed, so every returned row is a change candidate.
pub fn getFallback(self: *Self, line: []const u8) !?*SetEntry {
    const fields = try self.csvLine.parse(line);
    const hash = self.computeKeyHash(fields);
    const slot = try self.findSlot(hash, fields);
    if (!slot.found) return null;
    return self.takeFromSlot(slot.index);
}

pub fn takeFromSlot(self: *Self, slot: u32) ?*SetEntry {
    const primary = &self.data[slot];
    if (primary.count > 0) {
        return primary;
    }

    if (self.hasOverflow) {
        var head = self.overflowHeads.?[slot];
        while (head != 0) {
            const overflowEntry = &self.overflow.items[head - 1];
            if (overflowEntry.entry.count > 0) {
                return &overflowEntry.entry;
            }
            head = overflowEntry.next;
        }
    }
    return null;
}

pub const MatchResult = enum {
    exact,
    existing,
    missing,
};

pub const Match = struct {
    result: MatchResult,
    slot: u32,
};

/// Classifies a row from the second file and consumes an exact key+value
/// match when possible. `existing` means the key is present but no remaining
/// value matches; `missing` means the key is not present at all.
pub fn match(self: *Self, line: []const u8) !Match {
    const fields = try self.csvLine.parse(line);
    const hash = self.computeKeyHash(fields);
    const slot = try self.findSlot(hash, fields);
    if (!slot.found) return .{ .result = .missing, .slot = 0 };

    const primary = &self.data[slot.index];
    if (primary.count > 0 and try self.valuesMatchFields(primary.line.?, fields)) {
        primary.count -= 1;
        return .{ .result = .exact, .slot = slot.index };
    }

    if (self.hasOverflow) {
        var head = self.overflowHeads.?[slot.index];
        while (head != 0) {
            const overflowEntry = &self.overflow.items[head - 1];
            if (overflowEntry.entry.count > 0 and try self.valuesMatchFields(overflowEntry.entry.line.?, fields)) {
                overflowEntry.entry.count -= 1;
                return .{ .result = .exact, .slot = slot.index };
            }
            head = overflowEntry.next;
        }
    }
    return .{ .result = .existing, .slot = slot.index };
}

pub fn matchExact(self: *Self, line: []const u8) !bool {
    return (try self.match(line)).result == .exact;
}

pub fn eachRemaining(self: *Self, context: anytype, comptime func: fn (@TypeOf(context), *SetEntry) anyerror!void) !void {
    for (self.data, 0..) |*entry, slot| {
        if (entry.line != null and entry.count > 0) {
            try func(context, entry);
        }

        if (self.hasOverflow) {
            var head = self.overflowHeads.?[slot];
            while (head != 0) {
                const overflowEntry = &self.overflow.items[head - 1];
                if (overflowEntry.entry.count > 0) {
                    try func(context, &overflowEntry.entry);
                }
                head = overflowEntry.next;
            }
        }
    }
}

inline fn fieldAt(fields: [][]const u8, index: usize) []const u8 {
    return if (index < fields.len) fields[index] else "";
}

fn computeKeyHash(self: *Self, fields: [][]const u8) u32 {
    var hash: u32 = 2166136261;
    for (self.keyIndices) |index| {
        const value = fieldAt(fields, index);
        hash = (hash ^ std.hash.CityHash32.hash(value)) *% 16777619;
        hash = (hash ^ @as(u32, @truncate(value.len))) *% 16777619;
    }
    return hash;
}

inline fn keysMatchFields(self: *Self, entry: *SetEntry, fields: [][]const u8) !bool {
    const storedFields = try self.compareCsvLine.parse(entry.line.?);
    for (self.keyIndices) |index| {
        if (!std.mem.eql(u8, fieldAt(fields, index), fieldAt(storedFields, index))) {
            return false;
        }
    }
    return true;
}

pub inline fn valueMatches(self: *Self, entry: *SetEntry, line: []const u8) !bool {
    const fields = try self.csvLine.parse(line);
    return self.valuesMatchFields(entry.line.?, fields);
}

fn valuesMatchFields(self: *Self, storedLine: []const u8, fields: [][]const u8) !bool {
    if (self.valueIndices.len == 0) return true;

    const storedFields = try self.compareCsvLine.parse(storedLine);
    for (self.valueIndices) |index| {
        if (!std.mem.eql(u8, fieldAt(fields, index), fieldAt(storedFields, index))) {
            return false;
        }
    }
    return true;
}

const Slot = struct {
    index: u32,
    found: bool,
};

/// Finds the slot containing `key`, or the first empty slot where it would be
/// inserted. Uses the same linear probing as the original implementation.
fn findSlot(self: *Self, hash: u32, fields: [][]const u8) !Slot {
    const start: u32 = hash & self.mask;
    const len: u32 = @intCast(self.data.len);

    var index = start;
    var step: u32 = 0;
    while (step < len) : (step += 1) {
        const entry = &self.data[index];
        if (entry.line == null) {
            return .{ .index = index, .found = false };
        }
        if (entry.hash == hash and try self.keysMatchFields(entry, fields)) {
            return .{ .index = index, .found = true };
        }
        index = (index + 1) & self.mask;
    }

    @panic("HashSet is full");
}

fn ensureOverflowHeads(self: *Self) ![]u32 {
    if (self.overflowHeads) |heads| {
        return heads;
    }

    const heads = try self.allocator.alloc(u32, self.data.len);
    @memset(heads, 0);
    self.overflowHeads = heads;
    return heads;
}

fn appendOverflow(self: *Self, slot: u32, line: []const u8, hash: u32, count: u32) !void {
    const heads = try self.ensureOverflowHeads();
    const previousHead = heads[slot];

    try self.overflow.append(.{
        .entry = .{
            .line = line,
            .hash = hash,
            .count = count,
        },
        .next = previousHead,
    });

    heads[slot] = @intCast(self.overflow.items.len);
    self.hasOverflow = true;
}

pub inline fn load(self: *Self) f32 {
    if (self.count == 0) {
        return 0.0;
    }
    return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.data.len));
}

fn resize(self: *Self) !void {
    // The entry count and mask are 32 bit, so 31 is the largest usable size.
    if (self.size >= 31) {
        return error.MaximumHashSetSizeReached;
    }

    const oldData = self.data;
    const oldHeads = self.overflowHeads;
    var oldOverflow = self.overflow;

    self.overflow = std.array_list.Managed(OverflowEntry).init(self.allocator);
    self.overflowHeads = null;
    self.hasOverflow = false;

    self.size += 1;
    self.mask = (@as(u32, 1) << self.size) - 1;
    self.count = 0;
    self.data = try self.allocator.alloc(SetEntry, @as(u32, 1) << self.size);
    @memset(self.data, .{
        .line = null,
        .hash = 0,
        .count = 0,
    });

    for (oldData, 0..) |*entry, slot| {
        if (entry.line) |line| {
            const fields = try self.csvLine.parse(line);
            try self.putRow(line, fields, entry.hash, entry.count);
        }

        if (oldHeads) |heads| {
            var head = heads[slot];
            while (head != 0) {
                const overflowEntry = &oldOverflow.items[head - 1];
                const line = overflowEntry.entry.line.?;
                const fields = try self.csvLine.parse(line);
                try self.putRow(line, fields, overflowEntry.entry.hash, overflowEntry.entry.count);
                head = overflowEntry.next;
            }
        }
    }

    self.allocator.free(oldData);
    if (oldHeads) |heads| {
        self.allocator.free(heads);
    }
    oldOverflow.deinit();
}

test "getNumberOfBits" {
    try std.testing.expectEqual(0, getNumberOfBits(0));
    try std.testing.expectEqual(1, getNumberOfBits(1));
    try std.testing.expectEqual(2, getNumberOfBits(2));
    try std.testing.expectEqual(3, getNumberOfBits(3));
    try std.testing.expectEqual(3, getNumberOfBits(4));
    try std.testing.expectEqual(4, getNumberOfBits(8));
    try std.testing.expectEqual(5, getNumberOfBits(15));
    try std.testing.expectEqual(11, getNumberOfBits(1 << 10));
    try std.testing.expectEqual(25, getNumberOfBits(14976460));
}

const testing = std.testing;

test "put/get" {
    var csvLine = try CsvLine.init(testing.allocator, .{});
    defer csvLine.deinit();

    var keyIndices = [_]usize{0};
    var valueIndices = [_]usize{1};

    var set = try Self.init(4, &keyIndices, &valueIndices, &csvLine, testing.allocator);
    defer set.deinit();

    try set.put("1,a");
    try set.put("2,b");
    try set.put("1,a");

    try testing.expectEqual(2, (try set.get("1,a")).?.count);
    try testing.expectEqual(1, (try set.get("2,b")).?.count);
    try testing.expectEqual(null, try set.get("3,c"));
}

test "duplicate keys with different values are kept" {
    var csvLine = try CsvLine.init(testing.allocator, .{});
    defer csvLine.deinit();

    var keyIndices = [_]usize{0};
    var valueIndices = [_]usize{1};

    var set = try Self.init(4, &keyIndices, &valueIndices, &csvLine, testing.allocator);
    defer set.deinit();

    try set.put("1,a");
    try set.put("1,b");
    try set.put("1,a");

    const a = (try set.get("1,a")).?;
    try testing.expectEqual(2, a.count);

    const b = (try set.get("1,b")).?;
    try testing.expectEqual(1, b.count);

    try testing.expect(!try set.valueMatches(a, "1,b"));
}

test "fields containing the join separator do not collide" {
    var csvLine = try CsvLine.init(testing.allocator, .{});
    defer csvLine.deinit();

    var keyIndices = [_]usize{0};
    var valueIndices = [_]usize{ 1, 2 };

    var set = try Self.init(4, &keyIndices, &valueIndices, &csvLine, testing.allocator);
    defer set.deinit();

    try set.put("1,a|b,c");

    // No exact value match exists, so the lookup falls back to the key. The
    // values must still compare as different.
    const entry = (try set.get("1,a,b|c")).?;
    try testing.expect(!try set.valueMatches(entry, "1,a,b|c"));
}

test "eachRemaining reports unmatched rows" {
    var csvLine = try CsvLine.init(testing.allocator, .{});
    defer csvLine.deinit();

    var keyIndices = [_]usize{0};
    var valueIndices = [_]usize{1};

    var set = try Self.init(4, &keyIndices, &valueIndices, &csvLine, testing.allocator);
    defer set.deinit();

    try set.put("1,a");
    try set.put("2,b");

    const first = (try set.get("1,a")).?;
    first.count -= 1;

    const Collector = struct {
        lines: *std.array_list.Managed([]const u8),

        fn collect(context: @This(), entry: *SetEntry) anyerror!void {
            try context.lines.append(entry.line.?);
        }
    };

    var remaining = std.array_list.Managed([]const u8).init(testing.allocator);
    defer remaining.deinit();

    try set.eachRemaining(Collector{ .lines = &remaining }, Collector.collect);

    try testing.expectEqual(1, remaining.items.len);
    try testing.expectEqualStrings("2,b", remaining.items[0]);
}

test "overflow survives resize" {
    var csvLine = try CsvLine.init(testing.allocator, .{});
    defer csvLine.deinit();

    var keyIndices = [_]usize{0};
    var valueIndices = [_]usize{1};

    var set = try Self.init(1, &keyIndices, &valueIndices, &csvLine, testing.allocator);
    defer set.deinit();

    try set.put("1,a");
    try set.put("1,b");
    try set.put("1,a");

    // Force several resizes and make sure both values are still matchable.
    var index: usize = 2;
    while (index < 20) : (index += 1) {
        var key_buffer: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&key_buffer, "{d},v", .{index});
        try set.put(line);
    }

    try testing.expectEqual(2, (try set.get("1,a")).?.count);
    try testing.expectEqual(1, (try set.get("1,b")).?.count);
    try testing.expect(try set.matchExact("1,b"));
    try testing.expect(!try set.matchExact("1,b"));
}
