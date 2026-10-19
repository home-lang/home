// File I/O Library for Home Language
// Provides comprehensive file operations, directory management, and path utilities

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// ==================== Core Types ====================

/// File handle with automatic cleanup
pub const File = struct {
    handle: Io.File,
    path: []const u8,
    allocator: Allocator,
    io: Io,
    position: u64 = 0,

    /// Open a file for reading
    pub fn open(allocator: Allocator, path: []const u8, io: Io) !File {
        const cwd = Io.Dir.cwd();
        const handle = try cwd.openFile(io, path, .{});
        errdefer handle.close(io);
        const owned_path = try allocator.dupe(u8, path);
        return File{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Create a new file for writing (truncates if exists)
    pub fn create(allocator: Allocator, path: []const u8, io: Io) !File {
        const cwd = Io.Dir.cwd();
        const handle = try cwd.createFile(io, path, .{});
        errdefer handle.close(io);
        const owned_path = try allocator.dupe(u8, path);
        return File{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Open file for appending
    pub fn openForAppend(allocator: Allocator, path: []const u8, io: Io) !File {
        const cwd = Io.Dir.cwd();
        const handle = try cwd.openFile(io, path, .{ .mode = .write_only });
        errdefer handle.close(io);
        const stat = try handle.stat(io);
        const owned_path = try allocator.dupe(u8, path);
        return File{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
            .io = io,
            .position = stat.size,
        };
    }

    /// Close the file and cleanup
    pub fn close(self: *File) void {
        self.handle.close(self.io);
        self.allocator.free(self.path);
    }

    /// Read entire file contents into memory (caller owns the memory)
    pub fn readAll(self: *File) ![]u8 {
        const stat = try self.handle.stat(self.io);
        const remaining = stat.size -| self.position;
        const buffer = try self.allocator.alloc(u8, std.math.cast(usize, remaining) orelse return error.FileTooBig);
        errdefer self.allocator.free(buffer);

        var total_read: usize = 0;
        while (total_read < buffer.len) {
            const bytes_read = try self.read(buffer[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        if (total_read != buffer.len) {
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
        const count = try self.handle.readPositional(self.io, &.{buffer}, self.position);
        self.position += count;
        return count;
    }

    /// Write bytes to file
    pub fn write(self: *File, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const count = try self.handle.writePositional(self.io, &.{bytes[written..]}, self.position);
            if (count == 0) return error.UnexpectedWriteZero;
            self.position += count;
            written += count;
        }
    }

    /// Write a line to file (adds newline)
    pub fn writeLine(self: *File, line: []const u8) !void {
        try self.write(line);
        try self.write("\n");
    }

    /// Get file size in bytes
    pub fn size(self: *File) !u64 {
        const stat = try self.handle.stat(self.io);
        return stat.size;
    }

    /// Seek to position from start
    pub fn seekTo(self: *File, pos: u64) !void {
        self.position = pos;
    }

    /// Get current file position
    pub fn getPos(self: *File) !u64 {
        return self.position;
    }

    /// Sync file to disk
    pub fn sync(self: *File) !void {
        try self.handle.sync(self.io);
    }
};

// ==================== Convenience Functions ====================

/// Read entire file into string (caller owns the memory)
pub fn readToString(allocator: Allocator, path: []const u8, io: Io) ![]u8 {
    var file = try File.open(allocator, path, io);
    defer file.close();
    return try file.readAll();
}

/// Read file as lines (caller owns returned slice and all lines)
pub fn readLines(allocator: Allocator, path: []const u8, io: Io) ![][]const u8 {
    var file = try File.open(allocator, path, io);
    defer file.close();
    return try file.readLines();
}

/// Write string to file (creates or truncates)
pub fn writeString(allocator: Allocator, path: []const u8, content: []const u8, io: Io) !void {
    var file = try File.create(allocator, path, io);
    defer file.close();
    try file.write(content);
}

/// Append string to file
pub fn appendString(allocator: Allocator, path: []const u8, content: []const u8, io: Io) !void {
    var file = try File.openForAppend(allocator, path, io);
    defer file.close();
    try file.write(content);
}

/// Write lines to file (each gets a newline)
pub fn writeLines(allocator: Allocator, path: []const u8, lines: []const []const u8, io: Io) !void {
    var file = try File.create(allocator, path, io);
    defer file.close();
    for (lines) |line| {
        try file.writeLine(line);
    }
}

// ==================== Directory Operations ====================

pub const Dir = struct {
    handle: Io.Dir,
    path: []const u8,
    allocator: Allocator,
    io: Io,

    /// Open a directory
    pub fn open(allocator: Allocator, path: []const u8, io: Io) !Dir {
        const cwd = Io.Dir.cwd();
        const handle = try cwd.openDir(io, path, .{ .iterate = true });
        errdefer handle.close(io);
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
        self.handle.close(self.io);
        self.allocator.free(self.path);
    }

    /// List all entries in directory (caller owns returned slice and all names)
    pub fn list(self: *Dir) ![][]const u8 {
        var entries: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry);
            }
            entries.deinit(self.allocator);
        }

        var iter = self.handle.iterate();
        while (try iter.next(self.io)) |entry| {
            const owned_name = try self.allocator.dupe(u8, entry.name);
            try entries.append(self.allocator, owned_name);
        }

        return entries.toOwnedSlice(self.allocator);
    }
};

/// Create a directory (fails if exists)
pub fn createDir(path: []const u8, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDir(io, path, .default_dir);
}

/// Create directory and all parent directories
pub fn createDirAll(path: []const u8, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, path);
}

/// Remove a directory (must be empty)
pub fn removeDir(path: []const u8, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.deleteDir(io, path);
}

/// Remove directory and all contents recursively
pub fn removeDirAll(path: []const u8, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io, path);
}

/// List directory entries (caller owns returned slice and all names)
pub fn listDir(allocator: Allocator, path: []const u8, io: Io) ![][]const u8 {
    var dir = try Dir.open(allocator, path, io);
    defer dir.close();
    return try dir.list();
}

// ==================== File System Operations ====================

/// Check if path exists
pub fn exists(path: []const u8, io: Io) bool {
    const cwd = Io.Dir.cwd();
    cwd.access(io, path, .{}) catch return false;
    return true;
}

/// Check if path is a file
pub fn isFile(path: []const u8, io: Io) bool {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Check if path is a directory
pub fn isDir(path: []const u8, io: Io) bool {
    const cwd = Io.Dir.cwd();
    const dir = cwd.openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Delete a file
pub fn deleteFile(path: []const u8, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.deleteFile(io, path);
}

/// Copy a file
pub fn copyFile(allocator: Allocator, src: []const u8, dest: []const u8, io: Io) !void {
    const content = try readToString(allocator, src, io);
    defer allocator.free(content);
    try writeString(allocator, dest, content, io);
}

/// Move/rename a file
pub fn moveFile(src: []const u8, dest: []const u8, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.rename(src, cwd, dest, io);
}

/// Get file metadata
pub const FileInfo = struct {
    size: u64,
    kind: Io.File.Kind,
    modified: i96,
    accessed: ?i96,
    /// Filesystem metadata-change time, not birth time.
    changed: i96,
};

pub fn getFileInfo(path: []const u8, io: Io) !FileInfo {
    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    return FileInfo{
        .size = stat.size,
        .kind = stat.kind,
        .modified = stat.mtime.nanoseconds,
        .accessed = if (stat.atime) |atime| atime.nanoseconds else null,
        .changed = stat.ctime.nanoseconds,
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
    pub fn absolute(allocator: Allocator, path: []const u8, io: Io) ![]u8 {
        const cwd = Io.Dir.cwd();
        return try cwd.realPathFileAlloc(io, path, allocator);
    }

    /// Check if path is absolute
    pub fn isAbsolute(path: []const u8) bool {
        return std.fs.path.isAbsolute(path);
    }
};

// ==================== Tests ====================

fn testPath(allocator: Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, name });
}

test "File - create and read" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io_val: Io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_path = try testPath(allocator, &tmp, "test_file.txt");
    defer allocator.free(test_path);
    const test_content = "Hello, World!";

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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_path = try testPath(allocator, &tmp, "test_lines.txt");
    defer allocator.free(test_path);
    const test_lines = [_][]const u8{ "Line 1", "Line 2", "Line 3" };

    // Write lines
    try writeLines(allocator, test_path, &test_lines, io_val);

    // Read lines
    const lines = try readLines(allocator, test_path, io_val);
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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_path = try testPath(allocator, &tmp, "test_append.txt");
    defer allocator.free(test_path);

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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_dir = try testPath(allocator, &tmp, "test_dir");
    defer allocator.free(test_dir);
    const first = try Path.join(allocator, &.{ test_dir, "file1.txt" });
    defer allocator.free(first);
    const second = try Path.join(allocator, &.{ test_dir, "file2.txt" });
    defer allocator.free(second);

    // Create directory
    try createDir(test_dir, io_val);

    // Create some files
    try writeString(allocator, first, "content1", io_val);
    try writeString(allocator, second, "content2", io_val);

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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_path = try testPath(allocator, &tmp, "test_exists.txt");
    defer allocator.free(test_path);

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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try testPath(allocator, &tmp, "test_src.txt");
    defer allocator.free(src_path);
    const copy_path = try testPath(allocator, &tmp, "test_copy.txt");
    defer allocator.free(copy_path);
    const move_path = try testPath(allocator, &tmp, "test_move.txt");
    defer allocator.free(move_path);
    const test_content = "test content";

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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_path = try testPath(allocator, &tmp, "test_meta.txt");
    defer allocator.free(test_path);
    const test_content = "Hello, metadata!";

    // Create file
    try writeString(allocator, test_path, test_content, io_val);

    // Get metadata
    const info = try getFileInfo(test_path, io_val);

    try testing.expectEqual(@as(u64, test_content.len), info.size);
    try testing.expectEqual(Io.File.Kind.file, info.kind);
}
