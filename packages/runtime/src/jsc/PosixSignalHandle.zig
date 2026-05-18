// Copied from bun/src/jsc/PosixSignalHandle.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Single-producer / single-consumer lock-free ring buffer for posix signals.
// The signal handler enqueues on the SIGNAL stack; the JS thread drains them
// later through `dequeue()` / `drain()`. We keep the pure-Zig ring buffer +
// the `PosixSignalTask` plain-data carrier; the upstream `drain` /
// `Bun__onPosixSignal` / `Bun__ensureSignalHandler` exports cross into the
// event loop (`VirtualMachine.getMainThreadVM().?.eventLoop().signal_handler`,
// `jsc.Task.init(...)`), so they re-land once `VirtualMachine` + `EventLoop`
// + `Task` re-attach in Phase 12.2.

const std = @import("std");
const home_rt = @import("home_rt");

const PosixSignalHandle = @This();

const buffer_size = 8192;

signals: [buffer_size]u8 = undefined,

// Producer index (signal handler writes).
tail: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
// Consumer index (main thread reads).
head: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

/// Called by the signal handler (single producer).
/// Returns `true` if enqueued successfully, or `false` if the ring is full.
///
/// Note: the upstream version also wakes the main-thread event loop via
/// `VirtualMachine.getMainThreadVM().?.eventLoop().wakeup()`. That hook
/// re-lands alongside the JS event loop in Phase 12.2; until then the ring
/// buffer enqueue itself is the only thing carrying state forward.
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

    return true;
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

/// Plain-data carrier emitted by `drain()` once it re-lands. The upstream
/// extern `Bun__onSignalForJS(number: i32, globalObject: *JSGlobalObject)`
/// is the runtime callback; the data struct itself has no JSC dependencies.
pub const PosixSignalTask = struct {
    number: u8,
};

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

comptime {
    _ = home_rt;
}
