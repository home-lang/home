// Buffered I/O Library for Home Language
// Provides buffered reading and writing for improved I/O performance

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

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
            if (buffer_size == 0) return error.InvalidBufferSize;
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
            if (buffer_size == 0) return error.InvalidBufferSize;
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

pub const FileReader = struct {
    io: Io,
    file: Io.File,

    pub fn read(self: *FileReader, destination: []u8) !usize {
        return self.file.readStreaming(self.io, &.{destination}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
    }
};

pub const FileWriter = struct {
    io: Io,
    file: Io.File,

    pub fn writeAll(self: *FileWriter, bytes: []const u8) !void {
        try self.file.writeStreamingAll(self.io, bytes);
    }
};

/// Create a buffered reader that wraps an `std.Io.File` using explicit I/O.
pub fn FileBufferedReaderWithIo(allocator: Allocator, io: Io, file: Io.File) !BufferedReader(FileReader) {
    return BufferedReader(FileReader).initDefault(allocator, .{ .io = io, .file = file });
}

/// Compatibility entry point using the process-wide single-threaded I/O backend.
pub fn FileBufferedReader(allocator: Allocator, file: Io.File) !BufferedReader(FileReader) {
    return FileBufferedReaderWithIo(allocator, Io.Threaded.global_single_threaded.io(), file);
}

/// Create a buffered writer that wraps an `std.Io.File` using explicit I/O.
pub fn FileBufferedWriterWithIo(allocator: Allocator, io: Io, file: Io.File) !BufferedWriter(FileWriter) {
    return BufferedWriter(FileWriter).initDefault(allocator, .{ .io = io, .file = file });
}

/// Compatibility entry point using the process-wide single-threaded I/O backend.
pub fn FileBufferedWriter(allocator: Allocator, file: Io.File) !BufferedWriter(FileWriter) {
    return FileBufferedWriterWithIo(allocator, Io.Threaded.global_single_threaded.io(), file);
}

// ==================== Tests ====================

const TestFile = struct {
    allocator: Allocator,
    temporary_directory: std.testing.TmpDir,
    path: []const u8,

    fn init(allocator: Allocator, name: []const u8) !TestFile {
        var temporary_directory = std.testing.tmpDir(.{});
        errdefer temporary_directory.cleanup();
        const root = try temporary_directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(root);
        const path = try std.fs.path.join(allocator, &.{ root, name });
        return .{
            .allocator = allocator,
            .temporary_directory = temporary_directory,
            .path = path,
        };
    }

    fn deinit(self: *TestFile) void {
        self.allocator.free(self.path);
        self.temporary_directory.cleanup();
    }
};

test "BufferedReader - basic read" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_file = try TestFile.init(allocator, "buffered-read.txt");
    defer test_file.deinit();
    const test_content = "Hello, Buffered World!";

    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = test_file.path, .data = test_content });

    const file = try Io.Dir.cwd().openFile(testing.io, test_file.path, .{});
    defer file.close(testing.io);

    var buf_reader = try FileBufferedReaderWithIo(allocator, testing.io, file);
    defer buf_reader.deinit();

    const content = try buf_reader.readAll();
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}

test "BufferedReader - read line by line" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_file = try TestFile.init(allocator, "buffered-lines.txt");
    defer test_file.deinit();
    const test_content = "Line 1\nLine 2\nLine 3";

    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = test_file.path, .data = test_content });

    const file = try Io.Dir.cwd().openFile(testing.io, test_file.path, .{});
    defer file.close(testing.io);

    var buf_reader = try FileBufferedReaderWithIo(allocator, testing.io, file);
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
    var test_file = try TestFile.init(allocator, "buffered-delimiter.txt");
    defer test_file.deinit();
    const test_content = "apple,banana,cherry";

    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = test_file.path, .data = test_content });

    const file = try Io.Dir.cwd().openFile(testing.io, test_file.path, .{});
    defer file.close(testing.io);

    var buf_reader = try FileBufferedReaderWithIo(allocator, testing.io, file);
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
    var test_file = try TestFile.init(allocator, "buffered-write.txt");
    defer test_file.deinit();
    const test_content = "Buffered write test!";

    // Write with buffering
    {
        const file = try Io.Dir.cwd().createFile(testing.io, test_file.path, .{});
        defer file.close(testing.io);

        var buf_writer = try FileBufferedWriterWithIo(allocator, testing.io, file);
        defer buf_writer.deinit();

        try buf_writer.writeAll(test_content);
        try buf_writer.flush();
    }

    // Read back and verify
    const content = try Io.Dir.cwd().readFileAlloc(testing.io, test_file.path, allocator, .limited(1024));
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}

test "BufferedWriter - write lines" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_file = try TestFile.init(allocator, "buffered-write-lines.txt");
    defer test_file.deinit();

    // Write lines
    {
        const file = try Io.Dir.cwd().createFile(testing.io, test_file.path, .{});
        defer file.close(testing.io);

        var buf_writer = try FileBufferedWriterWithIo(allocator, testing.io, file);
        defer buf_writer.deinit();

        try buf_writer.writeLine("First line");
        try buf_writer.writeLine("Second line");
        try buf_writer.writeLine("Third line");
    }

    // Read back and verify
    const content = try Io.Dir.cwd().readFileAlloc(testing.io, test_file.path, allocator, .limited(1024));
    defer allocator.free(content);

    try testing.expectEqualStrings("First line\nSecond line\nThird line\n", content);
}

test "BufferedWriter - auto flush on deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_file = try TestFile.init(allocator, "buffered-auto-flush.txt");
    defer test_file.deinit();
    const test_content = "Auto flush!";

    // Write without explicit flush
    {
        const file = try Io.Dir.cwd().createFile(testing.io, test_file.path, .{});
        defer file.close(testing.io);

        var buf_writer = try FileBufferedWriterWithIo(allocator, testing.io, file);
        defer buf_writer.deinit(); // Should auto-flush

        try buf_writer.writeAll(test_content);
        // No explicit flush - deinit should handle it
    }

    // Read back and verify
    const content = try Io.Dir.cwd().readFileAlloc(testing.io, test_file.path, allocator, .limited(1024));
    defer allocator.free(content);

    try testing.expectEqualStrings(test_content, content);
}

test "BufferedReader - handle CRLF newlines" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_file = try TestFile.init(allocator, "buffered-crlf.txt");
    defer test_file.deinit();
    const test_content = "Line 1\r\nLine 2\r\nLine 3";

    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = test_file.path, .data = test_content });

    const file = try Io.Dir.cwd().openFile(testing.io, test_file.path, .{});
    defer file.close(testing.io);

    var buf_reader = try FileBufferedReaderWithIo(allocator, testing.io, file);
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

test "buffered IO rejects zero-sized buffers" {
    const EmptyReader = struct {
        pub fn read(_: *@This(), _: []u8) !usize {
            return 0;
        }
    };
    const EmptyWriter = struct {
        pub fn writeAll(_: *@This(), _: []const u8) !void {}
    };

    try std.testing.expectError(
        error.InvalidBufferSize,
        BufferedReader(EmptyReader).init(std.testing.allocator, .{}, 0),
    );
    try std.testing.expectError(
        error.InvalidBufferSize,
        BufferedWriter(EmptyWriter).init(std.testing.allocator, .{}, 0),
    );
}
