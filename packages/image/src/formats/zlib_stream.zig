//! Pinned-address streaming zlib adapter for image codecs. Link libc and libz.
//! Keeps the C stream at a stable address and never retains borrowed input.
const std = @import("std");
// ABI adapted from Home runtime/src/zlib/zlib.zig (Bun fd0b6f1a271fca0b8124b69f230b100f4d636af6).
// MIT, see ../../../runtime/src/cli/LICENSE.bun.md. Kept independent of the
// runtime allocator and @cImport so pinned/development Zig share this adapter.
const c = struct {
    const z_stream = extern struct {
        next_in: [*c]const u8,
        avail_in: c_uint,
        total_in: c_ulong,
        next_out: [*c]u8,
        avail_out: c_uint,
        total_out: c_ulong,
        msg: [*c]const u8,
        state: ?*anyopaque,
        zalloc: ?*const fn (?*anyopaque, c_uint, c_uint) callconv(.c) ?*anyopaque,
        zfree: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
        opaque_context: ?*anyopaque,
        data_type: c_int,
        adler: c_ulong,
        reserved: c_ulong,
    };
    const Z_OK = 0;
    const Z_STREAM_END = 1;
    const Z_MEM_ERROR = -4;
    const Z_NO_FLUSH = 0;
    const Z_FINISH = 4;
    extern fn zlibVersion() [*:0]const u8;
    extern fn deflateInit_(*z_stream, c_int, [*:0]const u8, c_int) c_int;
    extern fn deflate(*z_stream, c_int) c_int;
    extern fn deflateEnd(*z_stream) c_int;
};
pub const Deflater = struct {
    allocator: std.mem.Allocator,
    stream: c.z_stream = std.mem.zeroes(c.z_stream),
    state: enum { open, finished, failed } = .open,

    pub fn create(allocator: std.mem.Allocator, level: u32) !*Deflater {
        return createWithInit(allocator, level, initialize);
    }
    fn initialize(stream: *c.z_stream, level: c_int) c_int {
        return c.deflateInit_(stream, level, c.zlibVersion(), @sizeOf(c.z_stream));
    }
    // Native workspace uses the caller allocator too; failed initialization
    // never publishes an owner, including partial native allocation failures.
    fn createWithInit(allocator: std.mem.Allocator, level: u32, comptime init: fn (*c.z_stream, c_int) c_int) !*Deflater {
        if (level > 9) return error.InvalidCompressionLevel;
        const self = try allocator.create(Deflater);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };
        self.stream.zalloc = allocateWorkspace;
        self.stream.zfree = freeWorkspace;
        self.stream.opaque_context = self;
        errdefer if (self.stream.state != null) {
            _ = c.deflateEnd(&self.stream);
        };
        try status(init(&self.stream, @intCast(level)));
        return self;
    }
    // A fixed aligned prefix records the exact allocation length for zfree.
    // All zlib blocks are covered by caller allocation budgets/failure injection.
    fn allocateWorkspace(ctx: ?*anyopaque, count: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
        const self: *Deflater = @ptrCast(@alignCast(ctx.?));
        const payload = std.math.mul(usize, count, size) catch return null;
        const total = std.math.add(usize, payload, 16) catch return null;
        const bytes = self.allocator.alignedAlloc(u8, .@"16", total) catch return null;
        @memset(bytes, 0);
        std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], total, .little);
        return @ptrCast(bytes.ptr + 16);
    }
    fn freeWorkspace(ctx: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
        const block = address orelse return;
        const self: *Deflater = @ptrCast(@alignCast(ctx.?));
        const start: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(block)) - 16);
        const length = std.mem.readInt(usize, start[0..@sizeOf(usize)], .little);
        self.allocator.free(start[0..length]);
    }
    pub fn deinit(self: *Deflater) void {
        // Aborting an unfinished stream may return DATA_ERROR after freeing its
        // workspace. deinit is disposal, never a successful finish operation.
        _ = c.deflateEnd(&self.stream);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    pub fn write(self: *Deflater, input: []const u8, sink: anytype) !void {
        if (self.state != .open) return error.InvalidState;
        defer {
            self.stream.next_in = null;
            self.stream.avail_in = 0;
            self.stream.next_out = null;
            self.stream.avail_out = 0;
        }
        errdefer self.state = .failed;
        var offset: usize = 0;
        while (offset < input.len) {
            const size = @min(input.len - offset, std.math.maxInt(c_uint));
            self.stream.next_in = @constCast(input[offset..].ptr);
            self.stream.avail_in = @intCast(size);
            while (self.stream.avail_in != 0) {
                const before = self.stream.avail_in;
                var out: [32768]u8 = undefined;
                self.stream.next_out = &out;
                self.stream.avail_out = out.len;
                try status(c.deflate(&self.stream, c.Z_NO_FLUSH));
                const written = out.len - self.stream.avail_out;
                if (written != 0) try sink.writeAll(out[0..written]);
                if (self.stream.avail_in == before and written == 0) return error.CompressionFailed;
            }
            offset += size;
        }
        // No borrowed input pointer survives this synchronous call.
        self.stream.next_in = null;
    }
    pub fn finish(self: *Deflater, sink: anytype) !void {
        if (self.state != .open) return error.InvalidState;
        defer {
            self.stream.next_out = null;
            self.stream.avail_out = 0;
        }
        errdefer self.state = .failed;
        self.stream.next_in = null;
        self.stream.avail_in = 0;
        while (true) {
            var out: [32768]u8 = undefined;
            self.stream.next_out = &out;
            self.stream.avail_out = out.len;
            const rc = c.deflate(&self.stream, c.Z_FINISH);
            if (rc != c.Z_STREAM_END) try status(rc);
            const written = out.len - self.stream.avail_out;
            if (written != 0) try sink.writeAll(out[0..written]);
            if (rc == c.Z_STREAM_END) break;
            if (written == 0) return error.CompressionFailed;
        }
        self.state = .finished;
    }
};
fn status(rc: c_int) !void {
    return switch (rc) {
        c.Z_OK => {},
        c.Z_MEM_ERROR => error.OutOfMemory,
        else => error.CompressionFailed,
    };
}
pub fn compress(allocator: std.mem.Allocator, bytes: []const u8, level: u32) ![]u8 {
    var sink = Buffer{ .allocator = allocator };
    errdefer sink.bytes.deinit(allocator);
    const stream = try Deflater.create(allocator, level);
    defer stream.deinit();
    try stream.write(bytes, &sink);
    try stream.finish(&sink);
    return sink.bytes.toOwnedSlice(allocator);
}
const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    fn writeAll(self: *Buffer, data: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, data);
    }
};
test "streamed levels round trip independently through Zig inflate and seal finish" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 200001);
    defer allocator.free(data);
    for (data, 0..) |*v, i| v.* = @truncate(i *% 19);
    for ([_]u32{ 0, 1, 6, 9 }) |level| {
        var sink = Buffer{ .allocator = allocator };
        defer sink.bytes.deinit(allocator);
        const stream = try Deflater.create(allocator, level);
        defer stream.deinit();
        try stream.write(data[0..31], &sink);
        try stream.write(&.{}, &sink);
        try stream.write(data[31..], &sink);
        try stream.finish(&sink);
        try std.testing.expectError(error.InvalidState, stream.finish(&sink));
        try std.testing.expectError(error.InvalidState, stream.write("late", &sink));
        var reader: std.Io.Reader = .fixed(sink.bytes.items);
        var inflate: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
        var decoded: std.Io.Writer.Allocating = .init(allocator);
        defer decoded.deinit();
        _ = try inflate.reader.streamRemaining(&decoded.writer);
        try std.testing.expectEqualSlices(u8, data, decoded.written());
    }
}
test "sink failure poisons streaming state and validation precedes allocation" {
    const Sink = struct {
        fn writeAll(_: *@This(), _: []const u8) !void {
            return error.SinkFailed;
        }
    };
    var sink: Sink = .{};
    const stream = try Deflater.create(std.testing.allocator, 1);
    defer stream.deinit();
    try std.testing.expectError(error.SinkFailed, stream.write("pixels", &sink));
    try std.testing.expectError(error.InvalidState, stream.finish(&sink));
    try std.testing.expectError(error.InvalidCompressionLevel, Deflater.create(std.testing.failing_allocator, 10));
    try std.testing.expectError(error.OutOfMemory, Deflater.create(std.testing.failing_allocator, 1));
}

test "native initialization failure frees the pinned owner exactly once without publication" {
    inline for (.{ c.Z_MEM_ERROR, @as(c_int, -2), @as(c_int, -6) }) |code| {
        const NativeFailure = struct {
            fn init(stream: *c.z_stream, level: c_int) c_int {
                std.debug.assert(stream.state == null and stream.next_in == null and stream.next_out == null);
                std.debug.assert(level == 1);
                return code;
            }
        };
        if (code == c.Z_MEM_ERROR) {
            try std.testing.expectError(error.OutOfMemory, Deflater.createWithInit(std.testing.allocator, 1, NativeFailure.init));
        } else {
            try std.testing.expectError(error.CompressionFailed, Deflater.createWithInit(std.testing.allocator, 1, NativeFailure.init));
        }
    }
    const MustNotRun = struct {
        fn init(_: *c.z_stream, _: c_int) c_int {
            @panic("native init called before level/owner admission");
        }
    };
    try std.testing.expectError(error.InvalidCompressionLevel, Deflater.createWithInit(std.testing.allocator, 10, MustNotRun.init));
    try std.testing.expectError(error.OutOfMemory, Deflater.createWithInit(std.testing.failing_allocator, 1, MustNotRun.init));
}

fn workspaceFailureProbe(allocator: std.mem.Allocator) !void {
    const bytes = try compress(allocator, "caller-owned native zlib workspace and output", 1);
    defer allocator.free(bytes);
}
test "all native workspace allocation failures unwind exactly once through the caller allocator" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, workspaceFailureProbe, .{});
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, Deflater.create(fail.allocator(), 1));
    try std.testing.expectEqual(fail.allocated_bytes, fail.freed_bytes);
}
