const std = @import("std");
const compat = @import("compat.zig");
const Io = std.Io;

/// File system operations for Home standard library
pub const File = struct {
    handle: Io.File,
    path: []const u8,
    allocator: std.mem.Allocator,
    io: Io,
    position: u64 = 0,
    append: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, mode: OpenMode) !*File {
        const io = compat.io();
        const handle = try Io.Dir.cwd().openFile(io, path, .{
            .mode = switch (mode) {
                .Read => .read_only,
                .Write, .Append => .write_only,
                .ReadWrite => .read_write,
            },
        });
        errdefer handle.close(io);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const position = if (mode == .Append) try handle.length(io) else 0;
        if (mode == .Append) try io.vtable.fileSeekTo(io.userdata, handle, position);
        const file = try allocator.create(File);

        file.* = .{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
            .position = position,
            .append = mode == .Append,
        };

        return file;
    }

    pub fn create(allocator: std.mem.Allocator, path: []const u8) !*File {
        const io = compat.io();
        const handle = try Io.Dir.cwd().createFile(io, path, .{});
        errdefer handle.close(io);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const file = try allocator.create(File);

        file.* = .{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };

        return file;
    }

    pub fn close(self: *File) void {
        self.handle.close(self.io);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Read from the current position until EOF, enforcing the caller's limit.
    pub fn readToString(self: *File, max_size: usize) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const allowance = @min(buffer.len, max_size - result.items.len +| 1);
            const count = try self.read(buffer[0..allowance]);
            if (count == 0) return result.toOwnedSlice(self.allocator);
            if (count > max_size - result.items.len) return error.StreamTooLong;
            try result.appendSlice(self.allocator, buffer[0..count]);
        }
    }

    /// Read file into a buffer
    pub fn read(self: *File, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        while (true) {
            const count = self.handle.readStreaming(self.io, &.{buffer}) catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => return err,
            };
            if (count == 0) continue;
            self.position += count;
            return count;
        }
    }

    /// Write bytes to file
    pub fn write(self: *File, data: []const u8) !usize {
        if (self.append) {
            self.position = try self.handle.length(self.io);
            try self.io.vtable.fileSeekTo(self.io.userdata, self.handle, self.position);
        }
        const count = try self.handle.writeStreaming(self.io, &.{}, &.{data}, 1);
        self.position += count;
        return count;
    }

    /// Write string to file
    pub fn writeString(self: *File, s: []const u8) !void {
        if (self.append) {
            self.position = try self.handle.length(self.io);
            try self.io.vtable.fileSeekTo(self.io.userdata, self.handle, self.position);
        }
        try self.handle.writeStreamingAll(self.io, s);
        self.position += s.len;
    }

    /// Seek to position in file
    pub fn seek(self: *File, pos: u64) !void {
        try self.io.vtable.fileSeekTo(self.io.userdata, self.handle, pos);
        self.position = pos;
    }

    /// Get current file position
    pub fn tell(self: *File) !u64 {
        return self.position;
    }

    /// Get file size
    pub fn size(self: *File) !u64 {
        return self.handle.length(self.io);
    }
};

pub const OpenMode = enum {
    Read,
    Write,
    Append,
    ReadWrite,
};

/// Directory operations
pub const Dir = struct {
    handle: Io.Dir,
    path: []const u8,
    allocator: std.mem.Allocator,
    io: Io,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Dir {
        const io = compat.io();
        const handle = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer handle.close(io);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const dir = try allocator.create(Dir);

        dir.* = .{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };

        return dir;
    }

    pub fn close(self: *Dir) void {
        self.handle.close(self.io);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Create a directory
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try Io.Dir.cwd().createDir(compat.io(), path, .default_dir);
    }

    /// Create directory and all parent directories
    pub fn createAll(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try Io.Dir.cwd().createDirPath(compat.io(), path);
    }

    /// List directory contents
    pub fn list(self: *Dir) ![]DirEntry {
        var entries: std.ArrayList(DirEntry) = .empty;
        // Free previously-duped names if any subsequent dupe/append
        // fails before we can hand ownership to the caller.
        errdefer {
            for (entries.items) |e| self.allocator.free(e.name);
            entries.deinit(self.allocator);
        }

        var iter = self.handle.iterate();
        while (try iter.next(self.io)) |entry| {
            const name_copy = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name_copy);
            try entries.append(self.allocator, .{
                .name = name_copy,
                .kind = switch (entry.kind) {
                    .file => .File,
                    .directory => .Directory,
                    .sym_link => .SymLink,
                    else => .Unknown,
                },
            });
        }

        return entries.toOwnedSlice(self.allocator);
    }

    /// Check if file exists
    pub fn exists(allocator: std.mem.Allocator, path: []const u8) bool {
        _ = allocator;
        Io.Dir.cwd().access(compat.io(), path, .{}) catch return false;
        return true;
    }

    /// Delete a file
    pub fn deleteFile(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try Io.Dir.cwd().deleteFile(compat.io(), path);
    }

    /// Delete a directory
    pub fn deleteDir(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try Io.Dir.cwd().deleteDir(compat.io(), path);
    }

    /// Delete directory and all contents recursively
    pub fn deleteDirAll(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try Io.Dir.cwd().deleteTree(compat.io(), path);
    }

    /// Copy file
    pub fn copyFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
        _ = allocator;
        const cwd = Io.Dir.cwd();
        try cwd.copyFile(src, cwd, dest, compat.io(), .{ .replace = true });
    }

    /// Rename/move file
    pub fn rename(allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) !void {
        _ = allocator;
        const cwd = Io.Dir.cwd();
        try cwd.rename(old_path, cwd, new_path, compat.io());
    }
};

pub const DirEntry = struct {
    name: []const u8,
    kind: EntryKind,
};

pub const EntryKind = enum {
    File,
    Directory,
    SymLink,
    Unknown,
};

/// Path manipulation utilities
pub const Path = struct {
    /// Join path components
    pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        return try std.fs.path.join(allocator, parts);
    }

    /// Get directory name from path
    pub fn dirname(path: []const u8) []const u8 {
        return std.fs.path.dirname(path) orelse ".";
    }

    /// Get file name from path
    pub fn basename(path: []const u8) []const u8 {
        return std.fs.path.basename(path);
    }

    /// Get file extension
    pub fn extension(path: []const u8) []const u8 {
        return std.fs.path.extension(path);
    }

    /// Check if path is absolute
    pub fn isAbsolute(path: []const u8) bool {
        return std.fs.path.isAbsolute(path);
    }

    /// Get absolute path
    pub fn absolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const len = try Io.Dir.cwd().realPathFile(compat.io(), path, &buffer);
        return allocator.dupe(u8, buffer[0..len]);
    }
};

/// Convenient file operations
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try File.open(allocator, path, .Read);
    defer file.close();
    return file.readToString(100 * 1024 * 1024);
}

pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const file = try File.create(allocator, path);
    defer file.close();
    try file.writeString(data);
}

pub fn appendFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const file = try File.open(allocator, path, .Append);
    defer file.close();
    try file.writeString(data);
}
