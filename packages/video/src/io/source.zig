// Home Video Library - Input Sources
// Abstractions for reading media from various sources

const std = @import("std");
const err = @import("../core/error.zig");

pub const VideoError = err.VideoError;

// ============================================================================
// Source Interface
// ============================================================================

/// Read callback function type
pub const ReadFn = *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize;

/// Seek callback function type
pub const SeekFn = *const fn (ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64;

/// Tell callback function type (get current position)
pub const TellFn = *const fn (ctx: *anyopaque) u64;

/// Size callback function type (get total size, null if unknown)
pub const SizeFn = *const fn (ctx: *anyopaque) ?u64;

pub const SeekWhence = enum {
    start,
    current,
    end,
};

/// Generic source interface for reading media
pub const Source = struct {
    ctx: *anyopaque,
    read_fn: ReadFn,
    seek_fn: ?SeekFn,
    tell_fn: TellFn,
    size_fn: SizeFn,

    const Self = @This();

    /// Read data into buffer, returns bytes read
    pub fn read(self: *Self, buffer: []u8) !usize {
        return self.read_fn(self.ctx, buffer);
    }

    /// Read exact number of bytes, error if not available
    pub fn readExact(self: *Self, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try self.read(buffer[total..]);
            if (n == 0) return VideoError.UnexpectedEof;
            total += n;
        }
    }

    /// Seek to position
    pub fn seek(self: *Self, offset: i64, whence: SeekWhence) !u64 {
        if (self.seek_fn) |seek_fn| {
            return seek_fn(self.ctx, offset, whence);
        }
        return VideoError.NotSeekable;
    }

    /// Seek to absolute position from start
    pub fn seekTo(self: *Self, position: u64) !void {
        _ = try self.seek(@intCast(position), .start);
    }

    /// Get current position
    pub fn tell(self: *Self) u64 {
        return self.tell_fn(self.ctx);
    }

    /// Get total size (null if unknown/streaming)
    pub fn size(self: *Self) ?u64 {
        return self.size_fn(self.ctx);
    }

    /// Is seekable?
    pub fn isSeekable(self: *Self) bool {
        return self.seek_fn != null;
    }

    /// Skip bytes (uses seek if available, otherwise reads)
    pub fn skip(self: *Self, count: u64) !void {
        if (self.seek_fn != null) {
            _ = try self.seek(@intCast(count), .current);
        } else {
            // Read and discard
            var buf: [4096]u8 = undefined;
            var remaining = count;
            while (remaining > 0) {
                const to_read = @min(remaining, buf.len);
                const n = try self.read(buf[0..to_read]);
                if (n == 0) return VideoError.UnexpectedEof;
                remaining -= n;
            }
        }
    }

    /// Read all remaining data
    pub fn readAll(self: *Self, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var buf: [8192]u8 = undefined;
        while (result.items.len < max_size) {
            const n = try self.read(&buf);
            if (n == 0) break;
            try result.appendSlice(buf[0..n]);
        }

        return result.toOwnedSlice();
    }

    // Convenience read methods

    /// Read u8
    pub fn readU8(self: *Self) !u8 {
        var buf: [1]u8 = undefined;
        try self.readExact(&buf);
        return buf[0];
    }

    /// Read little-endian u16
    pub fn readU16Le(self: *Self) !u16 {
        var buf: [2]u8 = undefined;
        try self.readExact(&buf);
        return std.mem.readInt(u16, &buf, .little);
    }

    /// Read big-endian u16
    pub fn readU16Be(self: *Self) !u16 {
        var buf: [2]u8 = undefined;
        try self.readExact(&buf);
        return std.mem.readInt(u16, &buf, .big);
    }

    /// Read little-endian u32
    pub fn readU32Le(self: *Self) !u32 {
        var buf: [4]u8 = undefined;
        try self.readExact(&buf);
        return std.mem.readInt(u32, &buf, .little);
    }

    /// Read big-endian u32
    pub fn readU32Be(self: *Self) !u32 {
        var buf: [4]u8 = undefined;
        try self.readExact(&buf);
        return std.mem.readInt(u32, &buf, .big);
    }

    /// Read little-endian u64
    pub fn readU64Le(self: *Self) !u64 {
        var buf: [8]u8 = undefined;
        try self.readExact(&buf);
        return std.mem.readInt(u64, &buf, .little);
    }

    /// Read big-endian u64
    pub fn readU64Be(self: *Self) !u64 {
        var buf: [8]u8 = undefined;
        try self.readExact(&buf);
        return std.mem.readInt(u64, &buf, .big);
    }

    /// Read 4-byte chunk ID / FourCC
    pub fn readFourCC(self: *Self) ![4]u8 {
        var buf: [4]u8 = undefined;
        try self.readExact(&buf);
        return buf;
    }
};

// ============================================================================
// Buffer Source
// ============================================================================

/// Source that reads from a memory buffer
pub const BufferSource = struct {
    data: []const u8,
    position: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .position = 0,
        };
    }

    pub fn source(self: *Self) Source {
        return Source{
            .ctx = self,
            .read_fn = readImpl,
            .seek_fn = seekImpl,
            .tell_fn = tellImpl,
            .size_fn = sizeImpl,
        };
    }

    fn readImpl(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const available = self.data.len - self.position;
        const to_read = @min(buffer.len, available);
        @memcpy(buffer[0..to_read], self.data[self.position..][0..to_read]);
        self.position += to_read;
        return to_read;
    }

    fn seekImpl(ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const new_pos: i64 = switch (whence) {
            .start => offset,
            .current => @as(i64, @intCast(self.position)) + offset,
            .end => @as(i64, @intCast(self.data.len)) + offset,
        };

        if (new_pos < 0 or new_pos > @as(i64, @intCast(self.data.len))) {
            return VideoError.SeekOutOfRange;
        }

        self.position = @intCast(new_pos);
        return self.position;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.position;
    }

    fn sizeImpl(ctx: *anyopaque) ?u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.data.len;
    }
};

// ============================================================================
// File Source
// ============================================================================

/// Source that reads from a file
pub const FileSource = struct {
    file: std.fs.File,
    size_cached: ?u64,

    const Self = @This();

    pub fn open(path: []const u8) !Self {
        const file = std.fs.cwd().openFile(path, .{}) catch return VideoError.FileNotFound;

        const stat = file.stat() catch {
            file.close();
            return VideoError.ReadError;
        };

        return Self{
            .file = file,
            .size_cached = stat.size,
        };
    }

    pub fn close(self: *Self) void {
        self.file.close();
    }

    pub fn source(self: *Self) Source {
        return Source{
            .ctx = self,
            .read_fn = readImpl,
            .seek_fn = seekImpl,
            .tell_fn = tellImpl,
            .size_fn = sizeImpl,
        };
    }

    fn readImpl(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.file.read(buffer) catch return VideoError.ReadError;
    }

    fn seekImpl(ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const std_whence: std.fs.File.SeekableStream.SeekWhence = switch (whence) {
            .start => .start,
            .current => .cur,
            .end => .end,
        };

        self.file.seekTo(@bitCast(offset)) catch return VideoError.SeekError;
        _ = std_whence;

        return self.file.getPos() catch return VideoError.SeekError;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.file.getPos() catch 0;
    }

    fn sizeImpl(ctx: *anyopaque) ?u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.size_cached;
    }
};

// ============================================================================
// Buffered Source (wraps another source with read buffering)
// ============================================================================

pub const BufferedSource = struct {
    inner: *Source,
    buffer: []u8,
    buffer_start: u64, // File position where buffer data starts
    buffer_len: usize, // Amount of valid data in buffer
    position: u64, // Current logical position

    allocator: std.mem.Allocator,

    const Self = @This();
    const DEFAULT_BUFFER_SIZE = 64 * 1024; // 64KB

    pub fn init(allocator: std.mem.Allocator, inner: *Source) !Self {
        return initWithSize(allocator, inner, DEFAULT_BUFFER_SIZE);
    }

    pub fn initWithSize(allocator: std.mem.Allocator, inner: *Source, buffer_size: usize) !Self {
        const buffer = try allocator.alloc(u8, buffer_size);

        return Self{
            .inner = inner,
            .buffer = buffer,
            .buffer_start = 0,
            .buffer_len = 0,
            .position = inner.tell(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    pub fn source(self: *Self) Source {
        return Source{
            .ctx = self,
            .read_fn = readImpl,
            .seek_fn = if (self.inner.isSeekable()) seekImpl else null,
            .tell_fn = tellImpl,
            .size_fn = sizeImpl,
        };
    }

    fn fillBuffer(self: *Self) !void {
        // Seek inner to our position if needed
        if (self.inner.isSeekable()) {
            try self.inner.seekTo(self.position);
        }

        self.buffer_start = self.position;
        self.buffer_len = try self.inner.read(self.buffer);
    }

    fn readImpl(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));

        var total: usize = 0;
        var dest = buffer;

        while (dest.len > 0) {
            // Check if position is within buffer
            if (self.position >= self.buffer_start and
                self.position < self.buffer_start + self.buffer_len)
            {
                const buffer_offset = self.position - self.buffer_start;
                const available = self.buffer_len - @as(usize, @intCast(buffer_offset));
                const to_copy = @min(dest.len, available);

                @memcpy(dest[0..to_copy], self.buffer[@intCast(buffer_offset)..][0..to_copy]);

                self.position += to_copy;
                total += to_copy;
                dest = dest[to_copy..];
            } else {
                // Need to refill buffer
                try self.fillBuffer();
                if (self.buffer_len == 0) break; // EOF
            }
        }

        return total;
    }

    fn seekImpl(ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const new_pos: i64 = switch (whence) {
            .start => offset,
            .current => @as(i64, @intCast(self.position)) + offset,
            .end => blk: {
                const size = self.inner.size() orelse return VideoError.SeekError;
                break :blk @as(i64, @intCast(size)) + offset;
            },
        };

        if (new_pos < 0) return VideoError.SeekOutOfRange;

        self.position = @intCast(new_pos);
        return self.position;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.position;
    }

    fn sizeImpl(ctx: *anyopaque) ?u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.inner.size();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BufferSource read" {
    const data = "Hello, World!";
    var src = BufferSource.init(data);
    var source_obj = src.source();

    var buf: [5]u8 = undefined;
    const n = try source_obj.read(&buf);

    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, "Hello", &buf);
}

test "BufferSource seek" {
    const data = "Hello, World!";
    var src = BufferSource.init(data);
    var source_obj = src.source();

    _ = try source_obj.seek(7, .start);

    var buf: [5]u8 = undefined;
    _ = try source_obj.read(&buf);

    try std.testing.expectEqualSlices(u8, "World", &buf);
}

test "BufferSource read integers" {
    var data: [8]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0x12345678, .little);
    std.mem.writeInt(u32, data[4..8], 0x12345678, .big);

    var src = BufferSource.init(&data);
    var source_obj = src.source();

    const le = try source_obj.readU32Le();
    const be = try source_obj.readU32Be();

    try std.testing.expectEqual(@as(u32, 0x12345678), le);
    try std.testing.expectEqual(@as(u32, 0x12345678), be);
}
