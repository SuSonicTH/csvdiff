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

const Colors = struct {
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
    inputQuoute: ?[1]u8 = null,
    fileHeader: bool = true,
    header: ?[][]const u8 = null,
    keyFields: ?SelectionList = null,
    excludedFields: ?SelectionList = null,
    keyIndices: ?[]usize = null,
    valueIndices: ?[]usize = null,
    fieldTypes: ?[]FieldType = null,
    trim: bool = false,
    listHeader: bool = false,
    inputFiles: std.ArrayList([]const u8),
    time: bool = false,
    color: bool = false,
    asCsv: bool = false,
    diffSpaceing: u8 = ' ',
    fieldDiff: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Options {
        return .{
            .allocator = allocator,
            .inputFiles = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Options) void {
        self.inputFiles.deinit();
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

    pub fn setAsCsv(self: *Options, asCsv: bool) void {
        self.asCsv = asCsv;
        if (self.asCsv) {
            self.diffSpaceing = self.inputSeparator[0];
        }
    }

    fn getCsvLine(self: *Options) !*CsvLine {
        if (self.csvLine == null) {
            self.csvLine = try CsvLine.init(self.allocator, .{ .trim = self.trim });
        }
        return &(self.csvLine.?);
    }

    pub fn setHeader(self: *Options, header: []const u8) !void {
        self.header = try self.allocator.dupe([]const u8, try (try self.getCsvLine()).parse(header));
    }

    pub fn setHeaderFields(self: *Options, fields: [][]const u8) !void {
        self.header = try self.allocator.dupe([]const u8, fields);
    }

    pub fn addKey(self: *Options, fields: []const u8) !void {
        if (self.keyFields == null) {
            self.keyFields = try SelectionList.init(self.allocator);
        }
        for ((try (try self.getCsvLine()).parse(fields))) |field| {
            try self.keyFields.?.append(field);
        }
    }

    pub fn addExclude(self: *Options, fields: []const u8) !void {
        if (self.excludedFields == null) {
            self.excludedFields = try SelectionList.init(self.allocator);
        }
        for ((try (try self.getCsvLine()).parse(fields))) |field| {
            try self.excludedFields.?.append(field);
        }
    }

    pub fn calculateFieldIndices(self: *Options) !void {
        var excludedIndices = std.AutoHashMap(usize, bool).init(self.allocator);
        defer excludedIndices.deinit();

        if (self.keyFields != null) {
            self.keyIndices = try self.keyFields.?.calculateIndices(self.header);
            for (self.keyIndices.?) |index| {
                try excludedIndices.put(index, true);
            }
        }

        if (self.excludedFields != null) {
            for (try self.excludedFields.?.calculateIndices(self.header)) |index| {
                try excludedIndices.put(index, true);
            }
        }

        var count: usize = 0;
        for (0..self.header.?.len) |index| {
            if (!excludedIndices.contains(index)) {
                count += 1;
            }
        }

        self.valueIndices = try self.allocator.alloc(usize, count);
        count = 0;
        for (0..self.header.?.len) |index| {
            if (!excludedIndices.contains(index)) {
                self.valueIndices.?[count] = index;
                count += 1;
            }
        }

        if (self.fieldDiff) {
            self.fieldTypes = try self.allocator.alloc(FieldType, self.header.?.len);
            for (0..self.header.?.len) |index| {
                self.fieldTypes.?[index] = self.getFieldType(index);
            }
        }
    }

    fn getFieldType(self: *Options, index: usize) FieldType {
        for (self.keyIndices.?) |key| {
            if (key == index) {
                return .KEY;
            }
        }
        for (self.valueIndices.?) |value| {
            if (value == index) {
                return .VALUE;
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
    list: std.ArrayList(Selection),
    indices: ?[]usize = null,

    pub fn init(allocator: std.mem.Allocator) !SelectionList {
        return .{
            .allocator = allocator,
            .list = std.ArrayList(Selection).init(allocator),
        };
    }

    pub fn deinit(self: *const SelectionList) void {
        self.list.deinit();
        if (self.indices) |indices| {
            self.allocator.free(indices);
        }
    }

    pub fn append(self: *SelectionList, field: []const u8) !void {
        if (isRange(field)) |minusPos| {
            try addRange(&self.list, field, minusPos);
        } else if (toNumber(field)) |index| {
            try self.list.append(.{ .index = index - 1 });
        } else if (field[0] == '\\') {
            try self.list.append(.{ .name = field[1..] });
        } else {
            try self.list.append(.{ .name = field });
        }
    }

    pub fn calculateIndices(self: *SelectionList, header: ?[][]const u8) ![]usize {
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

    fn addRange(list: *std.ArrayList(Selection), field: []const u8, miusPos: usize) !void {
        if (toNumber(field[0..miusPos])) |from| {
            if (toNumber(field[miusPos + 1 ..])) |to| {
                for (from..to + 1) |index| {
                    try list.append(.{ .index = index - 1 });
                }
            }
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
