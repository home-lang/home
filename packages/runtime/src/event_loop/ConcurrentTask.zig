// Copied from bun/src/event_loop/ConcurrentTask.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home") and
// `bun.UnboundedQueue` → `home_rt.threading.UnboundedQueue`. The JSC
// `Task` type (must remain exactly 8 bytes to satisfy the
// `@sizeOf(ConcurrentTask) == 16` invariant), `ManagedTask`, `TrivialNew`,
// `TrivialDeinit`, and `markBinding` are local stubs — they re-attach to
// the real JSC bridge in Phase 12.2. The packed-next-pointer ABI is kept
// verbatim so a future swap to the real `jsc.Task` is a drop-in change.

//! A task that runs concurrently in the work pool.
//!
//! This is used to run tasks that are CPU-intensive or blocking on the work pool.
//! It's also used to run tasks that need to be run on a different thread than the main JavaScript thread.
//!
//! The task is run on a thread pool and then the result is returned to the main JavaScript thread.
//!
//! If `auto_delete` is true, the task is automatically deallocated when it's finished.
//! Otherwise, it's expected that the containing struct will deallocate the task.

const ConcurrentTask = @This();

task: Task = undefined,
/// Packed representation of the next pointer and auto_delete flag.
/// Uses the low bit to store auto_delete (since pointers are at least 2-byte aligned).
next: PackedNextPtr = .none,

/// Packed next pointer that encodes both the next ConcurrentTask pointer and the auto_delete flag.
/// Uses the low bit for auto_delete since ConcurrentTask pointers are at least 2-byte aligned.
pub const PackedNextPtr = enum(usize) {
    none = 0,
    auto_delete = 1,
    _,

    pub inline fn init(ptr: ?*ConcurrentTask, auto_del: bool) PackedNextPtr {
        const ptr_bits = if (ptr) |p| @intFromPtr(p) else 0;
        return @enumFromInt(ptr_bits | @intFromBool(auto_del));
    }

    pub inline fn getPtr(self: PackedNextPtr) ?*ConcurrentTask {
        const addr = @intFromEnum(self) & ~@as(usize, 1);
        return if (addr == 0) null else @ptrFromInt(addr);
    }

    pub inline fn setPtr(self: *PackedNextPtr, ptr: ?*ConcurrentTask) void {
        const auto_del = @intFromEnum(self.*) & 1;
        const ptr_bits = if (ptr) |p| @intFromPtr(p) else 0;
        self.* = @enumFromInt(ptr_bits | auto_del);
    }

    pub inline fn isAutoDelete(self: PackedNextPtr) bool {
        return (@intFromEnum(self) & 1) != 0;
    }

    pub inline fn atomicLoadPtr(self: *const PackedNextPtr, ordering: std.builtin.AtomicOrder) ?*ConcurrentTask {
        const value = @atomicLoad(usize, @as(*const usize, @ptrCast(self)), ordering);
        const addr = value & ~@as(usize, 1);
        return if (addr == 0) null else @ptrFromInt(addr);
    }

    pub inline fn atomicStorePtr(self: *PackedNextPtr, ptr: ?*ConcurrentTask, ordering: std.builtin.AtomicOrder) void {
        const ptr_bits = if (ptr) |p| @intFromPtr(p) else 0;
        // auto_delete is immutable after construction, so we can safely read it
        // with a relaxed load and preserve it in the new value.
        const self_ptr: *usize = @ptrCast(self);
        const auto_del_bit = @atomicLoad(usize, self_ptr, .monotonic) & 1;
        @atomicStore(usize, self_ptr, ptr_bits | auto_del_bit, ordering);
    }
};

comptime {
    if (@sizeOf(ConcurrentTask) != 16) {
        @compileError("ConcurrentTask should be 16 bytes, but is " ++ std.fmt.comptimePrint("{}", .{@sizeOf(ConcurrentTask)}) ++ " bytes");
    }
    // PackedNextPtr stores a pointer in the upper bits and auto_delete in bit 0.
    // This requires ConcurrentTask to be at least 2-byte aligned.
    if (@alignOf(ConcurrentTask) < 2) {
        @compileError("ConcurrentTask must be at least 2-byte aligned for pointer packing, but alignment is " ++ std.fmt.comptimePrint("{}", .{@alignOf(ConcurrentTask)}));
    }
}

pub const Queue = UnboundedQueue(ConcurrentTask, .next);
pub const new = TrivialNew(@This());
pub const deinit = TrivialDeinit(@This());

pub const AutoDeinit = enum {
    manual_deinit,
    auto_deinit,
};

pub fn create(task: Task) *ConcurrentTask {
    return ConcurrentTask.new(.{
        .task = task,
        .next = .auto_delete,
    });
}

pub fn createFrom(task: anytype) *ConcurrentTask {
    markBinding(@src());
    return create(Task.init(task));
}

pub fn fromCallback(ptr: anytype, comptime callback: anytype) *ConcurrentTask {
    markBinding(@src());

    return create(ManagedTask.New(std.meta.Child(@TypeOf(ptr)), callback).init(ptr));
}

pub fn from(this: *ConcurrentTask, of: anytype, auto_deinit: AutoDeinit) *ConcurrentTask {
    markBinding(@src());

    this.* = .{
        .task = Task.init(of),
        .next = if (auto_deinit == .auto_deinit) .auto_delete else .none,
    };
    return this;
}

/// Returns whether this task should be automatically deallocated after execution.
pub fn autoDelete(this: *const ConcurrentTask) bool {
    return this.next.isAutoDelete();
}

// ---- Local stubs ------------------------------------------------------
// These re-attach to the real JSC bridge in Phase 12.2. The `Task` ABI is
// pinned to 8 bytes so the `@sizeOf(ConcurrentTask) == 16` invariant
// asserted above continues to hold once the upstream
// `TaggedPointerUnion`-based `jsc.Task` lands. `ManagedTask` is the local
// port at `event_loop/ManagedTask.zig` (re-exported via
// `home_rt.event_loop.ManagedTask`).

// Phase 12.2: re-attached to the real `TaggedPointerUnion`-based `jsc.Task`.
pub const Task = jsc.Task;

// `TrivialNew` / `TrivialDeinit` re-attach to the real `home_rt.memory`
// helpers in Phase 12.2. The behavior matches upstream Bun: both go
// through `home_rt.default_allocator`. We accept `comptime T: type` and
// return `*const fn`-style helpers identical in shape to upstream Bun's
// generic constructors.
fn TrivialNew(comptime T: type) fn (T) *T {
    return struct {
        fn newFn(value: T) *T {
            const ptr = home_rt.handleOom(home_rt.default_allocator.create(T));
            ptr.* = value;
            return ptr;
        }
    }.newFn;
}

fn TrivialDeinit(comptime T: type) fn (*T) void {
    return struct {
        fn deinitFn(self: *T) void {
            home_rt.default_allocator.destroy(self);
        }
    }.deinitFn;
}

// markBinding is a debug breadcrumb in upstream Bun; we keep it as a
// no-op stub so call-sites compile unchanged.
fn markBinding(comptime _: std.builtin.SourceLocation) void {}

const std = @import("std");

const home_rt = @import("home");
const jsc = home_rt.jsc;
const UnboundedQueue = home_rt.threading.UnboundedQueue;
const ManagedTask = home_rt.event_loop.ManagedTask;

// ---- Inline tests -----------------------------------------------------
// Verifies the packed-next pointer encoding, the 16-byte size invariant,
// and the create/from constructors all behave as the original
// pointer-tagging contract expects.

const testing = std.testing;

test "ConcurrentTask: size & alignment invariants hold" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(ConcurrentTask));
    try testing.expect(@alignOf(ConcurrentTask) >= 2);
    try testing.expectEqual(@as(usize, 8), @sizeOf(Task));
}

test "ConcurrentTask: PackedNextPtr round-trips pointer + auto_delete" {
    var dummy: ConcurrentTask = .{};
    const packed_no_auto = PackedNextPtr.init(&dummy, false);
    try testing.expectEqual(@as(?*ConcurrentTask, &dummy), packed_no_auto.getPtr());
    try testing.expect(!packed_no_auto.isAutoDelete());

    const packed_auto = PackedNextPtr.init(&dummy, true);
    try testing.expectEqual(@as(?*ConcurrentTask, &dummy), packed_auto.getPtr());
    try testing.expect(packed_auto.isAutoDelete());

    const packed_null = PackedNextPtr.init(null, true);
    try testing.expectEqual(@as(?*ConcurrentTask, null), packed_null.getPtr());
    try testing.expect(packed_null.isAutoDelete());
}

test "ConcurrentTask: setPtr preserves auto_delete bit" {
    var a: ConcurrentTask = .{};
    var b: ConcurrentTask = .{};

    var p = PackedNextPtr.init(&a, true);
    try testing.expect(p.isAutoDelete());

    p.setPtr(&b);
    try testing.expectEqual(@as(?*ConcurrentTask, &b), p.getPtr());
    try testing.expect(p.isAutoDelete());

    p.setPtr(null);
    try testing.expectEqual(@as(?*ConcurrentTask, null), p.getPtr());
    try testing.expect(p.isAutoDelete());
}

test "ConcurrentTask: atomicLoadPtr/atomicStorePtr keep auto_delete bit" {
    var a: ConcurrentTask = .{};
    var b: ConcurrentTask = .{};

    var p = PackedNextPtr.init(&a, true);
    try testing.expectEqual(@as(?*ConcurrentTask, &a), p.atomicLoadPtr(.acquire));

    p.atomicStorePtr(&b, .release);
    try testing.expectEqual(@as(?*ConcurrentTask, &b), p.atomicLoadPtr(.acquire));
    try testing.expect(p.isAutoDelete());
}

test "ConcurrentTask: create / from set next correctly" {
    var sentinel: u32 = 0;
    const made = ConcurrentTask.create(Task.init(&sentinel));
    defer made.deinit();
    try testing.expect(made.autoDelete());
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), made.task.ptr);

    var stack: ConcurrentTask = .{};
    _ = stack.from(&sentinel, .manual_deinit);
    try testing.expect(!stack.autoDelete());
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), stack.task.ptr);

    var stack_auto: ConcurrentTask = .{};
    _ = stack_auto.from(&sentinel, .auto_deinit);
    try testing.expect(stack_auto.autoDelete());
}

test "ConcurrentTask: Queue enqueue/dequeue (UnboundedQueue substrate)" {
    var q: Queue = .{};
    var sentinel_a: u32 = 1;
    var sentinel_b: u32 = 2;

    const a = ConcurrentTask.create(Task.init(&sentinel_a));
    defer a.deinit();
    const b = ConcurrentTask.create(Task.init(&sentinel_b));
    defer b.deinit();

    q.push(a);
    q.push(b);

    const popped_a = q.pop().?;
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel_a)), popped_a.task.ptr);
    const popped_b = q.pop().?;
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel_b)), popped_b.task.ptr);
    try testing.expectEqual(@as(?*ConcurrentTask, null), q.pop());
}
