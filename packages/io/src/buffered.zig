// Buffered I/O Library for Home Language
// Provides buffered reading and writing for improved I/O performance

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Default buffer size (8KB)
pub const DEFAULT_BUFFER_SIZE = 8192;

// ==================== BufferedReader ====================

/// Buffered reader that reduces system calls by reading in chunks
pub fn BufferedReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        unbuffered_reader: ReaderType,
        buffer: []u8,
        allocator: Allocator,
        start: usize,
        end: usize,

        /// Initialize a buffered reader with custom buffer size
        pub fn init(allocator: Allocator, reader: ReaderType, buffer_size: usize) !Self {
            const buffer = try allocator.alloc(u8, buffer_size);
            return Self{
                .unbuffered_reader = reader,
                .buffer = buffer,
                .allocator = allocator,
                .start = 0,
                .end = 0,
            };
        }

        /// Initialize with default buffer size
        pub fn initDefault(allocator: Allocator, reader: ReaderType) !Self {
            return try init(allocator, reader, DEFAULT_BUFFER_SIZE);
        }

        /// Clean up allocated buffer
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Fill the buffer from the underlying reader
        fn fillBuffer(self: *Self) !void {
            self.start = 0;
            self.end = try self.unbuffered_reader.read(self.buffer);
        }

        /// Read bytes into destination buffer
        pub fn read(self: *Self, dest: []u8) !usize {
            if (dest.len == 0) return 0;

            var total_read: usize = 0;

            while (total_read < dest.len) {
                // If buffer is empty, refill it
                if (self.start >= self.end) {
                    try self.fillBuffer();
                    if (self.end == 0) break; // EOF
                }

                // Copy from buffer to dest
                const available = self.end - self.start;
                const needed = dest.len - total_read;
                const to_copy = @min(available, needed);

                @memcpy(dest[total_read..][0..to_copy], self.buffer[self.start..][0..to_copy]);
                self.start += to_copy;
                total_read += to_copy;
            }

            return total_read;
        }

        /// Read a single byte
        pub fn readByte(self: *Self) !?u8 {
            if (self.start >= self.end) {
                try self.fillBuffer();
                if (self.end == 0) return null; // EOF
            }

            const byte = self.buffer[self.start];
            self.start += 1;
            return byte;
        }

        /// Read until a delimiter is found (caller owns returned memory)
        pub fn readUntilDelimiter(self: *Self, delimiter: u8) ![]u8 {
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(self.allocator);

            while (true) {
                const byte = try self.readByte();
                if (byte == null) break;

                if (byte.? == delimiter) break;
                try result.append(self.allocator, byte.?);
            }

            return result.toOwnedSlice(self.allocator);
        }

        /// Read a line (up to newline, caller owns returned memory)
        pub fn readLine(self: *Self) !?[]u8 {
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(self.allocator);

            var found_anything = false;

            while (true) {
                const byte = try self.readByte();
                if (byte == null) {
                    if (!found_anything) return null;
                    break;
                }

                found_anything = true;
                const b = byte.?;

                // Handle different newline types
                if (b == '\n') break;
                if (b == '\r') {
                    // Check for \r\n
                    const next = try self.readByte();
                    if (next != null and next.? == '\n') {
                        // Consumed \r\n
                    } else if (next != null) {
                        // Put back the byte if it wasn't \n
                        self.start -= 1;
                    }
                    break;
                }

                try result.append(self.allocator, b);
            }

            const slice = try result.toOwnedSlice(self.allocator);
            return if (slice.len > 0 or found_anything) slice else null;
        }

        /// Read all remaining bytes (caller owns returned memory)
        pub fn readAll(self: *Self) ![]u8 {
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(self.allocator);

            var buf: [4096]u8 = undefined;
            while (true) {
                const bytes_read = try self.read(&buf);
                if (bytes_read == 0) break;
                try result.appendSlice(self.allocator, buf[0..bytes_read]);
            }

            return result.toOwnedSlice(self.allocator);
        }
    };
}

// ==================== BufferedWriter ====================

/// Buffered writer that reduces system calls by writing in chunks
pub fn BufferedWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        unbuffered_writer: WriterType,
        buffer: []u8,
        allocator: Allocator,
        end: usize,

        /// Initialize a buffered writer with custom buffer size
        pub fn init(allocator: Allocator, writer: WriterType, buffer_size: usize) !Self {
            const buffer = try allocator.alloc(u8, buffer_size);
            return Self{
                .unbuffered_writer = writer,
                .buffer = buffer,
                .allocator = allocator,
                .end = 0,
            };
        }

        /// Initialize with default buffer size
        pub fn initDefault(allocator: Allocator, writer: WriterType) !Self {
            return try init(allocator, writer, DEFAULT_BUFFER_SIZE);
        }

        /// Clean up (automatically flushes)
        pub fn deinit(self: *Self) void {
            self.flush() catch {};
            self.allocator.free(self.buffer);
        }

        /// Flush buffered data to the underlying writer
        pub fn flush(self: *Self) !void {
            if (self.end == 0) return;

            try self.unbuffered_writer.writeAll(self.buffer[0..self.end]);
            self.end = 0;
        }

        /// Write bytes from source buffer
        pub fn write(self: *Self, bytes: []const u8) !usize {
            if (bytes.len == 0) return 0;

            // If data is larger than buffer, flush and write directly
            if (bytes.len > self.buffer.len) {
                try self.flush();
                try self.unbuffered_writer.writeAll(bytes);
                return bytes.len;
            }

            var total_written: usize = 0;

            while (total_written < bytes.len) {
                // If buffer is full, flush it
                if (self.end >= self.buffer.len) {
                    try self.flush();
                }

                // Copy to buffer
                const available = self.buffer.len - self.end;
                const needed = bytes.len - total_written;
                const to_copy = @min(available, needed);

                @memcpy(self.buffer[self.end..][0..to_copy], bytes[total_written..][0..to_copy]);
                self.end += to_copy;
                total_written += to_copy;
            }

            return total_written;
        }

        /// Write all bytes (convenience wrapper)
        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            _ = try self.write(bytes);
        }

        /// Write a single byte
        pub fn writeByte(self: *Self, byte: u8) !void {
            if (self.end >= self.buffer.len) {
                try self.flush();
            }

            self.buffer[self.end] = byte;
            self.end += 1;
        }

        /// Write a line with newline
        pub fn writeLine(self: *Self, line: []const u8) !void {
            try self.writeAll(line);
            try self.writeByte('\n');
        }
    };
}

// ==================== Convenience Functions ====================

/// Create a buffered reader that wraps std.fs.File
pub fn FileBufferedReader(allocator: Allocator, file: std.fs.File) !BufferedReader(std.fs.File) {
    return try BufferedReader(std.fs.File).initDefault(allocator, file);
}

/// Create a buffered writer that wraps std.fs.File
pub fn FileBufferedWriter(allocator: Allocator, file: std.fs.File) !BufferedWriter(std.fs.File) {
    return try BufferedWriter(std.fs.File).initDefault(allocator, file);
}

// ==================== Tests ====================

test "BufferedReader - basic read" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a test file
    const test_path = "test_buffered_read.txt";
    const test_content = "Hello, Buffered World!";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Write test data
    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = test_content });

    // Read with buffering
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();

    var buf_reader = try FileBufferedReader(allocator, file);
    defer buf_reader.deinit();

    const content = try buf_reader.readAll();
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}

test "BufferedReader - read line by line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_buffered_lines.txt";
    const test_content = "Line 1\nLine 2\nLine 3";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = test_content });

    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();

    var buf_reader = try FileBufferedReader(allocator, file);
    defer buf_reader.deinit();

    // Read first line
    const line1 = try buf_reader.readLine();
    try testing.expect(line1 != null);
    defer allocator.free(line1.?);
    try testing.expectEqualStrings("Line 1", line1.?);

    // Read second line
    const line2 = try buf_reader.readLine();
    try testing.expect(line2 != null);
    defer allocator.free(line2.?);
    try testing.expectEqualStrings("Line 2", line2.?);

    // Read third line
    const line3 = try buf_reader.readLine();
    try testing.expect(line3 != null);
    defer allocator.free(line3.?);
    try testing.expectEqualStrings("Line 3", line3.?);

    // EOF
    const line4 = try buf_reader.readLine();
    try testing.expect(line4 == null);
}

test "BufferedReader - read until delimiter" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_buffered_delim.txt";
    const test_content = "apple,banana,cherry";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = test_content });

    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();

    var buf_reader = try FileBufferedReader(allocator, file);
    defer buf_reader.deinit();

    const word1 = try buf_reader.readUntilDelimiter(',');
    defer allocator.free(word1);
    try testing.expectEqualStrings("apple", word1);

    const word2 = try buf_reader.readUntilDelimiter(',');
    defer allocator.free(word2);
    try testing.expectEqualStrings("banana", word2);
}

test "BufferedWriter - basic write" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_buffered_write.txt";
    const test_content = "Buffered write test!";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Write with buffering
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();

        var buf_writer = try FileBufferedWriter(allocator, file);
        defer buf_writer.deinit();

        try buf_writer.writeAll(test_content);
        try buf_writer.flush();
    }

    // Read back and verify
    const content = try std.fs.cwd().readFileAlloc(test_path, allocator, @enumFromInt(1024));
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}

test "BufferedWriter - write lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_buffered_write_lines.txt";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Write lines
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();

        var buf_writer = try FileBufferedWriter(allocator, file);
        defer buf_writer.deinit();

        try buf_writer.writeLine("First line");
        try buf_writer.writeLine("Second line");
        try buf_writer.writeLine("Third line");
    }

    // Read back and verify
    const content = try std.fs.cwd().readFileAlloc(test_path, allocator, @enumFromInt(1024));
    defer allocator.free(content);

    try testing.expectEqualStrings("First line\nSecond line\nThird line\n", content);
}

test "BufferedWriter - auto flush on deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_buffered_auto_flush.txt";
    const test_content = "Auto flush!";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Write without explicit flush
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();

        var buf_writer = try FileBufferedWriter(allocator, file);
        defer buf_writer.deinit(); // Should auto-flush

        try buf_writer.writeAll(test_content);
        // No explicit flush - deinit should handle it
    }

    // Read back and verify
    const content = try std.fs.cwd().readFileAlloc(test_path, allocator, @enumFromInt(1024));
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}

test "BufferedReader - handle CRLF newlines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_buffered_crlf.txt";
    const test_content = "Line 1\r\nLine 2\r\nLine 3";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = test_content });

    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();

    var buf_reader = try FileBufferedReader(allocator, file);
    defer buf_reader.deinit();

    const line1 = try buf_reader.readLine();
    try testing.expect(line1 != null);
    defer allocator.free(line1.?);
    try testing.expectEqualStrings("Line 1", line1.?);

    const line2 = try buf_reader.readLine();
    try testing.expect(line2 != null);
    defer allocator.free(line2.?);
    try testing.expectEqualStrings("Line 2", line2.?);
}
