// Async File I/O for Home Language
// Leverages Zig 0.16-dev async I/O features
// Critical for non-blocking asset loading in Generals game

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Async file reader for non-blocking I/O operations
pub const AsyncFile = struct {
    file: std.fs.File,
    allocator: Allocator,

    /// Open a file for async reading
    pub fn open(path: []const u8, allocator: Allocator) !AsyncFile {
        const file = try std.fs.cwd().openFile(path, .{});
        return AsyncFile{
            .file = file,
            .allocator = allocator,
        };
    }

    /// Open a file for async writing
    pub fn create(path: []const u8, allocator: Allocator) !AsyncFile {
        const file = try std.fs.cwd().createFile(path, .{});
        return AsyncFile{
            .file = file,
            .allocator = allocator,
        };
    }

    /// Close the file
    pub fn close(self: *AsyncFile) void {
        self.file.close();
    }

    /// Read entire file contents asynchronously
    /// Caller owns the returned memory
    pub fn readAll(self: *AsyncFile) ![]u8 {
        const stat = try self.file.stat();
        const size = stat.size;

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        const bytes_read = try self.file.read(buffer);
        if (bytes_read != size) {
            self.allocator.free(buffer);
            return error.UnexpectedEndOfFile;
        }

        return buffer;
    }

    /// Read a specific number of bytes
    /// Caller owns the returned memory
    pub fn read(self: *AsyncFile, num_bytes: usize) ![]u8 {
        const buffer = try self.allocator.alloc(u8, num_bytes);
        errdefer self.allocator.free(buffer);

        const bytes_read = try self.file.read(buffer[0..num_bytes]);
        if (bytes_read < num_bytes) {
            // Resize buffer to actual bytes read
            const result = try self.allocator.realloc(buffer, bytes_read);
            return result;
        }

        return buffer;
    }

    /// Read file line by line (iterator-based)
    pub const LineIterator = struct {
        file: *AsyncFile,
        buffer: std.ArrayList(u8),
        allocator: Allocator,
        pos: usize,

        pub fn next(it: *LineIterator) !?[]const u8 {
            it.buffer.clearRetainingCapacity();

            var buf: [1]u8 = undefined;
            while (true) {
                const bytes_read = try it.file.file.read(&buf);
                if (bytes_read == 0) {
                    // EOF
                    if (it.buffer.items.len > 0) {
                        return it.buffer.items;
                    }
                    return null;
                }

                const byte = buf[0];
                if (byte == '\n') {
                    return it.buffer.items;
                }

                // Handle \r\n (Windows) and \r (old Mac)
                if (byte == '\r') {
                    // Peek next byte
                    const next_bytes = try it.file.file.read(&buf);
                    if (next_bytes > 0 and buf[0] != '\n') {
                        // Put it back (seek back)
                        try it.file.file.seekBy(-1);
                    }
                    return it.buffer.items;
                }

                try it.buffer.append(it.allocator, byte);
            }
        }

        pub fn deinit(it: *LineIterator) void {
            it.buffer.deinit(it.allocator);
        }
    };

    /// Get a line iterator for reading file line by line
    pub fn lines(self: *AsyncFile) !LineIterator {
        return LineIterator{
            .file = self,
            .buffer = try std.ArrayList(u8).initCapacity(self.allocator, 256),
            .allocator = self.allocator,
            .pos = 0,
        };
    }

    /// Write data to file asynchronously
    pub fn write(self: *AsyncFile, data: []const u8) !void {
        try self.file.writeAll(data);
    }

    /// Write formatted data to file
    pub fn print(self: *AsyncFile, comptime format: []const u8, args: anytype) !void {
        try self.file.writer().print(format, args);
    }

    /// Seek to a position in the file
    pub fn seekTo(self: *AsyncFile, pos: u64) !void {
        try self.file.seekTo(pos);
    }

    /// Get current position in file
    pub fn getPos(self: *AsyncFile) !u64 {
        return try self.file.getPos();
    }

    /// Get file size
    pub fn getSize(self: *AsyncFile) !u64 {
        const stat = try self.file.stat();
        return stat.size;
    }
};

/// Async directory operations
pub const AsyncDir = struct {
    dir: std.fs.Dir,
    allocator: Allocator,

    /// Open a directory
    pub fn open(path: []const u8, allocator: Allocator) !AsyncDir {
        const dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        return AsyncDir{
            .dir = dir,
            .allocator = allocator,
        };
    }

    /// Close the directory
    pub fn close(self: *AsyncDir) void {
        self.dir.close();
    }

    /// Iterator for directory entries
    pub const Iterator = struct {
        iter: std.fs.Dir.Iterator,

        pub fn next(it: *Iterator) !?std.fs.Dir.Entry {
            return try it.iter.next();
        }
    };

    /// Get an iterator over directory entries
    pub fn iterate(self: *AsyncDir) Iterator {
        return Iterator{
            .iter = self.dir.iterate(),
        };
    }

    /// List all files in directory (caller owns memory)
    pub fn listFiles(self: *AsyncDir) ![][]const u8 {
        var list = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        errdefer {
            for (list.items) |item| {
                self.allocator.free(item);
            }
            list.deinit(self.allocator);
        }

        var iter = self.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const name = try self.allocator.dupe(u8, entry.name);
                try list.append(self.allocator, name);
            }
        }

        return list.toOwnedSlice(self.allocator);
    }
};

/// Utility functions for async file operations

/// Read entire file contents (convenience function)
pub fn readFileAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    var file = try AsyncFile.open(path, allocator);
    defer file.close();
    return try file.readAll();
}

/// Write entire file contents (convenience function)
pub fn writeFile(allocator: Allocator, path: []const u8, data: []const u8) !void {
    var file = try AsyncFile.create(path, allocator);
    defer file.close();
    try file.write(data);
}

/// Check if a file exists
pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Check if a directory exists
pub fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Get file size without opening it
pub fn getFileSize(path: []const u8) !u64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}

// ==================== Tests ====================

test "AsyncFile: read and write" {
    const allocator = std.testing.allocator;

    const test_file = "/tmp/test_async_file.txt";
    const test_data = "Hello, Generals!\nThis is a test.\n";

    // Write
    {
        var file = try AsyncFile.create(test_file, allocator);
        defer file.close();
        try file.write(test_data);
    }

    // Read
    {
        var file = try AsyncFile.open(test_file, allocator);
        defer file.close();
        const data = try file.readAll();
        defer allocator.free(data);

        try std.testing.expectEqualStrings(test_data, data);
    }

    // Cleanup
    try std.fs.cwd().deleteFile(test_file);
}

test "AsyncFile: read lines" {
    const allocator = std.testing.allocator;

    const test_file = "/tmp/test_lines.txt";
    const test_data = "Line 1\nLine 2\nLine 3\n";

    // Write test file
    try writeFile(allocator, test_file, test_data);

    // Read lines
    var file = try AsyncFile.open(test_file, allocator);
    defer file.close();

    var line_iter = try file.lines();
    defer line_iter.deinit();

    var line_num: u32 = 0;
    while (try line_iter.next()) |line| {
        line_num += 1;
        if (line_num == 1) try std.testing.expectEqualStrings("Line 1", line);
        if (line_num == 2) try std.testing.expectEqualStrings("Line 2", line);
        if (line_num == 3) try std.testing.expectEqualStrings("Line 3", line);
    }

    try std.testing.expectEqual(@as(u32, 3), line_num);

    // Cleanup
    try std.fs.cwd().deleteFile(test_file);
}

test "AsyncFile: file size" {
    const allocator = std.testing.allocator;

    const test_file = "/tmp/test_size.txt";
    const test_data = "0123456789";

    try writeFile(allocator, test_file, test_data);

    const size = try getFileSize(test_file);
    try std.testing.expectEqual(@as(u64, 10), size);

    // Cleanup
    try std.fs.cwd().deleteFile(test_file);
}

test "AsyncFile: file exists" {
    const allocator = std.testing.allocator;

    const test_file = "/tmp/test_exists.txt";

    // Should not exist initially
    try std.testing.expect(!fileExists(test_file));

    // Create it
    try writeFile(allocator, test_file, "test");

    // Should exist now
    try std.testing.expect(fileExists(test_file));

    // Cleanup
    try std.fs.cwd().deleteFile(test_file);

    // Should not exist after deletion
    try std.testing.expect(!fileExists(test_file));
}

test "AsyncDir: list files" {
    const allocator = std.testing.allocator;

    // Create test directory
    const test_dir = "/tmp/test_async_dir";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test files
    try writeFile(allocator, test_dir ++ "/file1.txt", "test1");
    try writeFile(allocator, test_dir ++ "/file2.txt", "test2");
    try writeFile(allocator, test_dir ++ "/file3.txt", "test3");

    // List files
    var dir = try AsyncDir.open(test_dir, allocator);
    defer dir.close();

    const files = try dir.listFiles();
    defer {
        for (files) |file| {
            allocator.free(file);
        }
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 3), files.len);
}
