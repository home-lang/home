const std = @import("std");

/// File system operations for Ion standard library
pub const File = struct {
    handle: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, mode: OpenMode) !*File {
        const file = try allocator.create(File);

        const std_mode: std.fs.File.OpenFlags = switch (mode) {
            .Read => .{ .mode = .read_only },
            .Write => .{ .mode = .write_only },
            .Append => .{ .mode = .write_only },
            .ReadWrite => .{ .mode = .read_write },
        };

        file.* = .{
            .handle = try std.fs.cwd().openFile(path, std_mode),
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };

        return file;
    }

    pub fn create(allocator: std.mem.Allocator, path: []const u8) !*File {
        const file = try allocator.create(File);

        file.* = .{
            .handle = try std.fs.cwd().createFile(path, .{}),
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };

        return file;
    }

    pub fn close(self: *File) void {
        self.handle.close();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Read entire file into a string
    pub fn readToString(self: *File, max_size: usize) ![]u8 {
        return try self.handle.readToEndAlloc(self.allocator, max_size);
    }

    /// Read file into a buffer
    pub fn read(self: *File, buffer: []u8) !usize {
        return try self.handle.read(buffer);
    }

    /// Write bytes to file
    pub fn write(self: *File, data: []const u8) !usize {
        return try self.handle.write(data);
    }

    /// Write string to file
    pub fn writeString(self: *File, s: []const u8) !void {
        _ = try self.handle.writeAll(s);
    }

    /// Seek to position in file
    pub fn seek(self: *File, pos: u64) !void {
        try self.handle.seekTo(pos);
    }

    /// Get current file position
    pub fn tell(self: *File) !u64 {
        return try self.handle.getPos();
    }

    /// Get file size
    pub fn size(self: *File) !u64 {
        const stat = try self.handle.stat();
        return stat.size;
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
    handle: std.fs.Dir,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Dir {
        const dir = try allocator.create(Dir);

        dir.* = .{
            .handle = try std.fs.cwd().openDir(path, .{ .iterate = true }),
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };

        return dir;
    }

    pub fn close(self: *Dir) void {
        self.handle.close();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Create a directory
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try std.fs.cwd().makeDir(path);
    }

    /// Create directory and all parent directories
    pub fn createAll(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try std.fs.cwd().makePath(path);
    }

    /// List directory contents
    pub fn list(self: *Dir) ![]DirEntry {
        var entries = std.ArrayList(DirEntry).init(self.allocator);

        var iter = self.handle.iterate();
        while (try iter.next()) |entry| {
            try entries.append(.{
                .name = try self.allocator.dupe(u8, entry.name),
                .kind = switch (entry.kind) {
                    .file => .File,
                    .directory => .Directory,
                    .sym_link => .SymLink,
                    else => .Unknown,
                },
            });
        }

        return entries.toOwnedSlice();
    }

    /// Check if file exists
    pub fn exists(allocator: std.mem.Allocator, path: []const u8) bool {
        _ = allocator;
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// Delete a file
    pub fn deleteFile(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try std.fs.cwd().deleteFile(path);
    }

    /// Delete a directory
    pub fn deleteDir(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try std.fs.cwd().deleteDir(path);
    }

    /// Delete directory and all contents recursively
    pub fn deleteDirAll(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        try std.fs.cwd().deleteTree(path);
    }

    /// Copy file
    pub fn copyFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
        _ = allocator;
        try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
    }

    /// Rename/move file
    pub fn rename(allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) !void {
        _ = allocator;
        try std.fs.cwd().rename(old_path, new_path);
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
        return try std.fs.cwd().realpathAlloc(allocator, path);
    }
};

/// Convenient file operations
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB limit
}

pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    _ = allocator;
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

pub fn appendFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    _ = allocator;
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(data);
}
