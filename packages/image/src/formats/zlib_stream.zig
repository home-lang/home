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
    const Z_BUF_ERROR = -5;
    const Z_NO_FLUSH = 0;
    const Z_FINISH = 4;
    extern fn zlibVersion() [*:0]const u8;
    extern fn deflateInit_(*z_stream, c_int, [*:0]const u8, c_int) c_int;
    extern fn deflate(*z_stream, c_int) c_int;
    extern fn deflateEnd(*z_stream) c_int;
    extern fn inflateInit_(*z_stream, [*:0]const u8, c_int) c_int;
    extern fn inflate(*z_stream, c_int) c_int;
    extern fn inflateEnd(*z_stream) c_int;
};
pub const Deflater = struct {
    allocator: std.mem.Allocator,
    workspace: Workspace,
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
        self.* = .{ .allocator = allocator, .workspace = .{ .allocator = allocator } };
        self.stream.zalloc = Workspace.allocate;
        self.stream.zfree = Workspace.release;
        self.stream.opaque_context = &self.workspace;
        errdefer if (self.stream.state != null) {
            _ = c.deflateEnd(&self.stream);
        };
        try status(init(&self.stream, @intCast(level)));
        return self;
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
// Native allocation callbacks shared by pinned compression/inflation owners.
const Workspace = struct {
    allocator: std.mem.Allocator,
    limit: usize = std.math.maxInt(usize),
    live: usize = 0,
    fn allocate(ctx: ?*anyopaque, count: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
        const self: *Workspace = @ptrCast(@alignCast(ctx.?));
        const payload = std.math.mul(usize, count, size) catch return null;
        const total = std.math.add(usize, payload, 16) catch return null;
        if (total > self.limit - self.live) return null;
        const bytes = self.allocator.alignedAlloc(u8, .@"16", total) catch return null;
        @memset(bytes, 0);
        std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], total, .little);
        self.live += total;
        return @ptrCast(bytes.ptr + 16);
    }
    fn release(ctx: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
        const block = address orelse return;
        const self: *Workspace = @ptrCast(@alignCast(ctx.?));
        const start: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(block)) - 16);
        const length = std.mem.readInt(usize, start[0..@sizeOf(usize)], .little);
        std.debug.assert(length <= self.live);
        self.allocator.free(start[0..length]);
        self.live -= length;
    }
};
/// A conservative hard ceiling for one native inflate context, including block
/// prefixes. PNG planners include this in their live-workspace bound.
pub const inflate_workspace_limit = 256 * 1024;
fn checkInflate(input: []const u8, output_length: usize) !void {
    if (input.len < 6) return error.InvalidCompressedData;
    if (input.len > std.math.maxInt(c_uint) or output_length >= @min(std.math.maxInt(c_uint), std.math.maxInt(c_ulong))) return error.StreamTooLarge;
    if (input[0] & 15 != 8 or input[0] >> 4 > 7 or input[1] & 32 != 0 or (@as(u16, input[0]) * 256 + input[1]) % 31 != 0) return error.InvalidCompressedData;
}
const Inflater = struct {
    stream: c.z_stream = std.mem.zeroes(c.z_stream),
    workspace: Workspace,
};
/// Stream one checksum-verified zlib stream to a provisional sink under a hard
/// output ceiling. At most 32 KiB is offered per synchronous sink call. Errors
/// can leave a sink prefix; callers own staging/publication and cancellation.
/// Native workspace uses the caller allocator and is retired on every outcome.
pub fn inflateTo(allocator: std.mem.Allocator, input: []const u8, sink: anytype, limit: usize) !usize {
    try checkInflate(input, limit);
    const self = try allocator.create(Inflater);
    defer allocator.destroy(self);
    self.* = .{ .workspace = .{ .allocator = allocator, .limit = inflate_workspace_limit } };
    self.stream.zalloc = Workspace.allocate;
    self.stream.zfree = Workspace.release;
    self.stream.opaque_context = &self.workspace;
    const init = c.inflateInit_(&self.stream, c.zlibVersion(), @sizeOf(c.z_stream));
    defer {
        if (self.stream.state != null) _ = c.inflateEnd(&self.stream);
        std.debug.assert(self.workspace.live == 0);
    }
    if (init == c.Z_MEM_ERROR) return error.OutOfMemory;
    if (init != c.Z_OK) return error.InvalidCompressedData;
    self.stream.next_in = input.ptr;
    self.stream.avail_in = @intCast(input.len);
    defer {
        self.stream.next_in = null;
        self.stream.next_out = null;
        self.stream.avail_in = 0;
        self.stream.avail_out = 0;
    }
    var total: usize = 0;
    while (true) {
        const before = self.stream.avail_in;
        var bytes: [32768]u8 = undefined;
        const capacity = @min(bytes.len, limit - total + 1);
        self.stream.next_out = &bytes;
        self.stream.avail_out = @intCast(capacity);
        const rc = c.inflate(&self.stream, c.Z_NO_FLUSH);
        const written = capacity - self.stream.avail_out;
        if (written > limit - total) return error.InflateOutputLimit;
        if (written != 0) try sink.writeAll(bytes[0..written]);
        total += written;
        if (rc == c.Z_STREAM_END) {
            if (self.stream.avail_in != 0 or self.stream.total_in != input.len) return error.InvalidCompressedData;
            return total;
        }
        if (rc == c.Z_MEM_ERROR) return error.OutOfMemory;
        if (rc != c.Z_OK and rc != c.Z_BUF_ERROR) return error.InvalidCompressedData;
        if (before == self.stream.avail_in and written == 0) return error.InvalidCompressedData;
    }
}
/// Decode to bounded provisional output. Output can contain a prefix on error;
/// source/output overlap rejects before native allocation or the first write.
pub fn inflateInto(allocator: std.mem.Allocator, input: []const u8, output: []u8) !usize {
    try checkInflate(input, output.len);
    if (output.len != 0) {
        const a = @intFromPtr(input.ptr);
        const b = @intFromPtr(output.ptr);
        if ((a <= b and b - a < input.len) or (b < a and a - b < output.len)) return error.Overlap;
    }
    const Sink = struct {
        bytes: []u8,
        offset: usize = 0,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > self.bytes.len - self.offset) return error.InflateOutputLimit;
            @memcpy(self.bytes[self.offset..][0..bytes.len], bytes);
            self.offset += bytes.len;
        }
    };
    var sink = Sink{ .bytes = output };
    return inflateTo(allocator, input, &sink, output.len);
}
/// Compact owned inflated bytes under an explicit output ceiling.
pub fn inflateOwned(allocator: std.mem.Allocator, input: []const u8, limit: usize) ![]u8 {
    try checkInflate(input, limit);
    const bytes = try allocator.alloc(u8, limit);
    errdefer allocator.free(bytes);
    const size = try inflateInto(allocator, input, bytes);
    return allocator.realloc(bytes, size);
}

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

test "bounded inflate verifies exact checksums end and output length with no retained native workspace" {
    const t = std.testing;
    const large: [90000]u8 = @splat(0x37);
    for ([_][]const u8{ "", "pixels", &large }) |plain| {
        const compressed = try compress(t.allocator, plain, 6);
        defer t.allocator.free(compressed);
        const out = try t.allocator.alloc(u8, plain.len);
        defer t.allocator.free(out);
        try t.expectEqual(plain.len, try inflateInto(t.allocator, compressed, out));
        try t.expectEqualSlices(u8, plain, out);
        if (plain.len != 0) try t.expectError(error.InflateOutputLimit, inflateInto(t.allocator, compressed, out[0 .. out.len - 1]));
        for (0..compressed.len) |length| try t.expectError(error.InvalidCompressedData, inflateInto(t.allocator, compressed[0..length], out));
        const extra = try std.mem.concat(t.allocator, u8, &.{ compressed, &.{0} });
        defer t.allocator.free(extra);
        try t.expectError(error.InvalidCompressedData, inflateInto(t.allocator, extra, out));
        const corrupt = try t.allocator.dupe(u8, compressed);
        defer t.allocator.free(corrupt);
        corrupt[corrupt.len - 1] ^= 1;
        try t.expectError(error.InvalidCompressedData, inflateInto(t.allocator, corrupt, out));
    }
}
fn inflateFailureProbe(a: std.mem.Allocator, compressed: []const u8) !void {
    const decoded = try inflateOwned(a, compressed, 256);
    defer a.free(decoded);
    try std.testing.expectEqualStrings("allocator owned bounded inflation", decoded);
}
test "bounded inflate allocation failures retire native workspace and unpublished output exactly once" {
    const t = std.testing;
    const compressed = try compress(t.allocator, "allocator owned bounded inflation", 6);
    defer t.allocator.free(compressed);
    try std.testing.checkAllAllocationFailures(t.allocator, inflateFailureProbe, .{compressed});
    try t.expectError(error.InvalidCompressedData, inflateInto(t.failing_allocator, &.{}, &.{}));
    try t.expectError(error.OutOfMemory, inflateInto(t.failing_allocator, compressed, &.{}));
}

test "inflate preflight rejects malformed headers dictionaries and overlap before native allocation or writes" {
    const t = std.testing;
    const compressed = try compress(t.allocator, "pixels", 1);
    defer t.allocator.free(compressed);
    const before = try t.allocator.dupe(u8, compressed);
    defer t.allocator.free(before);
    try t.expectError(error.Overlap, inflateInto(t.failing_allocator, compressed, compressed[1..]));
    try t.expectEqualSlices(u8, before, compressed);
    for ([_][2]u8{ .{ 0, 0 }, .{ 0x78, 0x20 }, .{ 0x88, 0x98 } }) |header| {
        const bytes = [_]u8{ header[0], header[1], 1, 0, 0, 0, 0, 0 };
        try t.expectError(error.InvalidCompressedData, inflateOwned(t.failing_allocator, &bytes, 100));
    }
}

test "streaming inflate offers bounded chunks and joins sink failure without retaining source or workspace" {
    const t = std.testing;
    const plain = try t.allocator.alloc(u8, 90000);
    defer t.allocator.free(plain);
    @memset(plain, 0x35);
    const compressed = try compress(t.allocator, plain, 6);
    defer t.allocator.free(compressed);
    const Sink = struct {
        count: usize = 0,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try t.expect(bytes.len <= 32768);
            try t.expect(std.mem.allEqual(u8, bytes, 0x35));
            self.count += bytes.len;
        }
    };
    var sink: Sink = .{};
    try t.expectEqual(plain.len, try inflateTo(t.allocator, compressed, &sink, plain.len));
    try t.expectEqual(plain.len, sink.count);
    const Failed = struct {
        pub fn writeAll(_: *@This(), _: []const u8) !void {
            return error.Cancelled;
        }
    };
    var failed: Failed = .{};
    try t.expectError(error.Cancelled, inflateTo(t.allocator, compressed, &failed, plain.len));
}
