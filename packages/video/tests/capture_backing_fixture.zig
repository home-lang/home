const std = @import("std");
const backing = @import("backing");
const Heap = backing.LinuxHeap;
const Owner = backing.Owner(2, Heap);
fn run(scenario: u32) !void {
    if (scenario == 12) {
        if (Heap.open(null)) |value| {
            var heap = value;
            try heap.close();
            return error.Mismatch;
        } else |failure| if (failure != error.SystemIo) return failure;
        return;
    }
    const heap = try Heap.open(if (scenario == 0 or scenario >= 10) null else "/dev/dma_heap/zig-camera-test");
    const page = heap.page_size;
    const owner = try std.heap.c_allocator.create(Owner);
    defer std.heap.c_allocator.destroy(owner);
    owner.* = try Owner.init(heap, @intCast(page * 8), 2);
    const layout = try backing.policy.Layout.init("camera", &.{try backing.policy.Stream.init(8, 4, 32, 128, 2, "BGR888", 0)});
    if (scenario == 1 or scenario == 2 or scenario == 3 or scenario == 8) {
        if (owner.checkout(&layout)) |_| return error.Mismatch else |failure| {
            if (failure != (if (scenario == 8) error.CleanupPending else error.SystemIo)) return failure;
        }
        if (scenario == 8) {
            if (owner.cache.empty() or owner.cache.reservations.used != page * 2 or owner.cleanup_errors != 1) return error.Mismatch;
        } else if (!owner.cache.empty()) return error.Mismatch;
        try owner.close();
        return;
    }
    const first = try owner.checkout(&layout);
    const read = try owner.view(first.claim, 0, 0, false);
    if (read.fd < 0 or read.frame_bytes != 128 or read.bytes.len != page or owner.cache.reservations.used != page * 2) return error.Mismatch;
    if (scenario == 6) {
        if (owner.view(first.claim, 0, 0, true)) |_| return error.Mismatch else |failure| {
            if (failure != error.SystemIo) return failure;
        }
    } else {
        const write = try owner.view(first.claim, 0, 0, true);
        if (write.bytes.ptr == read.bytes.ptr) return error.Mismatch;
        // This peer is real memfd RAM, not physical DMA. Camera CPU fences stay
        // outside this provider and are tested at the camera request boundary.
        write.bytes[0] = 0x6a;
        if (read.bytes[0] != 0x6a) return error.Mismatch;
    }
    if (scenario == 9) try owner.discard(first.claim) else try owner.release(first.claim);
    const again = if (scenario == 9) try owner.checkoutConcurrent(&layout) else try owner.checkout(&layout);
    const same = try owner.view(again.claim, 0, 0, false);
    if (scenario == 9) {
        if (!again.fresh or same.bytes.ptr == read.bytes.ptr or owner.allocations != 4 or owner.retirements[first.slot] == null) return error.Mismatch;
    } else if (again.fresh or same.bytes.ptr != read.bytes.ptr or owner.allocations != 2) return error.Mismatch;
    if (scenario == 0) {
        const parallel = try owner.checkoutConcurrent(&layout);
        const other = try owner.view(parallel.claim, 0, 0, false);
        if (!parallel.fresh or other.bytes.ptr == same.bytes.ptr or other.fd == same.fd) return error.Mismatch;
        try owner.release(parallel.claim);
    }
    try owner.release(again.claim);
    if (scenario == 4 or scenario == 5 or scenario == 7) {
        if (owner.close()) |_| return error.Mismatch else |failure| {
            if (failure != (if (scenario == 7) error.SystemIo else error.CleanupPending)) return failure;
        }
        if (scenario != 7 and owner.cache.empty()) return error.Mismatch;
    }
    try owner.close();
    try owner.close();
    if (!owner.cache.empty()) return error.Mismatch;
}
export fn capture_backing_fixture_run(scenario: u32) c_int {
    run(scenario) catch return 1;
    return 0;
}
