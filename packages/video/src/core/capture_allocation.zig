//! Persistent capture-allocation ownership, without device or allocator calls.
//! The host serializes access, owns the physical resources, and never copies a
//! live Cache. Reserving precedes allocation; retirement completes AFTER every
//! resource has been destroyed. Failed cleanup keeps the claim and budget live.
const std = @import("std");
const admission = @import("owned_admission.zig");
const leases = @import("lease_pool.zig");

pub const max_streams = 3;
pub const max_camera_id = 4096;
pub const max_buffers = 64;
pub const Stream = struct {
    width: u32,
    height: u32,
    stride: u32,
    frame_bytes: u64,
    /// Charge actual backing storage (including page rounding), not just the
    /// visible frame. The host sets this before normalizing the layout.
    allocation_bytes: u64,
    buffer_count: u32,
    modifier: u64,
    format: [32]u8,

    pub fn init(width: u32, height: u32, stride: u32, frame_bytes: u64, buffer_count: u32, format: []const u8, modifier: u64) !Stream {
        if (width == 0 or height == 0 or stride == 0 or frame_bytes == 0 or buffer_count == 0 or buffer_count > max_buffers or
            format.len == 0 or format.len >= 32 or std.mem.indexOfScalar(u8, format, 0) != null) return error.InvalidLayout;
        // This is a physical-allocation description, not a pixel-format parser.
        // Compressed/planar layouts are validated by the importing backend.
        var out: Stream = .{ .width = width, .height = height, .stride = stride, .frame_bytes = frame_bytes, .allocation_bytes = frame_bytes, .buffer_count = buffer_count, .modifier = modifier, .format = @splat(0) };
        @memcpy(out.format[0..format.len], format);
        return out;
    }
    fn normalized(self: Stream) !Stream {
        const end = std.mem.indexOfScalar(u8, &self.format, 0) orelse return error.InvalidLayout;
        if (self.allocation_bytes < self.frame_bytes) return error.InvalidLayout;
        var result = try init(self.width, self.height, self.stride, self.frame_bytes, self.buffer_count, self.format[0..end], self.modifier);
        result.allocation_bytes = self.allocation_bytes;
        return result;
    }
};

/// Owns its identity and all stream descriptors. Equality uses the complete
/// normalized layout, never a caller label, pointer, prefix or hash alone.
pub const Layout = struct {
    camera: [max_camera_id]u8 = @splat(0),
    camera_length: u16 = 0,
    stream_count: u8 = 0,
    streams: [max_streams]Stream = std.mem.zeroes([max_streams]Stream),

    pub fn init(camera: []const u8, streams: []const Stream) !Layout {
        if (camera.len == 0 or camera.len > max_camera_id or std.mem.indexOfScalar(u8, camera, 0) != null or
            streams.len == 0 or streams.len > max_streams) return error.InvalidLayout;
        var out: Layout = .{ .camera_length = @intCast(camera.len), .stream_count = @intCast(streams.len) };
        @memcpy(out.camera[0..camera.len], camera);
        for (streams, 0..) |stream, i| out.streams[i] = try stream.normalized();
        _ = try out.bytes();
        return out;
    }
    pub fn normalized(self: *const Layout) !Layout {
        if (self.camera_length > max_camera_id or self.stream_count > max_streams) return error.InvalidLayout;
        return init(self.camera[0..self.camera_length], self.streams[0..self.stream_count]);
    }
    pub fn bytes(self: *const Layout) !usize {
        if (self.stream_count == 0 or self.stream_count > max_streams) return error.InvalidLayout;
        var total: u64 = 0;
        for (self.streams[0..self.stream_count]) |stream| {
            const stream_bytes = std.math.mul(u64, stream.allocation_bytes, stream.buffer_count) catch return error.SizeOverflow;
            total = std.math.add(u64, total, stream_bytes) catch return error.SizeOverflow;
        }
        return std.math.cast(usize, total) orelse error.SizeOverflow;
    }
    pub fn eql(a: *const Layout, b: *const Layout) bool {
        // Only canonical, successfully initialized layouts are compared here.
        if (a.camera_length != b.camera_length or a.stream_count != b.stream_count or
            !std.mem.eql(u8, a.camera[0..a.camera_length], b.camera[0..b.camera_length])) return false;
        for (a.streams[0..a.stream_count], b.streams[0..b.stream_count]) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        return true;
    }
};

pub const State = enum { preparing, borrowed, idle, retiring };
/// Tickets are scoped to their originating cache, like lease_pool tokens.
pub const Claim = struct { token: u64 };
pub const Retirement = struct { slot: u32, generation: u64 };

/// One exclusive borrower per entry. A camera driver may internally
/// retain many requests/frames; it releases this borrower only after joining all
/// of them. Idle entries stay charged and are evicted explicitly, never during
/// checkout. The host fixes its backing provider for this cache's lifetime.
pub fn Cache(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 64) @compileError("capture cache capacity must be 1..64");
    return struct {
        const Self = @This();
        const Reservations = admission.Registry(capacity);
        const Leases = leases.Pool(capacity, capacity);
        pub const Entry = struct {
            layout: Layout,
            bytes: usize,
            state: State,
            reservation: Reservations.Ticket,
            idle_order: u64 = 0,
        };
        pub const Checkout = struct { claim: Claim, slot: u32, fresh: bool };
        entries: [capacity]?Entry = @splat(null),
        reservations: Reservations,
        owners: Leases = .{},
        order: u64 = 0,
        preparations: u64 = 0,
        reuses: u64 = 0,
        retired: u64 = 0,
        rejected: u64 = 0,

        pub fn init(max_bytes: usize, max_entries: usize) !Self {
            return .{ .reservations = try Reservations.init(max_bytes, max_entries) };
        }
        pub fn checkout(self: *Self, requested: *const Layout) !Checkout {
            return self.checkoutImpl(requested, false);
        }
        /// A disconnected camera can still own exported/retained frames while
        /// its replacement uses the same identity and geometry. Allocate another
        /// bounded entry if no matching idle storage exists; never share backing
        /// with the old borrower. Ordinary checkout retains busy-key rejection.
        pub fn checkoutConcurrent(self: *Self, requested: *const Layout) !Checkout {
            return self.checkoutImpl(requested, true);
        }
        fn checkoutImpl(self: *Self, requested: *const Layout, concurrent: bool) !Checkout {
            errdefer self.rejected +|= 1;
            const layout = try requested.normalized();
            const bytes = try layout.bytes();
            var busy = false;
            for (&self.entries, 0..) |*entry, i| if (entry.*) |*current| {
                if (!current.layout.eql(&layout)) continue;
                if (current.state != .idle) {
                    busy = true;
                    continue;
                }
                const token = try self.owners.acquire(@intCast(i));
                current.state = .borrowed;
                self.reuses +|= 1;
                return .{ .claim = .{ .token = token }, .slot = @intCast(i), .fresh = false };
            };
            if (busy and !concurrent) return error.LayoutBusy;
            const reservation = try self.reservations.reserve(bytes);
            errdefer self.reservations.release(reservation) catch unreachable;
            const token = try self.owners.acquire(@intCast(reservation.slot));
            std.debug.assert(self.entries[reservation.slot] == null);
            self.entries[reservation.slot] = .{ .layout = layout, .bytes = bytes, .state = .preparing, .reservation = reservation };
            self.preparations +|= 1;
            return .{ .claim = .{ .token = token }, .slot = @intCast(reservation.slot), .fresh = true };
        }
        pub fn slot(self: *const Self, claim: Claim) !u32 {
            return self.owners.resource(claim.token) orelse error.StaleClaim;
        }
        fn checked(self: *Self, claim: Claim, state: State) !*Entry {
            const index = try self.slot(claim);
            const entry = &self.entries[index].?;
            if (entry.state != state) return error.InvalidState;
            return entry;
        }
        /// Call only after ALL backing resources/maps have been prepared.
        pub fn publish(self: *Self, claim: Claim) !void {
            const entry = try self.checked(claim, .preparing);
            entry.state = .borrowed;
        }
        /// No physical cleanup: all requests/readers/writers must already be gone.
        pub fn release(self: *Self, claim: Claim) !void {
            const entry = try self.checked(claim, .borrowed);
            const final = try self.owners.release(claim.token);
            std.debug.assert(final);
            self.order +|= 1;
            entry.idle_order = self.order;
            entry.state = .idle;
        }
        /// Failed preparation may own partially allocated resources. Transition
        /// to retirement, retaining its full byte reservation. Retirement uses
        /// the existing allocation generation: cleanup NEVER needs a fresh lease
        /// generation and remains possible after checkout sequence exhaustion.
        pub fn failPreparation(self: *Self, claim: Claim) !Retirement {
            return self.beginRetirement(claim, .preparing);
        }
        /// The host has joined all users, but a coherency/device failure makes
        /// reuse unsafe. Retire backing without physical I/O in a SDK destructor.
        pub fn discard(self: *Self, claim: Claim) !Retirement {
            return self.beginRetirement(claim, .borrowed);
        }
        fn beginRetirement(self: *Self, claim: Claim, state: State) !Retirement {
            const entry = try self.checked(claim, state);
            const index = try self.slot(claim);
            const final = try self.owners.release(claim.token);
            std.debug.assert(final);
            entry.state = .retiring;
            return .{ .slot = index, .generation = entry.reservation.id };
        }
        pub fn oldestIdle(self: *const Self) ?u32 {
            var result: ?u32 = null;
            var oldest: u64 = std.math.maxInt(u64);
            for (self.entries, 0..) |entry, i| if (entry) |current| {
                if (current.state == .idle and (result == null or current.idle_order < oldest)) {
                    oldest = current.idle_order;
                    result = @intCast(i);
                }
            };
            return result;
        }
        pub fn retireIdle(self: *Self, index: u32) !Retirement {
            if (index >= capacity) return error.InvalidSlot;
            const entry = &(self.entries[index] orelse return error.InvalidSlot);
            if (entry.state != .idle) return error.InvalidState;
            self.entries[index].?.state = .retiring;
            return .{ .slot = index, .generation = entry.reservation.id };
        }
        /// Destruction must have succeeded completely before this call. On any
        /// host cleanup failure, keep the claim and retry; never cancel retirement
        /// back to reusable storage whose resources may be partially destroyed.
        pub fn finishRetirement(self: *Self, retirement: Retirement) !void {
            if (retirement.slot >= capacity) return error.StaleRetirement;
            const entry = self.entries[retirement.slot] orelse return error.StaleRetirement;
            if (entry.reservation.id != retirement.generation) return error.StaleRetirement;
            if (entry.state != .retiring) return error.InvalidState;
            try self.reservations.release(entry.reservation);
            self.entries[retirement.slot] = null;
            self.retired +|= 1;
        }
        pub fn empty(self: *const Self) bool {
            return self.reservations.count == 0;
        }
    };
}

fn fixture() !Layout {
    return Layout.init("camera/one", &.{try Stream.init(8, 4, 32, 128, 2, "RGB888", 0)});
}

test "exact owned layouts distinguish camera, stream geometry, format, counts and modifiers" {
    const t = std.testing;
    var name = [_]u8{ 'a', 'b', 'c' };
    var streams = [_]Stream{try Stream.init(8, 4, 32, 128, 2, "RGB888", 0)};
    const layout = try Layout.init(&name, &streams);
    name[0] = 'x';
    streams[0].stride = 64;
    try t.expectEqualStrings("abc", layout.camera[0..layout.camera_length]);
    try t.expectEqual(@as(u32, 32), layout.streams[0].stride);
    const changed_camera = try Layout.init("abd", layout.streams[0..1]);
    try t.expect(!layout.eql(&changed_camera));
    inline for (.{ "width", "height", "stride", "frame_bytes", "allocation_bytes", "buffer_count", "modifier" }) |field| {
        var changed = layout;
        @field(changed.streams[0], field) += 1;
        try t.expect(!layout.eql(&changed));
    }
    var changed = layout;
    changed.streams[0].format[0] = 'B';
    try t.expect(!layout.eql(&changed));
    changed = try Layout.init("abc", &.{ layout.streams[0], layout.streams[0] });
    try t.expect(!layout.eql(&changed));
    // Padding is canonicalized, not used as an accidental cache key.
    changed = layout;
    changed.camera[100] = 99;
    changed.streams[0].format[20] = 99;
    changed.streams[2].stride = 1;
    const canonical = try changed.normalized();
    try t.expect(layout.eql(&canonical));
    try t.expectEqualDeep(layout, canonical);
}

test "reuse requires publication and complete borrower retirement; stale claims cannot consume owners" {
    const t = std.testing;
    const layout = try fixture();
    var cache = try Cache(2).init(512, 2);
    const first = try cache.checkout(&layout);
    try t.expect(first.fresh);
    try t.expectError(error.InvalidState, cache.release(first.claim));
    try t.expectError(error.LayoutBusy, cache.checkout(&layout));
    try cache.publish(first.claim);
    try t.expectError(error.InvalidState, cache.publish(first.claim));
    try t.expectError(error.InvalidState, cache.retireIdle(first.slot));
    try cache.release(first.claim);
    try t.expectError(error.StaleClaim, cache.release(first.claim));
    try t.expect(!cache.empty());
    try t.expectEqual(@as(usize, 256), cache.reservations.used);
    const again = try cache.checkout(&layout);
    try t.expect(!again.fresh);
    try t.expectEqual(first.slot, again.slot);
    try t.expect(again.claim.token != first.claim.token);
    try t.expectError(error.StaleClaim, cache.failPreparation(first.claim));
    try t.expectError(error.InvalidState, cache.failPreparation(again.claim));
    try cache.release(again.claim);
    const retiring = try cache.retireIdle(again.slot);
    try cache.finishRetirement(retiring);
    try t.expectError(error.StaleRetirement, cache.finishRetirement(retiring));
    try t.expect(cache.empty());
    try t.expectEqual(@as(u64, 1), cache.reuses);
    try t.expectEqual(@as(u64, 1), cache.preparations);
}

test "failed preparation and failed physical cleanup retain their entire budget and claim" {
    const t = std.testing;
    const layout = try fixture();
    var different = layout;
    different.camera[0] = 'X';
    var cache = try Cache(2).init(256, 2);
    const first = try cache.checkout(&layout);
    const retiring = try cache.failPreparation(first.claim);
    try t.expectError(error.StaleClaim, cache.release(first.claim));
    try t.expectError(error.StaleClaim, cache.publish(first.claim));
    try t.expectError(error.LayoutBusy, cache.checkout(&layout));
    try t.expectError(error.BufferFull, cache.checkout(&different));
    try t.expect(cache.oldestIdle() == null);
    // A host cleanup error makes NO policy transition. Repeating the inspection
    // proves this exact claim is still responsible for the reserved resources.
    for (0..3) |_| {
        try t.expectEqual(State.retiring, cache.entries[retiring.slot].?.state);
        try t.expectEqual(retiring.generation, cache.entries[retiring.slot].?.reservation.id);
        try t.expectEqual(@as(usize, 256), cache.reservations.used);
        try t.expectEqual(@as(usize, 0), cache.owners.used);
    }
    try cache.finishRetirement(retiring);
    try t.expectError(error.StaleRetirement, cache.finishRetirement(retiring));
    const next = try cache.checkout(&different);
    try t.expect(next.fresh);
    try t.expect(next.claim.token != first.claim.token);
    try t.expectError(error.StaleRetirement, cache.finishRetirement(retiring));
    try cache.finishRetirement(try cache.failPreparation(next.claim));
}

test "idle eviction never retires borrowers and admission never silently evicts storage" {
    const t = std.testing;
    const a = try fixture();
    var b = a;
    b.camera[0] = 'B';
    var c = a;
    c.camera[0] = 'C';
    var cache = try Cache(2).init(512, 2);
    const ca = try cache.checkout(&a);
    const cb = try cache.checkout(&b);
    try cache.publish(ca.claim);
    try cache.publish(cb.claim);
    try cache.release(cb.claim);
    try cache.release(ca.claim);
    try t.expectEqual(cb.slot, cache.oldestIdle().?);
    try t.expectError(error.BufferFull, cache.checkout(&c));
    try t.expectEqual(@as(usize, 512), cache.reservations.used);
    const reused = try cache.checkout(&b);
    try t.expectEqual(ca.slot, cache.oldestIdle().?);
    const evicted = try cache.retireIdle(ca.slot);
    try t.expect(cache.oldestIdle() == null);
    try t.expectError(error.BufferFull, cache.checkout(&c));
    try cache.finishRetirement(evicted);
    const cc = try cache.checkout(&c);
    try t.expectEqual(ca.slot, cc.slot);
    try t.expectError(error.StaleRetirement, cache.finishRetirement(evicted));
    try cache.finishRetirement(try cache.failPreparation(cc.claim));
    try cache.release(reused.claim);
    try cache.finishRetirement(try cache.retireIdle(reused.slot));
    try t.expect(cache.empty());
}

test "layout limits and arithmetic overflow reject before reservation" {
    const t = std.testing;
    const stream = (try fixture()).streams[0];
    try t.expectError(error.InvalidLayout, Layout.init("", &.{stream}));
    try t.expectError(error.InvalidLayout, Layout.init("x\x00y", &.{stream}));
    try t.expectError(error.InvalidLayout, Layout.init("x", &.{}));
    try t.expectError(error.InvalidLayout, Layout.init("x", &.{ stream, stream, stream, stream }));
    try t.expectError(error.InvalidLayout, Stream.init(1, 1, 1, 1, 1, "", 0));
    try t.expectError(error.InvalidLayout, Stream.init(1, 1, 1, 1, 1, "12345678901234567890123456789012", 0));
    var invalid = try fixture();
    invalid.streams[0].frame_bytes = std.math.maxInt(u64);
    invalid.streams[0].allocation_bytes = std.math.maxInt(u64);
    try t.expectError(error.SizeOverflow, invalid.normalized());
    invalid.streams[0].buffer_count = 1;
    invalid.streams[1] = invalid.streams[0];
    invalid.stream_count = 2;
    try t.expectError(error.SizeOverflow, invalid.normalized());
    invalid = try fixture();
    invalid.camera_length = max_camera_id + 1;
    var cache = try Cache(2).init(512, 2);
    try t.expectError(error.InvalidLayout, cache.checkout(&invalid));
    invalid = try fixture();
    invalid.streams[0].frame_bytes = 513;
    invalid.streams[0].allocation_bytes = 513;
    try t.expectError(error.PayloadTooLarge, cache.checkout(&invalid));
    try t.expect(cache.empty());
    try t.expectEqual(@as(usize, 0), cache.owners.used);
    try t.expectError(error.InvalidConfiguration, Cache(2).init(0, 1));
    try t.expectError(error.InvalidConfiguration, Cache(2).init(512, 3));
}

test "generation exhaustion preserves reusable storage and accounting" {
    const t = std.testing;
    const layout = try fixture();
    var cache = try Cache(1).init(256, 1);
    cache.owners.issued = @TypeOf(cache.owners).max_sequence - 1;
    const last = try cache.checkout(&layout);
    try cache.publish(last.claim);
    try cache.release(last.claim);
    try t.expectError(error.SequenceExhausted, cache.checkout(&layout));
    try t.expectEqual(@as(usize, 256), cache.reservations.used);
    try t.expectEqual(State.idle, cache.entries[last.slot].?.state);
    try cache.finishRetirement(try cache.retireIdle(last.slot));
    try t.expect(cache.empty());
    // A fresh admission at exhausted generation rolls its byte reservation back.
    var empty = try Cache(1).init(256, 1);
    empty.owners.issued = @TypeOf(empty.owners).max_sequence;
    try t.expectError(error.SequenceExhausted, empty.checkout(&layout));
    try t.expect(empty.empty());
    try t.expectEqual(@as(usize, 0), empty.reservations.used);
}

/// Independent test host: the policy never allocates or frees these bytes.
/// Injected cleanup errors occur AFTER earlier owners have actually been freed.
const TestHost = struct {
    allocator: std.mem.Allocator,
    policy: Cache(2),
    resources: [2][4]?[]u8 = @splat(@splat(null)),
    allocations: usize = 0,
    frees: usize = 0,
    fn open(self: *TestHost, layout: *const Layout) !Cache(2).Checkout {
        const checkout = try self.policy.checkout(layout);
        if (!checkout.fresh) return checkout;
        errdefer {
            const retirement = self.policy.failPreparation(checkout.claim) catch unreachable;
            self.cleanup(retirement, null) catch unreachable;
        }
        var index: usize = 0;
        for (layout.streams[0..layout.stream_count]) |stream| {
            for (0..stream.buffer_count) |_| {
                if (index == 4) return error.TestResourceLimit;
                self.resources[checkout.slot][index] = try self.allocator.alloc(u8, @intCast(stream.allocation_bytes));
                self.allocations += 1;
                index += 1;
            }
        }
        try self.policy.publish(checkout.claim);
        return checkout;
    }
    fn cleanup(self: *TestHost, retirement: Retirement, fail_before_free: ?usize) !void {
        const entry = self.policy.entries[retirement.slot] orelse return error.StaleRetirement;
        if (entry.state != .retiring or entry.reservation.id != retirement.generation) return error.StaleRetirement;
        var count: usize = 0;
        for (&self.resources[retirement.slot]) |*resource| if (resource.*) |bytes| {
            if (count == fail_before_free) return error.InjectedCleanup;
            self.allocator.free(bytes);
            resource.* = null;
            self.frees += 1;
            count += 1;
        };
        try self.policy.finishRetirement(retirement);
    }
    fn disposeIdle(self: *TestHost) void {
        while (self.policy.oldestIdle()) |slot_index| {
            self.cleanup(self.policy.retireIdle(slot_index) catch unreachable, null) catch unreachable;
        }
        std.debug.assert(self.policy.empty());
    }
};

fn allocationFailureScenario(allocator: std.mem.Allocator) !void {
    var layout = try fixture();
    layout.streams[1] = try Stream.init(2, 2, 8, 16, 2, "BGR888", 0);
    layout.stream_count = 2;
    var host: TestHost = .{ .allocator = allocator, .policy = try Cache(2).init(512, 2) };
    defer host.disposeIdle();
    const first = try host.open(&layout);
    const address = host.resources[first.slot][0].?.ptr;
    @memset(host.resources[first.slot][0].?, 0x51);
    try host.policy.release(first.claim);
    for (0..1000) |_| {
        const again = try host.open(&layout);
        try std.testing.expect(!again.fresh);
        try std.testing.expect(address == host.resources[again.slot][0].?.ptr);
        try std.testing.expectEqual(@as(u8, 0x51), host.resources[again.slot][0].?[0]);
        try host.policy.release(again.claim);
    }
    try std.testing.expectEqual(@as(usize, 4), host.allocations);
    try std.testing.expectEqual(@as(usize, 288), host.policy.reservations.used);
    try std.testing.expectEqual(@as(u64, 1000), host.policy.reuses);
}

test "owned backing survives repeated reuse and every allocation failure frees partial preparation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureScenario, .{});
}

test "partial host cleanup frees earlier owners but blocks reuse and budget release until retry" {
    const t = std.testing;
    const layout = try fixture();
    var other = layout;
    other.camera[0] = 'X';
    var host: TestHost = .{ .allocator = t.allocator, .policy = try Cache(2).init(256, 2) };
    const first = try host.open(&layout);
    try host.policy.release(first.claim);
    const retirement = try host.policy.retireIdle(first.slot);
    try t.expectError(error.InjectedCleanup, host.cleanup(retirement, 1));
    try t.expect(host.resources[first.slot][0] == null);
    try t.expect(host.resources[first.slot][1] != null);
    try t.expectEqual(@as(usize, 1), host.frees);
    try t.expectEqual(@as(usize, 256), host.policy.reservations.used);
    try t.expectError(error.LayoutBusy, host.open(&layout));
    try t.expectError(error.BufferFull, host.open(&other));
    try host.cleanup(retirement, null);
    try t.expectEqual(@as(usize, 2), host.frees);
    const second = try host.open(&other);
    try t.expectError(error.StaleRetirement, host.cleanup(retirement, null));
    try t.expect(host.resources[second.slot][0] != null);
    try host.policy.release(second.claim);
    host.disposeIdle();
    try t.expectEqual(host.allocations, host.frees);
}

test "page rounding is charged independently of frame bytes and admission limits entries" {
    const t = std.testing;
    var layout = try fixture();
    layout.streams[0].allocation_bytes = 4096;
    try t.expectEqual(@as(usize, 8192), try layout.bytes());
    var small = try Cache(2).init(8191, 2);
    try t.expectError(error.PayloadTooLarge, small.checkout(&layout));
    var cache = try Cache(2).init(32768, 1);
    const first = try cache.checkout(&layout);
    try cache.publish(first.claim);
    try cache.release(first.claim);
    var other = layout;
    other.streams[0].stride += 64;
    try t.expectError(error.BufferFull, cache.checkout(&other));
    try cache.finishRetirement(try cache.retireIdle(first.slot));
    layout.streams[0].allocation_bytes = 127;
    try t.expectError(error.InvalidLayout, cache.checkout(&layout));
    try t.expect(cache.empty());
}

test "full identity tails and stream order participate in reuse; malformed descriptors reject safely" {
    const t = std.testing;
    var identity: [max_camera_id]u8 = @splat('x');
    const main = try Stream.init(8, 4, 32, 128, 2, "RGB888", 0);
    const raw = try Stream.init(8, 4, 16, 64, 2, "SRGGB16", 0);
    const a = try Layout.init(&identity, &.{ main, raw });
    identity[max_camera_id - 1] = 'y';
    const b = try Layout.init(&identity, &.{ main, raw });
    try t.expect(!a.eql(&b));
    const swapped = try Layout.init(a.camera[0..a.camera_length], &.{ raw, main });
    try t.expect(!a.eql(&swapped));
    var cache = try Cache(1).init(4096, 1);
    inline for (.{ "width", "height", "stride", "frame_bytes", "buffer_count" }) |field| {
        var bad = a;
        @field(bad.streams[0], field) = 0;
        try t.expectError(error.InvalidLayout, cache.checkout(&bad));
    }
    var bad = a;
    bad.streams[0].buffer_count = max_buffers + 1;
    try t.expectError(error.InvalidLayout, cache.checkout(&bad));
    bad = a;
    bad.streams[0].format = @splat('x');
    try t.expectError(error.InvalidLayout, cache.checkout(&bad));
    bad = a;
    bad.stream_count = max_streams + 1;
    try t.expectError(error.InvalidLayout, cache.checkout(&bad));
    try t.expectError(error.InvalidSlot, cache.retireIdle(0));
    try t.expectError(error.InvalidSlot, cache.retireIdle(1));
    try t.expectError(error.StaleRetirement, cache.finishRetirement(.{ .slot = 1, .generation = 1 }));
    try t.expectError(error.StaleClaim, cache.release(.{ .token = 0 }));
    try t.expect(cache.empty());
}

test "replacement cameras allocate independent bounded storage while old layout borrowers remain live" {
    const t = std.testing;
    const layout = try fixture();
    var cache = try Cache(2).init(512, 2);
    const old = try cache.checkout(&layout);
    try cache.publish(old.claim);
    try t.expectError(error.LayoutBusy, cache.checkout(&layout));
    const replacement = try cache.checkoutConcurrent(&layout);
    try t.expect(replacement.fresh);
    try t.expect(old.slot != replacement.slot);
    try cache.publish(replacement.claim);
    try t.expectError(error.BufferFull, cache.checkoutConcurrent(&layout));
    try cache.release(replacement.claim);
    const next = try cache.checkoutConcurrent(&layout);
    try t.expect(!next.fresh);
    try t.expectEqual(replacement.slot, next.slot);
    try t.expectEqual(old.slot, try cache.slot(old.claim));
    try cache.release(old.claim);
    try cache.release(next.claim);
    try cache.finishRetirement(try cache.retireIdle(old.slot));
    try cache.finishRetirement(try cache.retireIdle(next.slot));
    try t.expect(cache.empty());
}
