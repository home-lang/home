// Copied from bun/src/jsc/PosixSignalHandle.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Single-producer / single-consumer lock-free ring buffer for posix signals.
// The signal handler enqueues on the SIGNAL stack; the JS thread drains them
// later through `dequeue()` / `drain()`.
//
// Re-attached (was Phase 12.2 stub): `VirtualMachine` + `EventLoop` + `Task`
// have landed, so the upstream `drain` / `Bun__onPosixSignal` /
// `Bun__ensureSignalHandler` exports now wire the real path. The OS sigaction
// is installed by the linked C++ (`BunProcess.cpp`), whose handler calls
// `Bun__onPosixSignal` → `enqueue` → `wakeup`; the JS thread then `drain`s the
// ring into `PosixSignalTask`s that call back into C++ `Bun__onSignalForJS`.

const PosixSignalHandle = @This();

const buffer_size = 8192;

pub const new = bun.TrivialNew(@This());

signals: [buffer_size]u8 = undefined,

// Producer index (signal handler writes).
tail: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
// Consumer index (main thread reads).
head: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

/// Called by the signal handler (single producer).
/// Returns `true` if enqueued successfully, or `false` if the ring is full.
pub fn enqueue(this: *PosixSignalHandle, signal: u8) bool {
    // Read the current tail and head (Acquire to ensure we have up‐to‐date values).
    const old_tail = this.tail.load(.acquire);
    const head_val = this.head.load(.acquire);

    // Compute the next tail (wrapping around buffer_size).
    const next_tail = (old_tail +% 1) % buffer_size;

    // Check if the ring is full.
    if (next_tail == (head_val % buffer_size)) {
        // The ring buffer is full. We can't block / wait inside a signal
        // handler, so drop. The upstream `Output.scoped(.PosixSignalHandle)`
        // log call is omitted here (the scoped logger lands separately).
        return false;
    }

    // Store the signal into the ring buffer slot (Release to ensure data is visible).
    @atomicStore(u8, &this.signals[old_tail % buffer_size], signal, .release);

    // Publish the new tail (Release so that the consumer sees the updated tail).
    this.tail.store(old_tail +% 1, .release);

    // Wake the main-thread event loop so it `drain`s the ring promptly.
    // Guarded so the unit tests below (which run without a VM) don't trip
    // the null unwrap; in real signal-handler context the VM is always set.
    if (VirtualMachine.getMainThreadVM()) |vm| {
        vm.eventLoop().wakeup();
    }

    return true;
}

/// This is the signal handler entry point. Calls enqueue on the ring buffer.
/// Note: Must be minimal logic here. Only do atomics & signal‐safe calls.
export fn Bun__onPosixSignal(number: i32) void {
    if (comptime Environment.isPosix) {
        const vm = VirtualMachine.getMainThreadVM().?;
        _ = vm.eventLoop().signal_handler.?.enqueue(@intCast(number));
    }
}

/// Called by the main thread (single consumer).
/// Returns `null` if the ring is empty, or the next signal otherwise.
pub fn dequeue(this: *PosixSignalHandle) ?u8 {
    // Read the current head and tail.
    const old_head = this.head.load(.acquire);
    const tail_val = this.tail.load(.acquire);

    // If head == tail, the ring is empty.
    if (old_head == tail_val) {
        return null; // No available items
    }

    const slot_index = old_head % buffer_size;
    // Acquire load of the stored signal to get the item.
    const signal = @atomicRmw(u8, &this.signals[slot_index], .Xchg, 0, .acq_rel);

    // Publish the updated head (Release).
    this.head.store(old_head +% 1, .release);

    return signal;
}

/// Drain as many signals as possible and enqueue them as tasks in the event
/// loop. Called by the main thread. The signal number is packed into the
/// task's pointer slot (zero-allocation), matching the upstream carrier.
pub fn drain(this: *PosixSignalHandle, event_loop: *jsc.EventLoop) void {
    while (this.dequeue()) |signal| {
        var posix_signal_task: PosixSignalTask = undefined;
        var task = jsc.Task.init(&posix_signal_task);
        task.setUintptr(signal);
        event_loop.enqueueTask(task);
    }
}

/// Plain-data carrier emitted by `drain()`. The signal number rides in the
/// task pointer slot; `runFromJSThread` reads it back and crosses into the
/// linked C++ runtime callback to fire the JS `process.on(signal)` listeners.
pub const PosixSignalTask = struct {
    number: u8,
    extern "c" fn Bun__onSignalForJS(number: i32, globalObject: *jsc.JSGlobalObject) void;

    pub const new = bun.TrivialNew(@This());
    pub fn runFromJSThread(number: u8, globalObject: *jsc.JSGlobalObject) void {
        Bun__onSignalForJS(number, globalObject);
    }
};

export fn Bun__ensureSignalHandler() void {
    if (comptime Environment.isPosix) {
        if (VirtualMachine.getMainThreadVM()) |vm| {
            const this = vm.eventLoop();
            if (this.signal_handler == null) {
                this.signal_handler = PosixSignalHandle.new(.{});
                @memset(&this.signal_handler.?.signals, 0);
            }
        }
    }
}

comptime {
    if (Environment.isPosix) {
        _ = &Bun__ensureSignalHandler;
        _ = &Bun__onPosixSignal;
    }
}

test "PosixSignalHandle is empty after init" {
    var ring = PosixSignalHandle{};
    @memset(&ring.signals, 0);
    try std.testing.expectEqual(@as(?u8, null), ring.dequeue());
}

test "PosixSignalHandle SPSC round-trip" {
    var ring = PosixSignalHandle{};
    @memset(&ring.signals, 0);

    try std.testing.expect(ring.enqueue(2)); // SIGINT
    try std.testing.expect(ring.enqueue(15)); // SIGTERM

    try std.testing.expectEqual(@as(?u8, 2), ring.dequeue());
    try std.testing.expectEqual(@as(?u8, 15), ring.dequeue());
    try std.testing.expectEqual(@as(?u8, null), ring.dequeue());
}

test "PosixSignalHandle fills up then drops" {
    var ring = PosixSignalHandle{};
    @memset(&ring.signals, 0);

    // The ring can hold buffer_size - 1 entries before reporting full.
    var i: usize = 0;
    while (i < buffer_size - 1) : (i += 1) {
        try std.testing.expect(ring.enqueue(@truncate(i % 250)));
    }
    try std.testing.expect(!ring.enqueue(1)); // full
}

test "PosixSignalTask carries the signal number" {
    const t = PosixSignalTask{ .number = 9 };
    try std.testing.expectEqual(@as(u8, 9), t.number);
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;

const jsc = bun.jsc;
const VirtualMachine = jsc.VirtualMachine;
