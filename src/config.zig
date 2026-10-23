const std = @import("std");
const Options = @import("options.zig").Options;
const builtin = @import("builtin");

const State = enum {
    searchStart,
    searchEnd,
    searchSingleQuote,
    searchDoubleQuote,
};

pub fn readConfigFromFile(io: std.Io, env: *const std.process.Environ.Map, name: []const u8, allocator: std.mem.Allocator) !std.array_list.Managed([]const u8) {
    const file = std.Io.Dir.cwd().openFile(io, name, .{}) catch blk: {
        if (name.len == 0 or name[0] == '/' or name[0] == '\\') {
            return error.FileNotFound;
        }

        break :blk try getConfigFileFromHome(io, env, name, allocator);
    };
    defer file.close(io);

    var reader_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);
    var config = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));

    var arguments = try std.array_list.Managed([]const u8).initCapacity(allocator, 10);
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
    var index: usize = 0;
    while (index < move) : (index += 1) {
        config[config.len - 1 - index] = ' ';
    }
}

fn getConfigFileFromHome(io: std.Io, env: *const std.process.Environ.Map, name: []const u8, allocator: std.mem.Allocator) !std.Io.File {
    if (env.get("CSVDIFF_CONFIG")) |config| {
        return openConfigFile(io, config, "", "", name, allocator);
    } else if (env.get("HOME")) |home| {
        return openConfigFile(io, home, ".config/csvdiff/", "", name, allocator);
    } else if (builtin.target.os.tag == .windows) {
        if (env.get("homedrive")) |homedrive| {
            if (env.get("homepath")) |homepath| {
                return openConfigFile(io, homedrive, homepath, ".config/csvdiff/", name, allocator);
            }
        }
    }
    return error.ReadingConfig;
}

fn openConfigFile(io: std.Io, home: []const u8, sub1: []const u8, sub2: []const u8, name: []const u8, allocator: std.mem.Allocator) !std.Io.File {
    var path = try std.array_list.Managed(u8).initCapacity(allocator, home.len + sub1.len + sub2.len + name.len + 3);
    defer path.deinit();

    try appendPathComponent(&path, home);
    try appendPathComponent(&path, sub1);
    try appendPathComponent(&path, sub2);
    try appendPathComponent(&path, name);

    if (path.items.len == 0) {
        return error.ReadingConfig;
    }
    return try std.Io.Dir.cwd().openFile(io, path.items, .{});
}

fn appendPathComponent(path: *std.array_list.Managed(u8), component: []const u8) !void {
    if (component.len == 0) {
        return;
    }
    if (path.items.len > 0) {
        const last = path.items[path.items.len - 1];
        if (last != '/' and last != '\\') {
            try path.append('/');
        }
    }
    try path.appendSlice(component);
}

test "reads it" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const arguments = try readConfigFromFile(std.testing.io, &env, "src/test/test.config", allocator);

    const expectEqualStrings = std.testing.expectEqualStrings;

    try expectEqualStrings("src/test/test.config", arguments.items[0]);
    try expectEqualStrings("--header", arguments.items[1]);
    try expectEqualStrings("1,2,3", arguments.items[2]);
    try expectEqualStrings("--trim", arguments.items[3]);
    try expectEqualStrings("-I", arguments.items[4]);
    try expectEqualStrings("quoted argument, with , spaces", arguments.items[5]);
    try expectEqualStrings("--include", arguments.items[6]);
    try expectEqualStrings("another one with spaces", arguments.items[7]);
    try expectEqualStrings("--separator", arguments.items[8]);
    try expectEqualStrings("tab", arguments.items[9]);
    try expectEqualStrings("this is 'escaped'", arguments.items[10]);
    try expectEqualStrings("--header", arguments.items[11]);
    try expectEqualStrings("one,two,three", arguments.items[12]);
    try expectEqualStrings("this_is#not_a_comment", arguments.items[13]);
    try expectEqualStrings("#also_not_a_comment", arguments.items[14]);
    try expectEqualStrings("--include", arguments.items[15]);
    try expectEqualStrings("eins,zwei,drei", arguments.items[16]);
}
