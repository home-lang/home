// Copied from bun/src/jsc/JSONLineBuffer.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Buffer for newline-delimited data that tracks scan positions to avoid
// O(n^2) scanning. Each byte is scanned exactly once. We track:
//   - `newline_pos`: position of first known newline (if any)
//   - `scanned_pos`: how far we've scanned (bytes before this have been checked)
//   - `head`: offset into the buffer where unconsumed data starts (avoids
//     copying on each consume).
// Compaction only happens when `head` exceeds a threshold.
//
// `bun.ByteList` (upstream's exact-capacity Vec-like, used as the backing
// storage) is not yet ported. We define a structurally compatible local
// `ByteList` here so the buffer's API stays byte-for-byte identical and
// re-attaches in Phase 12.2 by swapping the alias to `home_rt.ByteList`.

const std = @import("std");
const home_rt = @import("home_rt");
const Allocator = std.mem.Allocator;

/// Stub for `bun.ByteList`. Real upstream is a packed `{ ptr, len, cap }`
/// with `write` / `ensureUnusedCapacity` / `unusedCapacitySlice` / `slice` /
/// `deinit` semantics. We retain the same fields (`ptr` / `len` / `cap`) and
/// the methods this file depends on so the byte layout — and the iteration
/// semantics — line up when the real ByteList is wired in.
const ByteList = struct {
    ptr: [*]u8 = undefined,
    len: u32 = 0,
    cap: u32 = 0,

    pub fn slice(self: *const ByteList) []u8 {
        return self.ptr[0..self.len];
    }

    pub fn unusedCapacitySlice(self: *ByteList) []u8 {
        return self.ptr[self.len..self.cap];
    }

    pub fn write(self: *ByteList, allocator: Allocator, bytes: []const u8) Allocator.Error!u32 {
        try self.ensureUnusedCapacity(allocator, bytes.len);
        @memcpy(self.ptr[self.len .. self.len + bytes.len], bytes);
        self.len += @intCast(bytes.len);
        return @intCast(bytes.len);
    }

    pub fn ensureUnusedCapacity(self: *ByteList, allocator: Allocator, additional: usize) Allocator.Error!void {
        const needed = self.len + additional;
        if (needed <= self.cap) return;

        // Power-of-two growth, starting at 64 bytes — matches the upstream
        // ByteList growth curve closely enough for the consume/append cycle.
        var new_cap: usize = if (self.cap == 0) 64 else self.cap;
        while (new_cap < needed) new_cap *|= 2;

        const old_slice = self.ptr[0..self.cap];
        const new_buf = if (self.cap == 0)
            try allocator.alloc(u8, new_cap)
        else blk: {
            const reallocated = allocator.realloc(old_slice, new_cap) catch |err| return err;
            break :blk reallocated;
        };

        self.ptr = new_buf.ptr;
        self.cap = @intCast(new_cap);
    }

    pub fn deinit(self: *ByteList, allocator: Allocator) void {
        if (self.cap > 0) allocator.free(self.ptr[0..self.cap]);
        self.* = .{};
    }
};

/// Stub for `bun.debugAssert` — upstream is the no-op-in-release form of the
/// assertion. Wires into `std.debug.assert` only in debug builds.
inline fn debugAssert(condition: bool) void {
    if (home_rt.Environment.allow_assert) std.debug.assert(condition);
}

/// Stub for `bun.copy(comptime T, dest, src)`. Real upstream collapses to a
/// `@memcpy` after asserting the destination is large enough; we keep the
/// shape so the call sites read naturally.
inline fn copy(comptime T: type, dest: []T, src: []const T) void {
    debugAssert(dest.len >= src.len);
    @memcpy(dest[0..src.len], src);
}

pub const JSONLineBuffer = struct {
    data: ByteList = .{},
    /// Offset into `data` where unconsumed content starts.
    head: u32 = 0,
    /// Position of a known upcoming newline relative to `head`, if any.
    newline_pos: ?u32 = null,
    /// How far we've scanned for newlines relative to `head`.
    scanned_pos: u32 = 0,

    /// Compact the buffer when `head` exceeds this threshold.
    const compaction_threshold = 16 * 1024 * 1024; // 16 MB

    /// Get the active (unconsumed) portion of the buffer.
    fn activeSlice(self: *const @This()) []const u8 {
        return self.data.slice()[self.head..];
    }

    /// Scan for newline in the unscanned portion of the buffer.
    fn scanForNewline(self: *@This()) void {
        if (self.newline_pos != null) return;
        const sl = self.activeSlice();
        if (self.scanned_pos >= sl.len) return;

        const unscanned = sl[self.scanned_pos..];
        if (home_rt.strings.indexOfChar(unscanned, '\n')) |local_idx| {
            debugAssert(local_idx <= std.math.maxInt(u32));
            const pos = self.scanned_pos +| @as(u32, @intCast(local_idx));
            self.newline_pos = pos;
            self.scanned_pos = pos +| 1; // Only scanned up to (and including) the newline.
        } else {
            debugAssert(sl.len <= std.math.maxInt(u32));
            self.scanned_pos = @intCast(sl.len); // No newline, scanned everything.
        }
    }

    /// Compact the buffer by moving data to the front. Called when `head`
    /// exceeds the threshold.
    fn compact(self: *@This()) void {
        if (self.head == 0) return;
        const sl = self.activeSlice();
        copy(u8, self.data.ptr[0..sl.len], sl);
        debugAssert(sl.len <= std.math.maxInt(u32));
        self.data.len = @intCast(sl.len);
        self.head = 0;
    }

    /// Append bytes to the buffer, scanning only new data for newline.
    pub fn append(self: *@This(), bytes: []const u8) void {
        _ = home_rt.handleOom(self.data.write(home_rt.default_allocator, bytes));
        self.scanForNewline();
    }

    /// Returns the next complete message (up to and including newline) if available.
    pub fn next(self: *const @This()) ?struct { data: []const u8, newline_pos: u32 } {
        const pos = self.newline_pos orelse return null;
        return .{
            .data = self.activeSlice()[0 .. pos + 1],
            .newline_pos = pos,
        };
    }

    /// Consume bytes from the front of the buffer after processing a message.
    /// Just advances head offset — no copying until the compaction threshold
    /// is reached.
    pub fn consume(self: *@This(), bytes: u32) void {
        self.head +|= bytes;

        // Adjust scanned_pos (subtract consumed bytes, but don't go negative).
        self.scanned_pos = if (bytes >= self.scanned_pos) 0 else self.scanned_pos - bytes;

        // Adjust newline_pos.
        if (self.newline_pos) |pos| {
            if (bytes > pos) {
                // Consumed past the known newline — clear it and scan for next.
                self.newline_pos = null;
                self.scanForNewline();
            } else {
                self.newline_pos = pos - bytes;
            }
        }

        // Check if we've consumed everything.
        if (self.head >= self.data.len) {
            // Free memory if capacity exceeds threshold, otherwise just reset.
            if (self.data.cap >= compaction_threshold) {
                self.data.deinit(home_rt.default_allocator);
                self.data = .{};
            } else {
                self.data.len = 0;
            }
            self.head = 0;
            self.scanned_pos = 0;
            self.newline_pos = null;
            return;
        }

        // Compact if `head` exceeds threshold to avoid unbounded memory growth.
        if (self.head >= compaction_threshold) {
            self.compact();
        }
    }

    pub fn isEmpty(self: *const @This()) bool {
        return self.head >= self.data.len;
    }

    pub fn unusedCapacitySlice(self: *@This()) []u8 {
        return self.data.unusedCapacitySlice();
    }

    pub fn ensureUnusedCapacity(self: *@This(), additional: usize) void {
        home_rt.handleOom(self.data.ensureUnusedCapacity(home_rt.default_allocator, additional));
    }

    /// Notify the buffer that data was written directly (e.g., via pre-allocated slice).
    pub fn notifyWritten(self: *@This(), new_data: []const u8) void {
        debugAssert(new_data.len <= std.math.maxInt(u32));
        self.data.len +|= @as(u32, @intCast(new_data.len));
        self.scanForNewline();
    }

    pub fn deinit(self: *@This()) void {
        self.data.deinit(home_rt.default_allocator);
    }
};

test "JSONLineBuffer starts empty" {
    var buf: JSONLineBuffer = .{};
    defer buf.deinit();
    try std.testing.expect(buf.isEmpty());
    try std.testing.expect(buf.next() == null);
}

test "JSONLineBuffer.append/next handles a single newline-terminated message" {
    var buf: JSONLineBuffer = .{};
    defer buf.deinit();
    buf.append("hello\n");
    const msg = buf.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello\n", msg.data);
    try std.testing.expectEqual(@as(u32, 5), msg.newline_pos);
}

test "JSONLineBuffer.consume advances past the newline" {
    var buf: JSONLineBuffer = .{};
    defer buf.deinit();
    buf.append("foo\nbar\n");
    const first = buf.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("foo\n", first.data);
    buf.consume(4);
    const second = buf.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bar\n", second.data);
}

test "JSONLineBuffer.append without newline yields no message" {
    var buf: JSONLineBuffer = .{};
    defer buf.deinit();
    buf.append("partial");
    try std.testing.expect(buf.next() == null);
    buf.append(" line\n");
    const msg = buf.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("partial line\n", msg.data);
}

test "JSONLineBuffer.consume that drains the buffer resets state" {
    var buf: JSONLineBuffer = .{};
    defer buf.deinit();
    buf.append("abc\n");
    buf.consume(4);
    try std.testing.expect(buf.isEmpty());
    try std.testing.expect(buf.next() == null);
    try std.testing.expectEqual(@as(u32, 0), buf.head);
}
