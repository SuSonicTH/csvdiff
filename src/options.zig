const std = @import("std");
const CsvLine = @import("CsvLine").CsvLine;

const Selection = union(enum) {
    name: []const u8,
    index: usize,
};

const OptionError = error{
    NoSuchField,
    NoHeader,
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
    excludedIndices: ?std.AutoHashMap(usize, bool) = null,
    trim: bool = false,
    listHeader: bool = false,
    inputFiles: std.ArrayList([]const u8),
    outputName: ?[]const u8 = null,
    time: bool = false,

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
        if (self.keyIndices) |keyIndices| {
            self.allocator.free(keyIndices);
        }
        if (self.excludedFields) |selectedFields| {
            selectedFields.deinit();
        }
        if (self.excludedIndices != null) {
            self.excludedIndices.?.deinit();
        }
        if (self.header) |header| {
            self.allocator.free(header);
        }
        if (self.csvLine != null) {
            self.csvLine.?.free();
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
        if (self.keyFields != null) {
            self.keyIndices = try self.includedFields.?.calculateIndices(self.header);
        }
        if (self.excludedFields != null) {
            self.excludedIndices = std.AutoHashMap(usize, bool).init(self.allocator);
            for (try self.excludedFields.?.calculateIndices(self.header)) |index| {
                try self.excludedIndices.?.put(index, true);
            }
        }
    }

    pub fn setInputLimit(self: *Options, value: []const u8) !void {
        self.inputLimit = try std.fmt.parseInt(usize, value, 10);
    }

    pub fn setOutputLimit(self: *Options, value: []const u8) !void {
        self.outputLimit = try std.fmt.parseInt(usize, value, 10);
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
