const std = @import("std");
const Self = @This();
const defaultSize = 128;

allocator: std.mem.Allocator,
buffer: []u8,
len: usize = 0,
separator: u8 = undefined,

pub fn init(allocator: std.mem.Allocator, separator: u8) !Self {
    return initSized(allocator, separator, defaultSize);
}

pub fn initSized(allocator: std.mem.Allocator, separator: u8, size: usize) !Self {
    const reseved = switch (size) {
        0 => defaultSize,
        else => size,
    };
    return .{
        .allocator = allocator,
        .buffer = try allocator.alloc(u8, reseved),
        .separator = separator,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.buffer);
}

pub inline fn add(self: *Self, string: []const u8) !void {
    try self.ensureLen(string.len + 1);
    if (self.len != 0) {
        self.buffer[self.len] = self.separator;
        self.len += 1;
    }
    @memcpy(self.buffer[self.len .. self.len + string.len], string);
    self.len += string.len;
}

pub inline fn get(self: *Self) []u8 {
    return self.buffer[0..self.len];
}

fn ensureLen(self: *Self, additionalLen: usize) !void {
    const minimalLen = self.len + additionalLen;
    if (self.buffer.len < minimalLen) {
        var newSize = self.buffer.len * 2;
        while (newSize < minimalLen) {
            newSize *= 2;
        }
        self.buffer = try self.allocator.realloc(self.buffer, newSize);
    }
}

pub fn clear(self: *Self) void {
    self.len = 0;
}

pub fn isEmpty(self: *Self) bool {
    return self.len == 0;
}

const testing = std.testing;

test "stringJoinerTest" {
    var joiner = try initSized(testing.allocator, ',', 1);
    defer joiner.deinit();

    try testing.expectEqualStrings("", joiner.get());
    try testing.expectEqual(true, joiner.isEmpty());
    try testing.expectEqual(0, joiner.len);
    try testing.expectEqual(1, joiner.buffer.len);

    try joiner.add("ABC");
    try testing.expectEqualStrings("ABC", joiner.get());
    try testing.expectEqual(false, joiner.isEmpty());
    try testing.expectEqual(3, joiner.len);
    try testing.expectEqual(4, joiner.buffer.len);

    try joiner.add("DEF");
    try testing.expectEqualStrings("ABC,DEF", joiner.get());
    try testing.expectEqual(7, joiner.len);
    try testing.expectEqual(8, joiner.buffer.len);

    try joiner.add("GHIJKLMNOPQRSTUVWXYZ");
    try testing.expectEqualStrings("ABC,DEF,GHIJKLMNOPQRSTUVWXYZ", joiner.get());
    try testing.expectEqual(28, joiner.len);
    try testing.expectEqual(32, joiner.buffer.len);

    joiner.clear();
    try testing.expectEqualStrings("", joiner.get());
    try testing.expectEqual(true, joiner.isEmpty());
    try testing.expectEqual(0, joiner.len);
    try testing.expectEqual(32, joiner.buffer.len);
}

test "stringJoinerTest init" {
    var joiner = try init(testing.allocator, ',');
    defer joiner.deinit();

    try testing.expectEqualStrings("", joiner.get());
    try testing.expectEqual(true, joiner.isEmpty());
    try testing.expectEqual(0, joiner.len);
    try testing.expectEqual(defaultSize, joiner.buffer.len);
}

test "stringJoinerTest initSized zero" {
    var joiner = try initSized(testing.allocator, ',', 0);
    defer joiner.deinit();

    try testing.expectEqualStrings("", joiner.get());
    try testing.expectEqual(true, joiner.isEmpty());
    try testing.expectEqual(0, joiner.len);
    try testing.expectEqual(defaultSize, joiner.buffer.len);
}
