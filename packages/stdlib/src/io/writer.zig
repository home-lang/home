const std = @import("std");

/// Generic writer interface
pub const Writer = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!usize,

    pub fn write(self: Writer, bytes: []const u8) !usize {
        return self.writeFn(self.context, bytes);
    }

    pub fn writeAll(self: Writer, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try self.write(bytes[written..]);
            if (n == 0) return error.EndOfStream;
            written += n;
        }
    }

    pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
        try std.fmt.format(self, format, args);
    }

    pub fn writeByte(self: Writer, byte: u8) !void {
        const bytes = [_]u8{byte};
        try self.writeAll(&bytes);
    }

    pub fn writeInt(self: Writer, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.writeAll(&buffer);
    }

    pub fn writeStruct(self: Writer, value: anytype) !void {
        const bytes = std.mem.asBytes(&value);
        try self.writeAll(bytes);
    }
};

/// Buffered writer for improved performance
pub const BufferedWriter = struct {
    unbuffered_writer: Writer,
    buffer: []u8,
    end: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, writer: Writer, buffer_size: usize) !BufferedWriter {
        const buffer = try allocator.alloc(u8, buffer_size);
        return .{
            .unbuffered_writer = writer,
            .buffer = buffer,
            .end = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferedWriter) void {
        self.allocator.free(self.buffer);
    }

    pub fn writer(self: *BufferedWriter) Writer {
        return .{
            .context = self,
            .writeFn = writeFn,
        };
    }

    fn writeFn(context: *anyopaque, bytes: []const u8) !usize {
        const self: *BufferedWriter = @ptrCast(@alignCast(context));
        return self.write(bytes);
    }

    fn write(self: *BufferedWriter, bytes: []const u8) !usize {
        if (bytes.len >= self.buffer.len) {
            // Data is larger than buffer, flush and write directly
            try self.flush();
            return self.unbuffered_writer.write(bytes);
        }

        if (self.end + bytes.len > self.buffer.len) {
            try self.flush();
        }

        @memcpy(self.buffer[self.end .. self.end + bytes.len], bytes);
        self.end += bytes.len;

        return bytes.len;
    }

    pub fn flush(self: *BufferedWriter) !void {
        if (self.end == 0) return;

        var written: usize = 0;
        while (written < self.end) {
            const n = try self.unbuffered_writer.write(self.buffer[written..self.end]);
            if (n == 0) return error.EndOfStream;
            written += n;
        }

        self.end = 0;
    }
};
