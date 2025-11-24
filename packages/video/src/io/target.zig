// Home Video Library - Output Targets
// Abstractions for writing media to various destinations

const std = @import("std");
const err = @import("../core/error.zig");

pub const VideoError = err.VideoError;

// ============================================================================
// Target Interface
// ============================================================================

/// Write callback function type
pub const WriteFn = *const fn (ctx: *anyopaque, data: []const u8) anyerror!void;

/// Seek callback function type
pub const SeekFn = *const fn (ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64;

/// Tell callback function type
pub const TellFn = *const fn (ctx: *anyopaque) u64;

/// Flush callback function type
pub const FlushFn = *const fn (ctx: *anyopaque) anyerror!void;

pub const SeekWhence = enum {
    start,
    current,
    end,
};

/// Generic target interface for writing media
pub const Target = struct {
    ctx: *anyopaque,
    write_fn: WriteFn,
    seek_fn: ?SeekFn,
    tell_fn: TellFn,
    flush_fn: ?FlushFn,

    const Self = @This();

    /// Write data
    pub fn write(self: *Self, data: []const u8) !void {
        return self.write_fn(self.ctx, data);
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

    /// Is seekable?
    pub fn isSeekable(self: *Self) bool {
        return self.seek_fn != null;
    }

    /// Flush buffered data
    pub fn flush(self: *Self) !void {
        if (self.flush_fn) |flush_fn| {
            try flush_fn(self.ctx);
        }
    }

    // Convenience write methods

    /// Write u8
    pub fn writeU8(self: *Self, value: u8) !void {
        try self.write(&[1]u8{value});
    }

    /// Write little-endian u16
    pub fn writeU16Le(self: *Self, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.write(&buf);
    }

    /// Write big-endian u16
    pub fn writeU16Be(self: *Self, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .big);
        try self.write(&buf);
    }

    /// Write little-endian u32
    pub fn writeU32Le(self: *Self, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.write(&buf);
    }

    /// Write big-endian u32
    pub fn writeU32Be(self: *Self, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        try self.write(&buf);
    }

    /// Write little-endian u64
    pub fn writeU64Le(self: *Self, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try self.write(&buf);
    }

    /// Write big-endian u64
    pub fn writeU64Be(self: *Self, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .big);
        try self.write(&buf);
    }

    /// Write little-endian i16
    pub fn writeI16Le(self: *Self, value: i16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(i16, &buf, value, .little);
        try self.write(&buf);
    }

    /// Write big-endian i16
    pub fn writeI16Be(self: *Self, value: i16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(i16, &buf, value, .big);
        try self.write(&buf);
    }

    /// Write little-endian i32
    pub fn writeI32Le(self: *Self, value: i32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, value, .little);
        try self.write(&buf);
    }

    /// Write big-endian i32
    pub fn writeI32Be(self: *Self, value: i32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, value, .big);
        try self.write(&buf);
    }

    /// Write FourCC
    pub fn writeFourCC(self: *Self, fourcc: [4]u8) !void {
        try self.write(&fourcc);
    }

    /// Write zeros (padding)
    pub fn writeZeros(self: *Self, count: usize) !void {
        const zeros = [_]u8{0} ** 64;
        var remaining = count;
        while (remaining > 0) {
            const to_write = @min(remaining, zeros.len);
            try self.write(zeros[0..to_write]);
            remaining -= to_write;
        }
    }

    /// Write padding to align to boundary
    pub fn alignTo(self: *Self, alignment: u64) !void {
        const pos = self.tell();
        const rem = pos % alignment;
        if (rem != 0) {
            try self.writeZeros(@intCast(alignment - rem));
        }
    }
};

// ============================================================================
// Buffer Target
// ============================================================================

/// Target that writes to a growable memory buffer
pub const BufferTarget = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    position: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .buffer = .empty,
            .allocator = allocator,
            .position = 0,
        };
    }

    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
        var buffer: std.ArrayList(u8) = .empty;
        try buffer.ensureTotalCapacity(allocator, capacity);
        return Self{
            .buffer = buffer,
            .allocator = allocator,
            .position = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn target(self: *Self) Target {
        return Target{
            .ctx = self,
            .write_fn = writeImpl,
            .seek_fn = seekImpl,
            .tell_fn = tellImpl,
            .flush_fn = null,
        };
    }

    /// Get the written data
    pub fn getData(self: *Self) []const u8 {
        return self.buffer.items;
    }

    /// Get owned slice (transfers ownership)
    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    /// Reset to empty
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.position = 0;
    }

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // If writing at end, append
        if (self.position >= self.buffer.items.len) {
            // Pad with zeros if needed
            if (self.position > self.buffer.items.len) {
                const pad = self.position - self.buffer.items.len;
                try self.buffer.appendNTimes(self.allocator, 0, pad);
            }
            try self.buffer.appendSlice(self.allocator, data);
        } else {
            // Overwrite existing data
            const overwrite_len = @min(data.len, self.buffer.items.len - self.position);
            @memcpy(self.buffer.items[self.position..][0..overwrite_len], data[0..overwrite_len]);

            // Append remaining if write extends past current end
            if (data.len > overwrite_len) {
                try self.buffer.appendSlice(self.allocator, data[overwrite_len..]);
            }
        }

        self.position += data.len;
    }

    fn seekImpl(ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const new_pos: i64 = switch (whence) {
            .start => offset,
            .current => @as(i64, @intCast(self.position)) + offset,
            .end => @as(i64, @intCast(self.buffer.items.len)) + offset,
        };

        if (new_pos < 0) return VideoError.SeekOutOfRange;

        self.position = @intCast(new_pos);
        return self.position;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.position;
    }
};

// ============================================================================
// File Target
// ============================================================================

/// Target that writes to a file
pub const FileTarget = struct {
    file: std.fs.File,

    const Self = @This();

    pub fn create(path: []const u8) !Self {
        const file = std.fs.cwd().createFile(path, .{}) catch return VideoError.WriteError;
        return Self{ .file = file };
    }

    pub fn close(self: *Self) void {
        self.file.close();
    }

    pub fn target(self: *Self) Target {
        return Target{
            .ctx = self,
            .write_fn = writeImpl,
            .seek_fn = seekImpl,
            .tell_fn = tellImpl,
            .flush_fn = flushImpl,
        };
    }

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.file.writeAll(data) catch return VideoError.WriteError;
    }

    fn seekImpl(ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = whence;

        self.file.seekTo(@bitCast(offset)) catch return VideoError.SeekError;
        return self.file.getPos() catch return VideoError.SeekError;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.file.getPos() catch 0;
    }

    fn flushImpl(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.file.sync() catch return VideoError.WriteError;
    }
};

// ============================================================================
// Null Target (discards output)
// ============================================================================

/// Target that discards all output (for benchmarking/analysis)
pub const NullTarget = struct {
    bytes_written: u64,

    const Self = @This();

    pub fn init() Self {
        return Self{ .bytes_written = 0 };
    }

    pub fn target(self: *Self) Target {
        return Target{
            .ctx = self,
            .write_fn = writeImpl,
            .seek_fn = null,
            .tell_fn = tellImpl,
            .flush_fn = null,
        };
    }

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.bytes_written += data.len;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bytes_written;
    }
};

// ============================================================================
// Callback Target (for streaming/custom output)
// ============================================================================

/// Target that calls a callback for each write
pub fn CallbackTarget(comptime Context: type) type {
    return struct {
        ctx: Context,
        callback: *const fn (Context, []const u8) anyerror!void,
        bytes_written: u64,

        const Self = @This();

        pub fn init(ctx: Context, callback: *const fn (Context, []const u8) anyerror!void) Self {
            return Self{
                .ctx = ctx,
                .callback = callback,
                .bytes_written = 0,
            };
        }

        pub fn target(self: *Self) Target {
            return Target{
                .ctx = self,
                .write_fn = writeImpl,
                .seek_fn = null,
                .tell_fn = tellImpl,
                .flush_fn = null,
            };
        }

        fn writeImpl(ctx_ptr: *anyopaque, data: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx_ptr));
            try self.callback(self.ctx, data);
            self.bytes_written += data.len;
        }

        fn tellImpl(ctx_ptr: *anyopaque) u64 {
            const self: *Self = @ptrCast(@alignCast(ctx_ptr));
            return self.bytes_written;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "BufferTarget write" {
    var tgt = BufferTarget.init(std.testing.allocator);
    defer tgt.deinit();
    var target_obj = tgt.target();

    try target_obj.write("Hello");
    try target_obj.write(", World!");

    try std.testing.expectEqualSlices(u8, "Hello, World!", tgt.getData());
}

test "BufferTarget seek and overwrite" {
    var tgt = BufferTarget.init(std.testing.allocator);
    defer tgt.deinit();
    var target_obj = tgt.target();

    try target_obj.write("Hello, World!");
    _ = try target_obj.seek(7, .start);
    try target_obj.write("Zig!!");

    // Overwrites from pos 7: "World!" -> "Zig!!" leaves last char '!' intact
    try std.testing.expectEqualSlices(u8, "Hello, Zig!!!", tgt.getData());
}

test "BufferTarget write integers" {
    var tgt = BufferTarget.init(std.testing.allocator);
    defer tgt.deinit();
    var target_obj = tgt.target();

    try target_obj.writeU32Le(0x12345678);
    try target_obj.writeU32Be(0x12345678);

    const data = tgt.getData();
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, data[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, data[4..8], .big));
}

test "NullTarget" {
    var tgt = NullTarget.init();
    var target_obj = tgt.target();

    try target_obj.write("Hello");
    try target_obj.write("World");

    try std.testing.expectEqual(@as(u64, 10), tgt.bytes_written);
}
