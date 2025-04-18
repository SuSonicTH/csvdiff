const std = @import("std");
const testing = std.testing;

pub fn expectEqualStringsArray(expected: []const []const u8, actual: [][]const u8) !void {
    try testing.expect(expected.len <= actual.len);
    for (expected, 0..) |exp, idx| {
        try testing.expectEqualStrings(exp, actual[idx]);
    }
    try testing.expectEqual(expected.len, actual.len);
}

pub fn writeFile(file_path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try file.writeAll(data);
}
