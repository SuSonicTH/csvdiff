const std = @import("std");
const builtin = @import("builtin");
const Self = @This();

file: std.Io.File,
io: std.Io,
file_mapping: ?windows.HANDLE = null,

pub fn init(file: std.Io.File, io: std.Io, writeable: bool) !Self {
    if (builtin.target.os.tag == .windows) {
        // CreateFileMapping rejects zero length files; they are handled by
        // map() returning an empty slice.
        if ((try file.stat(io)).size == 0) {
            return .{
                .file = file,
                .io = io,
            };
        }

        const protection: windows.PAGE = if (writeable) .{ .READWRITE = true } else .{ .READONLY = true };
        const file_mapping = CreateFileMappingA(file.handle, null, @bitCast(protection), 0, 0, null);
        if (file_mapping == null) {
            return MemMapperError.CouldNotMapFile;
        }

        return .{
            .file = file,
            .io = io,
            .file_mapping = file_mapping.?,
        };
    } else {
        return .{
            .file = file,
            .io = io,
        };
    }
}

pub fn deinit(self: *Self) void {
    if (builtin.target.os.tag == .windows) {
        if (self.file_mapping) |file_mapping| {
            CloseHandle(file_mapping);
        }
    }
}

pub fn map(self: *Self, comptime T: type, options: Options) ![]T {
    const byteLen = if (options.size != 0)
        options.size * @sizeOf(T)
    else
        (try self.file.stat(self.io)).size;

    // mmap(2) rejects zero length mappings, and empty files are perfectly
    // valid input.
    if (byteLen == 0) {
        return @constCast(&[_]T{});
    }
    if (byteLen % @sizeOf(T) != 0) {
        return MemMapperError.InvalidMappingSize;
    }
    const len = byteLen / @sizeOf(T);

    if (builtin.target.os.tag == .windows) {
        var access: windows.DWORD = 0;
        if (options.read) access |= FILE_MAP_READ;
        if (options.write) access |= FILE_MAP_WRITE;

        const ptr = MapViewOfFile(self.file_mapping.?, access, 0, 0, byteLen);
        if (ptr == null) {
            return MemMapperError.CouldNotMapRegion;
        }
        const typed: [*]T = @ptrCast(@alignCast(ptr));
        return typed[0..len];
    } else {
        var prot: std.posix.PROT = .{};
        if (options.read) prot.READ = true;
        if (options.write) prot.WRITE = true;

        const bytes = try std.posix.mmap(null, byteLen, prot, .{ .TYPE = .SHARED }, self.file.handle, options.offset);
        const typed: [*]T = @ptrCast(@alignCast(bytes.ptr));
        return typed[0..len];
    }
}

pub fn unmap(self: *Self, memory: anytype) void {
    _ = self;
    const bytes = std.mem.sliceAsBytes(memory);
    if (bytes.len == 0) {
        return;
    }

    if (builtin.target.os.tag == .windows) {
        _ = UnmapViewOfFile(@constCast(bytes.ptr));
    } else {
        std.posix.munmap(@alignCast(bytes));
    }
}

pub const MemMapperError = error{
    CouldNotMapFile,
    CouldNotMapRegion,
    InvalidMappingSize,
};

pub const Options = struct {
    read: bool = true,
    write: bool = false,
    offset: usize = 0,
    size: usize = 0,
};

const windows = std.os.windows;

const FILE_MAP_READ: windows.DWORD = 4;
const FILE_MAP_WRITE: windows.DWORD = 2;

extern "kernel32" fn CreateFileMappingA(hFile: windows.HANDLE, lpFileMappingAttributes: ?*windows.SECURITY_ATTRIBUTES, flProtect: windows.DWORD, dwMaximumSizeHigh: windows.DWORD, dwMaximumSizeLow: windows.DWORD, lpNam: ?windows.LPCSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn MapViewOfFile(hFileMappingObject: windows.HANDLE, dwDesiredAccess: windows.DWORD, dwFileOffsetHigh: windows.DWORD, dwFileOffsetLow: windows.DWORD, dwNumberOfBytesToMa: windows.SIZE_T) callconv(.winapi) ?windows.LPVOID;
extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: windows.LPCVOID) callconv(.winapi) windows.BOOL;

const CloseHandle = windows.CloseHandle;

// Test

const testing = std.testing;

test "simple mapping for reading" {
    const message = "This is a Test";
    const fileName = "./src/test/MemMapperReading.txt";

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = fileName, .data = message });

    var file = try std.Io.Dir.cwd().openFile(testing.io, fileName, .{});
    defer file.close(testing.io);

    var mapper = try init(file, testing.io, false);
    defer mapper.deinit();

    const tst = try mapper.map(u8, .{});
    defer mapper.unmap(tst);

    try testing.expectEqualStrings(message, tst);
    try testing.expectEqual(14, tst.len);
}

test "mapping an empty file" {
    var file = try std.Io.Dir.cwd().openFile(testing.io, "./src/test/empty", .{});
    defer file.close(testing.io);

    var mapper = try init(file, testing.io, false);
    defer mapper.deinit();

    const data = try mapper.map(u8, .{});
    defer mapper.unmap(data);

    try testing.expectEqual(0, data.len);
}
