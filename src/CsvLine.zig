const std = @import("std");

pub const Separator = struct {
    const comma: u8 = ',';
    const semicolon: u8 = ';';
    const tab: u8 = '\t';
    const pipe: u8 = '|';
};

pub const Quote = struct {
    const single: u8 = '\'';
    const double: u8 = '"';
    const none: ?u8 = null;
};

pub const Options = struct {
    separator: u8 = Separator.comma,
    quote: ?u8 = Quote.none,
    fields: usize = 16,
    trim: bool = false,
};

pub const ParserError = error{
    FoundEndOfLineAfterOpeningQuote,
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
        if (start_of_quoted_string(line, pos, self.options.quote)) |quote_pos| {
            start = quote_pos;
            end = end_of_quoted_string(line, quote_pos, self.options.quote.?);
            if (end_of_line(line, end)) return ParserError.FoundEndOfLineAfterOpeningQuote;

            const separator_pos = next_separator(line, end, self.options.separator);
            last_was_separator = separator_pos < line.len and line[separator_pos] == self.options.separator;
            pos = separator_pos + 1;
        } else {
            start = pos;
            end = next_separator(line, pos, self.options.separator);
            last_was_separator = end < line.len and line[end] == self.options.separator;
            pos = end + 1;
        }
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

inline fn start_of_quoted_string(line: []const u8, start: usize, quote: ?u8) ?usize {
    const quote_char = quote orelse return null;
    var pos = start;
    while (pos < line.len and line[pos] == ' ') {
        pos += 1;
    }
    if (pos >= line.len) {
        return null;
    }

    if (line[pos] == quote_char) {
        return pos + 1;
    }
    return null;
}

inline fn end_of_quoted_string(line: []const u8, start: usize, quote: u8) usize {
    var pos = start;
    while (pos < line.len and line[pos] != quote) {
        pos += 1;
    }
    return pos;
}

inline fn add_field(self: *Self, field: []const u8, index: usize) !void {
    if (index >= self.fields.len) {
        const new_len = if (self.fields.len == 0) 1 else self.fields.len * 2;
        self.fields = try self.allocator.realloc(self.fields, new_len);
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

test "basic quoted parsing" {
    var csvLine = try init(testing.allocator, .{ .quote = Quote.single });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("'1','2','3'"));
}

test "basic quoted parsing - spaces in fields" {
    var csvLine = try init(testing.allocator, .{ .quote = Quote.single });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ " 1", "2 ", " 3 " }, try csvLine.parse("' 1','2 ',' 3 '"));
}

test "basic quoted parsing - spaces outside fields" {
    var csvLine = try init(testing.allocator, .{ .quote = Quote.single });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3" }, try csvLine.parse("   '1','2' , '3'    "));
}

test "quoted parsing - expect error for non closed quote" {
    var csvLine = try init(testing.allocator, .{ .quote = Quote.single });
    defer csvLine.deinit();
    try testing.expectError(ParserError.FoundEndOfLineAfterOpeningQuote, csvLine.parse("'1,2,3"));
}

test "quoted parsing - trailing empty field" {
    var csvLine = try init(testing.allocator, .{ .quote = Quote.double });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "a", "" }, try csvLine.parse("\"1\",\"a\","));
    try expectEqualStringsArray(&[_][]const u8{ "1", "a", "x" }, try csvLine.parse("\"1\",\"a\",x"));
}

test "quoted parsing - field with only spaces at end of line" {
    var csvLine = try init(testing.allocator, .{ .quote = Quote.single });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "a", "   " }, try csvLine.parse("a,   "));
}

test "whitespace trimming" {
    var csvLine = try init(testing.allocator, .{ .trim = true });
    defer csvLine.deinit();
    try expectEqualStringsArray(&[_][]const u8{ "1", "2", "3", "", "", "" }, try csvLine.parse("\t1,2 , \t 3\t , ,\t,  \t \t"));
}
