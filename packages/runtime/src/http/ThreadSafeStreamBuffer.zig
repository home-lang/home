// Copied from bun/src/http/ThreadSafeStreamBuffer.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Mutex-guarded `StreamBuffer` plus a 2-thread refcount + drain callback. The
// upstream file is 61 lines and pulls in three substrate types that aren't
// fully ported yet:
//
//   * `bun.io.StreamBuffer` — a cursor + `std.array_list.Managed(u8)` queue
//     that lives in `bun/src/io/PipeWriter.zig` (lines 1111-1230). The
//     full type carries `writeLatin1` / `writeUTF16` / `writeOrFallback`
//     branches that pull in `bun.ByteList`, but `ThreadSafeStreamBuffer`
//     itself only references `.deinit()` and `.isEmpty()`. We inline a
//     minimal `StreamBuffer` shaped to that subset here. When `bun.io`
//     ports, this swaps to `home_rt.io.StreamBuffer` 1-for-1.
//   * `bun.ptr.ThreadSafeRefCount(Self, "ref_count", Self.deinit, .{})` —
//     a thread-safe refcount mixin. We inline a minimal equivalent below
//     because `home_rt.ptr.ThreadSafeRefCount` hasn't ported yet.
//   * `bun.TrivialNew(Self)` / `bun.destroy(...)` — boil down to a
//     `default_allocator.create(Self)` / `default_allocator.destroy(self)`.
//
// `bun.Mutex` → `home_rt.threading.Mutex` (already ported).
//
// Upstream initialises `ref_count` with `.initExactRefs(2)` (one for the
// main thread, one for the http thread). We mirror that exact bootstrap.

const std = @import("std");
const home_rt = @import("home_rt");

const Mutex = home_rt.threading.Mutex;
const default_allocator = home_rt.default_allocator;

const ThreadSafeStreamBuffer = @This();

buffer: StreamBuffer = .{},
mutex: Mutex = .{},
ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2), // 1 for main thread, 1 for http thread.
// callback is called once the buffer has been drained, but only if the end
// chunk was not sent / reported yet.
callback: ?Callback = null,

pub const Callback = struct {
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,

    pub fn init(comptime T: type, callback_fn: *const fn (*T) void, context: *T) Callback {
        return .{ .callback = @ptrCast(callback_fn), .context = @ptrCast(context) };
    }

    pub fn call(this: Callback) void {
        this.callback(this.context);
    }
};

pub fn new() *ThreadSafeStreamBuffer {
    const self = default_allocator.create(ThreadSafeStreamBuffer) catch @panic("ThreadSafeStreamBuffer.new: out of memory");
    self.* = .{};
    return self;
}

pub fn ref(this: *ThreadSafeStreamBuffer) void {
    _ = this.ref_count.fetchAdd(1, .monotonic);
}

pub fn deref(this: *ThreadSafeStreamBuffer) void {
    const prev = this.ref_count.fetchSub(1, .release);
    if (prev == 1) {
        // Acquire ordering pairs with the release on every other deref so
        // the deinit reads happen-after every prior write to `this`.
        _ = this.ref_count.load(.acquire);
        this.deinit();
    }
}

pub fn acquire(this: *ThreadSafeStreamBuffer) *StreamBuffer {
    this.mutex.lock();
    return &this.buffer;
}

pub fn release(this: *ThreadSafeStreamBuffer) void {
    this.mutex.unlock();
}

/// Should only be called from the main thread, before this buffer is
/// scheduled onto the http thread.
pub fn setDrainCallback(this: *ThreadSafeStreamBuffer, comptime T: type, callback_fn: *const fn (*T) void, context: *T) void {
    this.callback = Callback.init(T, callback_fn, context);
}

pub fn clearDrainCallback(this: *ThreadSafeStreamBuffer) void {
    this.callback = null;
}

/// This is exclusively called from the http thread. Buffer must be
/// `acquire`d first.
pub fn reportDrain(this: *ThreadSafeStreamBuffer) void {
    if (this.buffer.isEmpty()) {
        if (this.callback) |callback| {
            callback.call();
        }
    }
}

pub fn deinit(this: *ThreadSafeStreamBuffer) void {
    this.buffer.deinit();
    default_allocator.destroy(this);
}

/// PORT NOTE: subset of upstream `bun.io.StreamBuffer` (defined in
/// `src/io/PipeWriter.zig` lines 1111-1230). Only the methods
/// `ThreadSafeStreamBuffer` itself dispatches on — `isEmpty`, `deinit`,
/// plus `write`/`slice`/`wrote`/`size` since those are the canonical
/// drain-API entry points that any code reaching into `.acquire().*` will
/// expect to find. The `writeLatin1` / `writeUTF16` / `writeOrFallback`
/// branches stay parked until `bun.ByteList` ports.
pub const StreamBuffer = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,

    pub fn reset(this: *StreamBuffer) void {
        this.cursor = 0;
        this.list.clearRetainingCapacity();
    }

    pub fn memoryCost(this: *const StreamBuffer) usize {
        return this.list.capacity;
    }

    pub fn size(this: *const StreamBuffer) usize {
        return this.list.items.len - this.cursor;
    }

    pub fn isEmpty(this: *const StreamBuffer) bool {
        return this.size() == 0;
    }

    pub fn isNotEmpty(this: *const StreamBuffer) bool {
        return this.size() > 0;
    }

    pub fn write(this: *StreamBuffer, buffer: []const u8) std.mem.Allocator.Error!void {
        try this.list.appendSlice(default_allocator, buffer);
    }

    pub fn wrote(this: *StreamBuffer, amount: usize) void {
        this.cursor += amount;
    }

    pub fn writeAssumeCapacity(this: *StreamBuffer, buffer: []const u8) void {
        this.list.appendSliceAssumeCapacity(buffer);
    }

    pub fn ensureUnusedCapacity(this: *StreamBuffer, capacity: usize) std.mem.Allocator.Error!void {
        return this.list.ensureUnusedCapacity(default_allocator, capacity);
    }

    pub fn slice(this: *const StreamBuffer) []const u8 {
        return this.list.items[this.cursor..];
    }

    pub fn deinit(this: *StreamBuffer) void {
        this.cursor = 0;
        this.list.deinit(default_allocator);
    }
};

// -- Inline tests -------------------------------------------------------

test "ThreadSafeStreamBuffer.new initialises refcount to 2 and an empty buffer" {
    var t = ThreadSafeStreamBuffer.new();
    try std.testing.expectEqual(@as(u32, 2), t.ref_count.load(.monotonic));
    try std.testing.expect(t.buffer.isEmpty());
    // Bring it down to 0 to clean up.
    t.deref();
    t.deref();
}

test "ThreadSafeStreamBuffer.acquire/release round-trips the inner buffer" {
    var t = ThreadSafeStreamBuffer.new();
    defer {
        t.deref();
        t.deref();
    }
    const buf = t.acquire();
    try buf.write("home");
    t.release();

    const buf2 = t.acquire();
    defer t.release();
    try std.testing.expectEqualSlices(u8, "home", buf2.slice());
}

test "ThreadSafeStreamBuffer.reportDrain fires the callback only when empty" {
    var t = ThreadSafeStreamBuffer.new();
    defer {
        t.deref();
        t.deref();
    }
    var hit_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn cb(self: *@This()) void {
            self.count.* += 1;
        }
    };
    var ctx = Ctx{ .count = &hit_count };
    t.setDrainCallback(Ctx, Ctx.cb, &ctx);

    // Non-empty buffer → no fire.
    const buf = t.acquire();
    try buf.write("x");
    t.reportDrain();
    t.release();
    try std.testing.expectEqual(@as(u32, 0), hit_count);

    // Drain it.
    const buf2 = t.acquire();
    buf2.reset();
    t.reportDrain();
    t.release();
    try std.testing.expectEqual(@as(u32, 1), hit_count);
}

test "ThreadSafeStreamBuffer.clearDrainCallback unhooks the callback" {
    var t = ThreadSafeStreamBuffer.new();
    defer {
        t.deref();
        t.deref();
    }
    var hit_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn cb(self: *@This()) void {
            self.count.* += 1;
        }
    };
    var ctx = Ctx{ .count = &hit_count };
    t.setDrainCallback(Ctx, Ctx.cb, &ctx);
    t.clearDrainCallback();

    _ = t.acquire();
    t.reportDrain();
    t.release();
    try std.testing.expectEqual(@as(u32, 0), hit_count);
}

test "StreamBuffer.size/isEmpty track cursor and items" {
    var b: StreamBuffer = .{};
    defer b.deinit();
    try std.testing.expect(b.isEmpty());
    try b.write("abc");
    try std.testing.expect(b.isNotEmpty());
    try std.testing.expectEqual(@as(usize, 3), b.size());
    b.wrote(2);
    try std.testing.expectEqual(@as(usize, 1), b.size());
    try std.testing.expectEqualSlices(u8, "c", b.slice());
}
