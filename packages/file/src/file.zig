// File I/O Library for Home Language
// Provides comprehensive file operations, directory management, and path utilities

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// ==================== Core Types ====================

/// File handle with automatic cleanup
pub const File = struct {
    handle: std.fs.File,
    path: []const u8,
    allocator: Allocator,
    io: ?Io = null,

    /// Open a file for reading
    pub fn open(allocator: Allocator, path: []const u8, io: ?Io) !File {
        const io_val = io orelse return error.Unexpected;
        const cwd = Io.Dir.cwd();
        const handle = try cwd.openFile(io_val, path, .{});
        const owned_path = try allocator.dupe(u8, path);
        return File{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Create a new file for writing (truncates if exists)
    pub fn create(allocator: Allocator, path: []const u8, io: ?Io) !File {
        const io_val = io orelse return error.Unexpected;
        const cwd = Io.Dir.cwd();
        const handle = try cwd.createFile(io_val, path, .{});
        const owned_path = try allocator.dupe(u8, path);
        return File{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Open file for appending
    pub fn openForAppend(allocator: Allocator, path: []const u8, io: ?Io) !File {
        const io_val = io orelse return error.Unexpected;
        const cwd = Io.Dir.cwd();
        const handle = try cwd.openFile(io_val, path, .{ .mode = .write_only });
        try handle.seekFromEnd(0);
        const owned_path = try allocator.dupe(u8, path);
        return File{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Close the file and cleanup
    pub fn close(self: *File) void {
        if (self.io) |io_val| {
            self.handle.close(io_val);
        }
        self.allocator.free(self.path);
    }

    /// Read entire file contents into memory (caller owns the memory)
    pub fn readAll(self: *File) ![]u8 {
        const stat = try self.handle.stat();
        const file_size = stat.size;
        const buffer = try self.allocator.alloc(u8, file_size);
        errdefer self.allocator.free(buffer);

        var total_read: usize = 0;
        while (total_read < file_size) {
            const bytes_read = try self.handle.read(buffer[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        if (total_read != file_size) {
            return error.UnexpectedEndOfFile;
        }

        return buffer;
    }

    /// Read file line by line (caller owns returned slice and all lines)
    pub fn readLines(self: *File) ![][]const u8 {
        const content = try self.readAll();
        defer self.allocator.free(content);

        var lines: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (lines.items) |line| {
                self.allocator.free(line);
            }
            lines.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const owned_line = try self.allocator.dupe(u8, line);
            try lines.append(self.allocator, owned_line);
        }

        return lines.toOwnedSlice(self.allocator);
    }

    /// Read up to buffer.len bytes
    pub fn read(self: *File, buffer: []u8) !usize {
        return try self.handle.read(buffer);
    }

    /// Write bytes to file
    pub fn write(self: *File, bytes: []const u8) !void {
        try self.handle.writeAll(bytes);
    }

    /// Write a line to file (adds newline)
    pub fn writeLine(self: *File, line: []const u8) !void {
        try self.handle.writeAll(line);
        try self.handle.writeAll("\n");
    }

    /// Get file size in bytes
    pub fn size(self: *File) !u64 {
        const stat = try self.handle.stat();
        return stat.size;
    }

    /// Seek to position from start
    pub fn seekTo(self: *File, pos: u64) !void {
        try self.handle.seekTo(pos);
    }

    /// Get current file position
    pub fn getPos(self: *File) !u64 {
        return try self.handle.getPos();
    }

    /// Sync file to disk
    pub fn sync(self: *File) !void {
        try self.handle.sync();
    }
};

// ==================== Convenience Functions ====================

/// Read entire file into string (caller owns the memory)
pub fn readToString(allocator: Allocator, path: []const u8, io: ?Io) ![]u8 {
    var file = try File.open(allocator, path, io);
    defer file.close();
    return try file.readAll();
}

/// Read file as lines (caller owns returned slice and all lines)
pub fn readLines(allocator: Allocator, path: []const u8, io: ?Io) ![][]const u8 {
    var file = try File.open(allocator, path, io);
    defer file.close();
    return try file.readLines();
}

/// Write string to file (creates or truncates)
pub fn writeString(allocator: Allocator, path: []const u8, content: []const u8, io: ?Io) !void {
    var file = try File.create(allocator, path, io);
    defer file.close();
    try file.write(content);
}

/// Append string to file
pub fn appendString(allocator: Allocator, path: []const u8, content: []const u8, io: ?Io) !void {
    var file = try File.openForAppend(allocator, path, io);
    defer file.close();
    try file.write(content);
}

/// Write lines to file (each gets a newline)
pub fn writeLines(allocator: Allocator, path: []const u8, lines: []const []const u8, io: ?Io) !void {
    var file = try File.create(allocator, path, io);
    defer file.close();
    for (lines) |line| {
        try file.writeLine(line);
    }
}

// ==================== Directory Operations ====================

pub const Dir = struct {
    handle: std.fs.Dir,
    path: []const u8,
    allocator: Allocator,
    io: ?Io = null,

    /// Open a directory
    pub fn open(allocator: Allocator, path: []const u8, io: ?Io) !Dir {
        const io_val = io orelse return error.Unexpected;
        const cwd = Io.Dir.cwd();
        const handle = try cwd.openDir(io_val, path, .{ .iterate = true });
        const owned_path = try allocator.dupe(u8, path);
        return Dir{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Close directory
    pub fn close(self: *Dir) void {
        if (self.io) |io_val| {
            self.handle.close(io_val);
        }
        self.allocator.free(self.path);
    }

    /// List all entries in directory (caller owns returned slice and all names)
    pub fn list(self: *Dir) ![][]const u8 {
        const io_val = self.io orelse return error.Unexpected;
        var entries: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry);
            }
            entries.deinit(self.allocator);
        }

        var iter = self.handle.iterate();
        while (try iter.next(io_val)) |entry| {
            const owned_name = try self.allocator.dupe(u8, entry.name);
            try entries.append(self.allocator, owned_name);
        }

        return entries.toOwnedSlice(self.allocator);
    }
};

/// Create a directory (fails if exists)
pub fn createDir(path: []const u8, io: ?Io) !void {
    const io_val = io orelse return error.Unexpected;
    const cwd = Io.Dir.cwd();
    try cwd.makeDir(io_val, path);
}

/// Create directory and all parent directories
pub fn createDirAll(path: []const u8, io: ?Io) !void {
    const io_val = io orelse return error.Unexpected;
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io_val, path);
}

/// Remove a directory (must be empty)
pub fn removeDir(path: []const u8, io: ?Io) !void {
    const io_val = io orelse return error.Unexpected;
    const cwd = Io.Dir.cwd();
    try cwd.deleteDir(io_val, path);
}

/// Remove directory and all contents recursively
pub fn removeDirAll(path: []const u8, io: ?Io) !void {
    const io_val = io orelse return error.Unexpected;
    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io_val, path);
}

/// List directory entries (caller owns returned slice and all names)
pub fn listDir(allocator: Allocator, path: []const u8, io: ?Io) ![][]const u8 {
    var dir = try Dir.open(allocator, path, io);
    defer dir.close();
    return try dir.list();
}

// ==================== File System Operations ====================

/// Check if path exists
pub fn exists(path: []const u8, io: ?Io) bool {
    const io_val = io orelse return false;
    const cwd = Io.Dir.cwd();
    cwd.access(io_val, path, .{}) catch return false;
    return true;
}

/// Check if path is a file
pub fn isFile(path: []const u8, io: ?Io) bool {
    const io_val = io orelse return false;
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io_val, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Check if path is a directory
pub fn isDir(path: []const u8, io: ?Io) bool {
    const io_val = io orelse return false;
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io_val, path, .{}) catch return false;
    dir.close(io_val);
    return true;
}

/// Delete a file
pub fn deleteFile(path: []const u8, io: ?Io) !void {
    const io_val = io orelse return error.Unexpected;
    const cwd = Io.Dir.cwd();
    try cwd.deleteFile(io_val, path);
}

/// Copy a file
pub fn copyFile(allocator: Allocator, src: []const u8, dest: []const u8, io: ?Io) !void {
    const content = try readToString(allocator, src, io);
    defer allocator.free(content);
    try writeString(allocator, dest, content, io);
}

/// Move/rename a file
pub fn moveFile(src: []const u8, dest: []const u8, io: ?Io) !void {
    const io_val = io orelse return error.Unexpected;
    const cwd = Io.Dir.cwd();
    try cwd.rename(io_val, src, dest);
}

/// Get file metadata
pub const FileInfo = struct {
    size: u64,
    kind: std.fs.File.Kind,
    modified: i96,
    accessed: i96,
    created: i96,
};

pub fn getFileInfo(path: []const u8, io: ?Io) !FileInfo {
    const io_val = io orelse return error.Unexpected;
    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(io_val, path, .{});
    return FileInfo{
        .size = stat.size,
        .kind = stat.kind,
        .modified = stat.mtime.nanoseconds,
        .accessed = stat.atime.nanoseconds,
        .created = stat.ctime.nanoseconds,
    };
}

// ==================== Path Utilities ====================

pub const Path = struct {
    /// Join path components (caller owns returned memory)
    pub fn join(allocator: Allocator, parts: []const []const u8) ![]u8 {
        return try std.fs.path.join(allocator, parts);
    }

    /// Get directory name from path (caller owns returned memory)
    pub fn dirname(allocator: Allocator, path: []const u8) ![]u8 {
        const dir = std.fs.path.dirname(path) orelse ".";
        return try allocator.dupe(u8, dir);
    }

    /// Get base name from path (caller owns returned memory)
    pub fn basename(allocator: Allocator, path: []const u8) ![]u8 {
        const base = std.fs.path.basename(path);
        return try allocator.dupe(u8, base);
    }

    /// Get file extension (caller owns returned memory)
    pub fn extension(allocator: Allocator, path: []const u8) ![]u8 {
        const ext = std.fs.path.extension(path);
        return try allocator.dupe(u8, ext);
    }

    /// Get absolute path (caller owns returned memory)
    pub fn absolute(allocator: Allocator, path: []const u8, io: ?Io) ![]u8 {
        const io_val = io orelse return error.Unexpected;
        const cwd = Io.Dir.cwd();
        return try cwd.realpathAlloc(io_val, allocator, path);
    }

    /// Check if path is absolute
    pub fn isAbsolute(path: []const u8) bool {
        return std.fs.path.isAbsolute(path);
    }
};

// ==================== Tests ====================

test "File - create and read" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    const test_path = "test_file.txt";
    const test_content = "Hello, World!";

    // Clean up any existing test file
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io_val, test_path) catch {};
    defer cwd.deleteFile(io_val, test_path) catch {};

    // Write file
    try writeString(allocator, test_path, test_content, io_val);

    // Read file
    const content = try readToString(allocator, test_path, io_val);
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}

test "File - write and read lines" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    const test_path = "test_lines.txt";
    const test_lines = [_][]const u8{ "Line 1", "Line 2", "Line 3" };

    // Clean up
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io_val, test_path) catch {};
    defer cwd.deleteFile(io_val, test_path) catch {};

    // Write lines
    try writeLines(allocator, test_path, &test_lines, io_val);

    // Read lines
    const lines = try readLines(allocator, test_path);
    defer {
        for (lines) |line| {
            allocator.free(line);
        }
        allocator.free(lines);
    }

    // writeLine adds newline, so last line will be empty - filter it
    var non_empty_count: usize = 0;
    for (lines) |line| {
        if (line.len > 0) non_empty_count += 1;
    }

    try testing.expectEqual(@as(usize, 3), non_empty_count);
    try testing.expectEqualStrings("Line 1", lines[0]);
    try testing.expectEqualStrings("Line 2", lines[1]);
    try testing.expectEqualStrings("Line 3", lines[2]);
}

test "File - append" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    const test_path = "test_append.txt";

    // Clean up
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io_val, test_path) catch {};
    defer cwd.deleteFile(io_val, test_path) catch {};

    // Write initial content
    try writeString(allocator, test_path, "Initial\n", io_val);

    // Append content
    try appendString(allocator, test_path, "Appended", io_val);

    // Read and verify
    const content = try readToString(allocator, test_path, io_val);
    defer allocator.free(content);

    try testing.expectEqualStrings("Initial\nAppended", content);
}

test "Directory - create and list" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    const test_dir = "test_dir";

    // Clean up
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io_val, test_dir) catch {};
    defer cwd.deleteTree(io_val, test_dir) catch {};

    // Create directory
    try createDir(test_dir, io_val);

    // Create some files
    try writeString(allocator, test_dir ++ "/file1.txt", "content1", io_val);
    try writeString(allocator, test_dir ++ "/file2.txt", "content2", io_val);

    // List directory
    const entries = try listDir(allocator, test_dir, io_val);
    defer {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "Path - utilities" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Join paths
    const joined = try Path.join(allocator, &[_][]const u8{ "foo", "bar", "baz.txt" });
    defer allocator.free(joined);

    // Get basename
    const base = try Path.basename(allocator, joined);
    defer allocator.free(base);
    try testing.expectEqualStrings("baz.txt", base);

    // Get extension
    const ext = try Path.extension(allocator, joined);
    defer allocator.free(ext);
    try testing.expectEqualStrings(".txt", ext);
}

test "File - exists and delete" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    const test_path = "test_exists.txt";

    // Clean up
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io_val, test_path) catch {};

    // File shouldn't exist
    try testing.expect(!exists(test_path, io_val));

    // Create file
    try writeString(allocator, test_path, "test", io_val);

    // Now it should exist
    try testing.expect(exists(test_path, io_val));
    try testing.expect(isFile(test_path, io_val));
    try testing.expect(!isDir(test_path, io_val));

    // Delete it
    try deleteFile(test_path, io_val);

    // Should not exist anymore
    try testing.expect(!exists(test_path, io_val));
}

test "File - copy and move" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    const src_path = "test_src.txt";
    const copy_path = "test_copy.txt";
    const move_path = "test_move.txt";
    const test_content = "test content";

    // Clean up
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io_val, src_path) catch {};
    cwd.deleteFile(io_val, copy_path) catch {};
    cwd.deleteFile(io_val, move_path) catch {};
    defer {
        cwd.deleteFile(io_val, src_path) catch {};
        cwd.deleteFile(io_val, copy_path) catch {};
        cwd.deleteFile(io_val, move_path) catch {};
    }

    // Create source file
    try writeString(allocator, src_path, test_content, io_val);

    // Copy file
    try copyFile(allocator, src_path, copy_path, io_val);
    try testing.expect(exists(copy_path, io_val));

    const copy_content = try readToString(allocator, copy_path, io_val);
    defer allocator.free(copy_content);
    try testing.expectEqualStrings(test_content, copy_content);

    // Move file
    try moveFile(copy_path, move_path, io_val);
    try testing.expect(!exists(copy_path, io_val));
    try testing.expect(exists(move_path, io_val));
}

test "File - metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    const test_path = "test_meta.txt";
    const test_content = "Hello, metadata!";

    // Clean up
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io_val, test_path) catch {};
    defer cwd.deleteFile(io_val, test_path) catch {};

    // Create file
    try writeString(allocator, test_path, test_content, io_val);

    // Get metadata
    const info = try getFileInfo(test_path, io_val);

    try testing.expectEqual(@as(u64, test_content.len), info.size);
    try testing.expectEqual(std.fs.File.Kind.file, info.kind);
}
