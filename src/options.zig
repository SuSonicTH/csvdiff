const std = @import("std");
const CsvLine = @import("CsvLine.zig");

const Selection = union(enum) {
    name: []const u8,
    index: usize,
};

const OptionError = error{
    NoSuchField,
    NoHeader,
};

pub const Colors = struct {
    red: []const u8 = "\x1B[31m",
    green: []const u8 = "\x1B[32m",
    blue: []const u8 = "\x1B[34m",
    reset: []const u8 = "\x1B[0m",

    pub fn get(colors: bool) Colors {
        if (!colors) {
            return .{
                .red = "",
                .green = "",
                .blue = "",
                .reset = "",
            };
        }
        return .{};
    }
};

pub const FieldType = enum {
    KEY,
    VALUE,
    EXCLUDED,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    csvLine: ?CsvLine = null,
    inputSeparator: [1]u8 = .{','},
    inputQuote: ?[1]u8 = null,
    fileHeader: bool = true,
    header: ?[][]const u8 = null,
    columnCount: ?usize = null,
    keyFields: ?SelectionList = null,
    excludedFields: ?SelectionList = null,
    keyIndices: ?[]usize = null,
    valueIndices: ?[]usize = null,
    fieldTypes: ?[]FieldType = null,
    trim: bool = false,
    listHeader: bool = false,
    inputFiles: std.array_list.Managed([]const u8),
    time: bool = false,
    color: bool = false,
    asCsv: bool = false,
    diffSpaceing: u8 = ' ',
    fieldDiff: bool = false,
    outputAll: bool = false,
    stats: bool = false,

    // Values are kept here until all arguments are known, so that --trim,
    // --quote and similar options work regardless of their order.
    pendingHeader: ?[]const u8 = null,
    pendingKeys: std.array_list.Managed([]const u8),
    pendingExcludes: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) !Options {
        return .{
            .allocator = allocator,
            .inputFiles = std.array_list.Managed([]const u8).init(allocator),
            .pendingKeys = std.array_list.Managed([]const u8).init(allocator),
            .pendingExcludes = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Options) void {
        self.inputFiles.deinit();
        self.pendingKeys.deinit();
        self.pendingExcludes.deinit();
        if (self.keyFields) |keyFields| {
            keyFields.deinit();
        }
        if (self.excludedFields) |excludedFields| {
            excludedFields.deinit();
        }
        if (self.valueIndices) |valueIndices| {
            self.allocator.free(valueIndices);
        }
        if (self.fieldTypes) |fieldTypes| {
            self.allocator.free(fieldTypes);
        }
        if (self.header) |header| {
            self.allocator.free(header);
        }
        if (self.csvLine != null) {
            self.csvLine.?.deinit();
        }
    }

    /// Parses all deferred command line selections. Must be called after the
    /// last argument has been processed and before calculateFieldIndices.
    pub fn finalize(self: *Options) !void {
        if (self.pendingHeader) |header| {
            try self.setHeader(header);
            self.pendingHeader = null;
        }
        for (self.pendingKeys.items) |fields| {
            try self.addKey(fields);
        }
        self.pendingKeys.clearRetainingCapacity();
        for (self.pendingExcludes.items) |fields| {
            try self.addExclude(fields);
        }
        self.pendingExcludes.clearRetainingCapacity();
    }

    pub fn setAsCsv(self: *Options, asCsv: bool) void {
        self.asCsv = asCsv;
        if (self.asCsv) {
            self.diffSpaceing = self.inputSeparator[0];
        }
    }

    fn getCsvLine(self: *Options, separator: u8) !*CsvLine {
        const csvOptions: CsvLine.Options = .{
            .separator = separator,
            .trim = self.trim,
            .quote = if (self.inputQuote) |quote| quote[0] else null,
        };

        if (self.csvLine == null) {
            self.csvLine = try CsvLine.init(self.allocator, csvOptions);
        } else {
            self.csvLine.?.options = csvOptions;
        }
        return &(self.csvLine.?);
    }

    /// Selection lists are normally comma separated. When the user selected a
    /// different input separator and the value contains it, use that separator
    /// instead so `-s ';' --header 'A;B'` works as expected.
    fn parseSelectionList(self: *Options, fields: []const u8) ![][]const u8 {
        const separator = if (self.inputSeparator[0] != ',' and
            std.mem.indexOfScalar(u8, fields, self.inputSeparator[0]) != null)
            self.inputSeparator[0]
        else
            ',';
        return (try self.getCsvLine(separator)).parse(fields);
    }

    pub fn setHeader(self: *Options, header: []const u8) !void {
        const fields = try self.parseSelectionList(header);
        if (fields.len == 0) {
            return error.InvalidFieldSelection;
        }
        if (self.header) |old| {
            self.allocator.free(old);
            self.header = null;
        }
        self.header = try self.allocator.dupe([]const u8, fields);
    }

    pub fn setHeaderFields(self: *Options, fields: [][]const u8) !void {
        if (self.header) |old| {
            self.allocator.free(old);
            self.header = null;
        }
        self.header = try self.allocator.dupe([]const u8, fields);
    }

    pub fn setPendingHeader(self: *Options, header: []const u8) void {
        self.pendingHeader = header;
        self.fileHeader = false;
    }

    pub fn addPendingKey(self: *Options, fields: []const u8) !void {
        try self.pendingKeys.append(fields);
    }

    pub fn addPendingExclude(self: *Options, fields: []const u8) !void {
        try self.pendingExcludes.append(fields);
    }

    pub fn addKey(self: *Options, fields: []const u8) !void {
        if (self.keyFields) |*keyFields| {
            try self.appendSelections(keyFields, fields);
        } else {
            var keyFields = try SelectionList.init(self.allocator);
            errdefer keyFields.deinit();
            try self.appendSelections(&keyFields, fields);
            self.keyFields = keyFields;
        }
    }

    pub fn addExclude(self: *Options, fields: []const u8) !void {
        if (self.excludedFields) |*excludedFields| {
            try self.appendSelections(excludedFields, fields);
        } else {
            var excludedFields = try SelectionList.init(self.allocator);
            errdefer excludedFields.deinit();
            try self.appendSelections(&excludedFields, fields);
            self.excludedFields = excludedFields;
        }
    }

    fn appendSelections(self: *Options, list: *SelectionList, fields: []const u8) !void {
        const parsed = try self.parseSelectionList(fields);
        if (parsed.len == 0) {
            return error.InvalidFieldSelection;
        }
        for (parsed) |field| {
            try list.append(field);
        }
    }

    pub fn calculateFieldIndices(self: *Options) !void {
        if (self.valueIndices) |old| {
            self.allocator.free(old);
            self.valueIndices = null;
        }
        if (self.fieldTypes) |old| {
            self.allocator.free(old);
            self.fieldTypes = null;
        }

        var excludedIndices = std.AutoHashMap(usize, bool).init(self.allocator);
        defer excludedIndices.deinit();

        if (self.keyFields) |*keyFields| {
            self.keyIndices = try keyFields.calculateIndices(self.header);
            for (self.keyIndices.?) |index| {
                try excludedIndices.put(index, true);
            }
        } else {
            self.keyIndices = null;
        }

        if (self.excludedFields) |*excludedFields| {
            for (try excludedFields.calculateIndices(self.header)) |index| {
                try excludedIndices.put(index, true);
            }
        }

        // Without a header the width is learnt from the first data line, which
        // keeps index based selections working with --noHeader.
        const headerLen = if (self.header) |header| header.len else (self.columnCount orelse 0);

        var count: usize = 0;
        for (0..headerLen) |index| {
            if (!excludedIndices.contains(index)) {
                count += 1;
            }
        }

        self.valueIndices = try self.allocator.alloc(usize, count);
        var valueIndex: usize = 0;
        for (0..headerLen) |index| {
            if (!excludedIndices.contains(index)) {
                self.valueIndices.?[valueIndex] = index;
                valueIndex += 1;
            }
        }

        if (self.fieldDiff and headerLen > 0) {
            self.fieldTypes = try self.allocator.alloc(FieldType, headerLen);
            for (0..headerLen) |index| {
                self.fieldTypes.?[index] = self.getFieldType(index);
            }
        }
    }

    fn getFieldType(self: *Options, index: usize) FieldType {
        if (self.keyIndices) |keyIndices| {
            for (keyIndices) |key| {
                if (key == index) {
                    return .KEY;
                }
            }
        }
        if (self.valueIndices) |valueIndices| {
            for (valueIndices) |value| {
                if (value == index) {
                    return .VALUE;
                }
            }
        }
        return .EXCLUDED;
    }

    pub fn getColors(self: *Options) Colors {
        return Colors.get(self.color);
    }
};

const SelectionList = struct {
    allocator: std.mem.Allocator,
    list: std.array_list.Managed(Selection),
    indices: ?[]usize = null,

    pub fn init(allocator: std.mem.Allocator) !SelectionList {
        return .{
            .allocator = allocator,
            .list = std.array_list.Managed(Selection).init(allocator),
        };
    }

    pub fn deinit(self: *const SelectionList) void {
        self.list.deinit();
        if (self.indices) |indices| {
            self.allocator.free(indices);
        }
    }

    pub fn append(self: *SelectionList, field: []const u8) !void {
        if (field.len == 0) {
            return error.InvalidFieldSelection;
        }

        if (isRange(field)) |minusPos| {
            try addRange(&self.list, field, minusPos);
        } else if (toNumber(field)) |index| {
            if (index == 0) {
                return error.InvalidFieldSelection;
            }
            try self.list.append(.{ .index = index - 1 });
        } else if (field[0] == '\\') {
            if (field.len == 1) {
                return error.InvalidFieldSelection;
            }
            try self.list.append(.{ .name = field[1..] });
        } else {
            try self.list.append(.{ .name = field });
        }
    }

    pub fn calculateIndices(self: *SelectionList, header: ?[][]const u8) ![]usize {
        if (self.indices) |old| {
            self.allocator.free(old);
            self.indices = null;
        }

        self.indices = try self.allocator.alloc(usize, self.list.items.len);
        for (self.list.items, 0..) |item, i| {
            switch (item) {
                .index => |index| self.indices.?[i] = index,
                .name => |name| self.indices.?[i] = try getHeaderIndex(header, name),
            }
        }
        return self.indices.?;
    }

    fn isRange(field: []const u8) ?usize {
        if (field.len < 3) return null;
        var minusPos: ?usize = null;
        for (field, 0..) |char, index| {
            if (std.mem.indexOfScalar(u8, "0123456789-", char)) |pos| {
                if (pos == 10 and index > 0 and index < field.len - 1) {
                    minusPos = index;
                }
            } else {
                return null;
            }
        }
        return minusPos;
    }

    fn addRange(list: *std.array_list.Managed(Selection), field: []const u8, minusPos: usize) !void {
        const from = toNumber(field[0..minusPos]) orelse return error.InvalidFieldSelection;
        const to = toNumber(field[minusPos + 1 ..]) orelse return error.InvalidFieldSelection;

        if (from == 0 or to == 0 or from > to) {
            return error.InvalidFieldSelection;
        }

        var index = from;
        while (index <= to) {
            try list.append(.{ .index = index - 1 });
            if (index == to) break;
            index += 1;
        }
    }

    fn toNumber(field: []const u8) ?usize {
        return std.fmt.parseInt(usize, field, 10) catch null;
    }

    fn getHeaderIndex(header: ?[][]const u8, search: []const u8) OptionError!usize {
        if (header == null) {
            return OptionError.NoHeader;
        }

        return for (header.?, 0..) |field, index| {
            if (std.mem.eql(u8, field, search)) {
                break index;
            }
        } else OptionError.NoSuchField;
    }
};

const testing = std.testing;

test "rejects empty and zero based selections" {
    var options = try Options.init(testing.allocator);
    defer options.deinit();

    try testing.expectError(error.InvalidFieldSelection, options.addKey(""));
    try testing.expectError(error.InvalidFieldSelection, options.addKey("1,"));
    try testing.expectError(error.InvalidFieldSelection, options.addKey("0"));
    try testing.expectError(error.InvalidFieldSelection, options.addKey("0-2"));
    try testing.expectError(error.InvalidFieldSelection, options.addKey("3-1"));
}

test "defers selection parsing until finalize" {
    var options = try Options.init(testing.allocator);
    defer options.deinit();

    try options.addPendingKey("A, B");
    try options.addPendingExclude("C");
    options.trim = true;
    options.setPendingHeader("A,B,C,D");
    try options.finalize();

    try testing.expectEqual(2, options.keyFields.?.list.items.len);
    try testing.expectEqual(1, options.excludedFields.?.list.items.len);
    try testing.expectEqual(4, options.header.?.len);
    try testing.expectEqualStrings("A", options.keyFields.?.list.items[0].name);
    try testing.expectEqualStrings("B", options.keyFields.?.list.items[1].name);
    try testing.expect(!options.fileHeader);
}

test "ranges expand" {
    var list = try SelectionList.init(testing.allocator);
    defer list.deinit();

    try list.append("2-4");
    try testing.expectEqual(3, list.list.items.len);
    try testing.expectEqual(1, list.list.items[0].index);
    try testing.expectEqual(3, list.list.items[2].index);
}

test "selection lists honour a custom separator" {
    var options = try Options.init(testing.allocator);
    defer options.deinit();

    options.inputSeparator = .{';'};
    try options.addPendingKey("A;B");
    options.setPendingHeader("A;B;C");
    try options.finalize();

    try testing.expectEqual(2, options.keyFields.?.list.items.len);
    try testing.expectEqual(3, options.header.?.len);
}
