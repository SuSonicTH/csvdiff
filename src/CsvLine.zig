const std = @import("std");

pub const Separator = struct {
    const comma: u8 = ',';
    const semicolon: u8 = ';';
    const tab: u8 = '\t';
    const pipe: u8 = '|';
};

pub const Quoute = struct {
    const single: u8 = '\'';
    const double: u8 = '"';
    const none: ?u8 = null;
};

pub const Options = struct {
    separator: u8 = Separator.comma,
    quoute: ?u8 = Quoute.none,
    fields: usize = 16,
    trim: bool = false,
};

pub const ParserError = error{
    FoundEndOfLineAfterOpeningQuoute,
    OutOfMemory,
};

const Self = @This();

allocator: std.mem.Allocator,
options: Options,
fields: [][]const u8,

pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
    return .{
        .allocator = allocator,
        .options = options,
        .fields = try allocator.alloc([]const u8, options.fields),
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.fields);
}

pub fn parse(self: *Self, line: []const u8) ParserError![][]const u8 {
    var index: usize = 0;
    var pos: usize = 0;
    var start: usize = 0;
    var end: usize = 0;
    var last_was_separator: bool = false;

    while (!end_of_line(line, pos)) {
        if (start_of_quouted_string(line, pos, self.options.quoute)) |quoute_pos| {
            start = quoute_pos;
            end = end_of_quoted_string(line, quoute_pos, self.options.quoute.?);
            if (end_of_line(line, end)) return ParserError.FoundEndOfLineAfterOpeningQuoute;
            pos = next_separator(line, end, self.options.separator) + 1;
        } else {
            start = pos;
            end = next_separator(line, pos, self.options.separator);
            pos = end + 1;
        }
        last_was_separator = end < line.len and line[end] == self.options.separator;
        if (self.options.trim) {
            try self.add_field(std.mem.trim(u8, line[start..end], " \t"), index);
        } else {
            try self.add_field(line[start..end], index);
        }

        index += 1;
    }

    if (last_was_separator) {
        try self.add_field("", index);
        index += 1;
    }

    return self.fields[0..index];
}

inline fn start_of_quouted_string(line: []const u8, start: usize, quoute: ?u8) ?usize {
    if (quoute == null) {
        return null;
    }
    var pos = start;
    while (pos < line.len and line[pos] == ' ') {
        pos += 1;
    }

    if (line[pos] == quoute.?) {
        pos = pos + 1;
        return pos;
    }
    return null;
}

inline fn end_of_quoted_string(line: []const u8, start: usize, quoute: u8) usize {
    var pos = start;
    while (!end_of_line(line, pos) and line[pos] != quoute) {
        pos += 1;
    }
    return pos;
}

inline fn add_field(self: *Self, field: []const u8, index: usize) !void {
    if (index >= self.fields.len) {
        self.fields = try self.allocator.realloc(self.fields, self.fields.len * 2);
    }
    self.fields[index] = field;
}

inline fn end_of_line(line: []const u8, pos: usize) bool {
    return pos >= line.len or line[pos] == '\r' or line[pos] == '\n';
}

fn next_separator(line: []const u8, start: usize, separator: u8) usize {
    var pos = start;
    while (!end_of_line(line, pos) and line[pos] != separator) {
        pos += 1;
    }
    return pos;
}

// Tests

const testing = std.testing;
const testUtils = @import("testUtils.zig");
const expectEqualStringsArray = testUtils.expectEqualStringsArray;

test "basic parsing" {
    var csvLine = try init(testing.allocator, .{});
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("1,2,3"));
}

test "basic parsing - first empty" {
    var csvLine = try init(testing.allocator, .{});
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "", "2", "3" }, try csvLine.parse(",2,3"));
}

test "basic parsing - middle empty" {
    var csvLine = try init(testing.allocator, .{});
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "", "3" }, try csvLine.parse("1,,3"));
}

test "basic parsing - last empty" {
    var csvLine = try init(testing.allocator, .{});
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "" }, try csvLine.parse("1,2,"));
}

test "basic parsing - all empty" {
    var csvLine = try init(testing.allocator, .{});
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "", "", "" }, try csvLine.parse(",,"));
}

test "basic parsing with tab separator" {
    var csvLine = try init(testing.allocator, .{ .separator = Separator.tab });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("1\t2\t3"));
}

test "basic parsing with semicolon separator" {
    var csvLine = try init(testing.allocator, .{ .separator = Separator.semicolon });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("1;2;3"));
}

test "basic parsing with pipe separator" {
    var csvLine = try init(testing.allocator, .{ .separator = Separator.pipe });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("1|2|3"));
}

test "basic quouted parsing" {
    var csvLine = try init(testing.allocator, .{ .quoute = Quoute.single });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("'1','2','3'"));
}

test "basic quouted parsing - spaces in fields" {
    var csvLine = try init(testing.allocator, .{ .quoute = Quoute.single });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ " 1", "2 ", " 3 " }, try csvLine.parse("' 1','2 ',' 3 '"));
}

test "basic quouted parsing - spaces outside fields" {
    var csvLine = try init(testing.allocator, .{ .quoute = Quoute.single });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("   '1','2' , '3'    "));
}

test "quouted parsing - expect error for non closed quoute" {
    var csvLine = try init(testing.allocator, .{ .quoute = Quoute.single });
    defer csvLine.deinit();
    try testing.expectError(ParserError.FoundEndOfLineAfterOpeningQuoute, csvLine.parse("'1,2,3"));
}

test "whitespace trimming" {
    var csvLine = try init(testing.allocator, .{ .trim = true });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3", "", "", "" }, try csvLine.parse("\t1,2 , \t 3\t , ,\t,  \t \t"));
}
