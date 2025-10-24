const std = @import("std");

/// Generic reader interface
pub const Reader = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, buffer: []u8) anyerror!usize,

    pub fn read(self: Reader, buffer: []u8) !usize {
        return self.readFn(self.context, buffer);
    }

    pub fn readAll(self: Reader, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&buffer);
            if (n == 0) break;
            try result.appendSlice(buffer[0..n]);
        }

        return try result.toOwnedSlice();
    }

    pub fn readLine(self: Reader, allocator: std.mem.Allocator) !?[]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        var buffer: [1]u8 = undefined;
        while (true) {
            const n = try self.read(&buffer);
            if (n == 0) {
                if (result.items.len == 0) return null;
                break;
            }

            if (buffer[0] == '\n') break;
            if (buffer[0] == '\r') continue;

            try result.append(buffer[0]);
        }

        return try result.toOwnedSlice();
    }

    pub fn readUntil(self: Reader, allocator: std.mem.Allocator, delimiter: u8) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        var buffer: [1]u8 = undefined;
        while (true) {
            const n = try self.read(&buffer);
            if (n == 0) break;

            if (buffer[0] == delimiter) break;
            try result.append(buffer[0]);
        }

        return try result.toOwnedSlice();
    }

    pub fn readInt(self: Reader, comptime T: type) !T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        const n = try self.read(&buffer);
        if (n != @sizeOf(T)) return error.UnexpectedEof;
        return std.mem.readInt(T, &buffer, .little);
    }

    pub fn readStruct(self: Reader, comptime T: type) !T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        const n = try self.read(&buffer);
        if (n != @sizeOf(T)) return error.UnexpectedEof;
        return @as(*const T, @ptrCast(@alignCast(&buffer))).*;
    }
};

/// Buffered reader for improved performance
pub const BufferedReader = struct {
    unbuffered_reader: Reader,
    buffer: []u8,
    start: usize,
    end: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, reader: Reader, buffer_size: usize) !BufferedReader {
        const buffer = try allocator.alloc(u8, buffer_size);
        return .{
            .unbuffered_reader = reader,
            .buffer = buffer,
            .start = 0,
            .end = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferedReader) void {
        self.allocator.free(self.buffer);
    }

    pub fn reader(self: *BufferedReader) Reader {
        return .{
            .context = self,
            .readFn = readFn,
        };
    }

    fn readFn(context: *anyopaque, buffer: []u8) !usize {
        const self: *BufferedReader = @ptrCast(@alignCast(context));
        return self.read(buffer);
    }

    fn read(self: *BufferedReader, buffer: []u8) !usize {
        if (self.start >= self.end) {
            // Buffer is empty, refill
            self.start = 0;
            self.end = try self.unbuffered_reader.read(self.buffer);
            if (self.end == 0) return 0; // EOF
        }

        const available = self.end - self.start;
        const to_copy = @min(buffer.len, available);

        @memcpy(buffer[0..to_copy], self.buffer[self.start .. self.start + to_copy]);
        self.start += to_copy;

        return to_copy;
    }

    pub fn peek(self: *BufferedReader) ![]const u8 {
        if (self.start >= self.end) {
            self.start = 0;
            self.end = try self.unbuffered_reader.read(self.buffer);
        }
        return self.buffer[self.start..self.end];
    }
};
