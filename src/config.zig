const std = @import("std");
const Options = @import("options.zig").Options;
const builtin = @import("builtin");

const State = enum {
    searchStart,
    searchEnd,
    searchSingleQuote,
    searchDoubleQuote,
};

pub fn readConfigFromFile(name: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    const file = std.fs.cwd().openFile(name, .{}) catch blk: {
        if (name[0] == '/' or name[0] == '\\') {
            return error.FileNotFound;
        }

        break :blk try getConfigFileFromHome(name, allocator);
    };
    defer file.close();

    var config = try file.readToEndAlloc(allocator, 1024 * 1024);

    var arguments = try std.ArrayList([]const u8).initCapacity(allocator, 10);
    try arguments.append(name);

    var pos: usize = 0;
    var start: usize = 0;
    var state: State = State.searchStart;
    var escape: bool = false;

    while (pos < config.len) {
        switch (config[pos]) {
            '\\' => {
                escape = !escape;
                pos += 1;
            },
            ' ', '\t' => {
                switch (state) {
                    .searchEnd => {
                        try arguments.append(config[start..pos]);
                        state = State.searchStart;
                    },
                    else => {},
                }
                pos += 1;
                escape = false;
            },
            '\r' => {
                switch (state) {
                    .searchEnd => {
                        if (!escape) {
                            try arguments.append(config[start..pos]);
                            state = State.searchStart;
                            pos += 1;
                        } else {
                            if (pos + 1 < config.len and config[pos + 1] == '\n') {
                                try moveToLeft(config, pos, 3);
                            } else {
                                try moveToLeft(config, pos, 2);
                            }
                        }
                    },
                    .searchDoubleQuote, .searchSingleQuote => {
                        pos += 1;
                        if (pos < config.len and config[pos] == '\n') {
                            try moveToLeft(config, pos, 2);
                            pos += 1;
                        } else {
                            try moveToLeft(config, pos, 1);
                        }
                    },
                    else => pos += 1,
                }
                escape = false;
            },
            '\n' => {
                switch (state) {
                    .searchEnd => {
                        if (!escape) {
                            try arguments.append(config[start..pos]);
                            state = State.searchStart;
                            pos += 1;
                        } else {
                            try moveToLeft(config, pos, 2);
                        }
                    },
                    .searchDoubleQuote, .searchSingleQuote => {
                        pos += 1;
                        try moveToLeft(config, pos, 1);
                    },
                    else => pos += 1,
                }
                escape = false;
            },
            '#' => {
                if (!escape) {
                    pos += 1;
                    while (pos < config.len and config[pos] != '\r' and config[pos] != '\n') {
                        pos += 1;
                    }
                } else {
                    try moveToLeft(config, pos, 1);
                    if (state == State.searchStart) {
                        start = pos - 1;
                        state = State.searchEnd;
                    }
                    escape = false;
                }
            },
            '"' => {
                if (!escape) {
                    pos += 1;
                    if (state == State.searchDoubleQuote) {
                        try arguments.append(config[start .. pos - 1]);
                        state = State.searchStart;
                    } else {
                        start = pos;
                        state = State.searchDoubleQuote;
                    }
                } else {
                    try moveToLeft(config, pos, 1);
                    escape = false;
                }
            },
            '\'' => {
                if (!escape) {
                    pos += 1;
                    if (state == State.searchSingleQuote) {
                        try arguments.append(config[start .. pos - 1]);
                        state = State.searchStart;
                    } else {
                        start = pos;
                        state = State.searchSingleQuote;
                    }
                } else {
                    try moveToLeft(config, pos, 1);
                    escape = false;
                }
            },
            else => {
                if (state == State.searchStart) {
                    start = pos;
                    state = State.searchEnd;
                }
                pos += 1;
                escape = false;
            },
        }
    }

    switch (state) {
        .searchStart => {},
        .searchEnd => try arguments.append(config[start..pos]),
        .searchSingleQuote => return error.expectedSingleQuoteFoudEOF,
        .searchDoubleQuote => return error.expectedDoubleQuoteFoudEOF,
    }

    return arguments;
}

inline fn moveToLeft(config: []u8, pos: usize, comptime move: u2) !void {
    std.mem.copyForwards(u8, config[pos - 1 ..], config[pos + move - 1 ..]);
    config[config.len - 1] = ' ';
    if (move == 2) {
        config[config.len - 2] = ' ';
    }
}

fn getConfigFileFromHome(name: []const u8, allocator: std.mem.Allocator) !std.fs.File {
    var envMap = try std.process.getEnvMap(allocator);
    defer envMap.deinit();

    if (envMap.get("CSVCUT_CONFIG")) |config| {
        return openConfigFile(config, "", "", name, allocator);
    } else if (envMap.get("HOME")) |home| {
        return openConfigFile(home, ".config/csvdiff/", "", name, allocator);
    } else if (builtin.os.tag == .windows) {
        if (envMap.get("homedrive")) |homedrive| {
            if (envMap.get("homepath")) |homepath| {
                return openConfigFile(homedrive, homepath, ".config/csvdiff/", name, allocator);
            }
        }
    }
    return error.ReadingConfig;
}

fn openConfigFile(home: []const u8, sub1: []const u8, sub2: []const u8, name: []const u8, allocator: std.mem.Allocator) !std.fs.File {
    var path = try std.ArrayList(u8).initCapacity(allocator, home.len + sub1.len + sub2.len + name.len + 3);
    defer path.deinit();

    try path.appendSlice(home);
    if (path.items[path.items.len - 1] != '/' and path.items[path.items.len - 1] != '\\') {
        try path.append('/');
    }

    try path.appendSlice(sub1);
    if (path.items[path.items.len - 1] != '/' and path.items[path.items.len - 1] != '\\') {
        try path.append('/');
    }

    try path.appendSlice(sub2);
    if (path.items[path.items.len - 1] != '/' and path.items[path.items.len - 1] != '\\') {
        try path.append('/');
    }

    try path.appendSlice(name);

    return try std.fs.cwd().openFile(path.items, .{});
}

test "reads it" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const arguments = try readConfigFromFile("test/test.config", allocator);

    const expectEqualStrings = std.testing.expectEqualStrings;

    try expectEqualStrings("--header", arguments.items[0]);
    try expectEqualStrings("1,2,3", arguments.items[1]);
    try expectEqualStrings("--trim", arguments.items[2]);
    try expectEqualStrings("-I", arguments.items[3]);
    try expectEqualStrings("quouted argument, with , spaces", arguments.items[4]);
    try expectEqualStrings("--include", arguments.items[5]);
    try expectEqualStrings("another one with spaces", arguments.items[6]);
    try expectEqualStrings("--separator", arguments.items[7]);
    try expectEqualStrings("tab", arguments.items[8]);
    try expectEqualStrings("this is 'escaped'", arguments.items[9]);
    try expectEqualStrings("--header", arguments.items[10]);
    try expectEqualStrings("one,two,three", arguments.items[11]);
    try expectEqualStrings("this_is#not_a_comment", arguments.items[12]);
    try expectEqualStrings("#also_not_a_comment", arguments.items[13]);
    try expectEqualStrings("--include", arguments.items[14]);
    try expectEqualStrings("eins,zwei,drei", arguments.items[15]);
}
