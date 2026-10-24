//! Owned persistent backing for capture_allocation policy. Caller serializes
//! access and fixes the provider for the lifetime of this non-copyable owner.
//! Mapping is NOT CPU access admission: the camera still owns coherency fences.
const std = @import("std");
pub const policy = @import("capture_allocation.zig");
pub const ImportBuffer = struct { fd: c_int, offset: u64 = 0 };
pub const Identity = struct { device: u64, inode: u64, bytes: u64 };
pub const Resource = struct {
    fd: c_int = -1,
    read: ?[]u8 = null,
    write: ?[]u8 = null,
    ram: ?[]u8 = null,
    identity: ?Identity = null,
    offset: u64 = 0,
    read_offset: usize = 0,
};
pub const View = struct { fd: c_int, bytes: []u8, frame_bytes: usize, offset: u64 = 0 };

/// Explicit synthetic backing, not a physical address or DMA emulation.
pub const Ram = struct {
    allocator: std.mem.Allocator,
    pub fn allocationBytes(_: *const Ram, bytes: u64) !u64 {
        if (bytes == 0) return error.InvalidLayout;
        return bytes;
    }
    pub fn prepare(self: *Ram, resource: *Resource, bytes: usize) !void {
        const allocation = try self.allocator.alloc(u8, bytes);
        resource.ram = allocation;
        resource.read = allocation;
    }
    pub fn writable(_: *Ram, resource: *Resource) ![]u8 {
        return resource.ram orelse error.InvalidResource;
    }
    pub fn destroy(self: *Ram, resource: *Resource) !void {
        if (resource.ram) |bytes| self.allocator.free(bytes);
        resource.* = .{};
    }
    pub fn close(_: *Ram) !void {}
};

pub const linux_available = @import("builtin").os.tag == .linux;
pub const host_toolchain_supported = @import("builtin").zig_version.major == 0 and @import("builtin").zig_version.minor == 15;
// Native C translation is deliberately available only via capture_host.zig.
// New Zig compilers parse even unused imports containing removed builtins.

/// Fixed-capacity provider owner. All backing is prepared before publication.
/// Idle eviction is explicit by default; checkoutEvicting retires idle entries
/// only when admission is full. Failed cleanup keeps its retirement and budget.
pub fn Owner(comptime capacity: usize, comptime Provider: type) type {
    return struct {
        const Self = @This();
        pub const Cache = policy.Cache(capacity);
        provider: Provider,
        cache: Cache,
        resources: [capacity][policy.max_streams][policy.max_buffers]Resource = @splat(@splat(@splat(.{}))),
        retirements: [capacity]?policy.Retirement = @splat(null),
        cleanup_errors: u64 = 0,
        allocations: u64 = 0,
        writable_maps: u64 = 0,
        pub fn init(provider: Provider, max_bytes: usize, max_entries: usize) !Self {
            return .{ .provider = provider, .cache = try Cache.init(max_bytes, max_entries) };
        }
        pub fn checkout(self: *Self, requested: *const policy.Layout) !Cache.Checkout {
            return self.checkoutImpl(requested, false);
        }
        pub fn checkoutConcurrent(self: *Self, requested: *const policy.Layout) !Cache.Checkout {
            return self.checkoutImpl(requested, true);
        }
        pub fn checkoutExisting(self: *Self, requested: *const policy.Layout) !Cache.Checkout {
            return self.cache.checkoutExisting(requested);
        }
        /// Provider-specific descriptor preflight precedes reservation; duplicate
        /// ownership and mapping start only after full-byte admission. The caller
        /// keeps input fds stable and inactive until this synchronous call ends.
        pub fn importBuffers(self: *Self, requested: *const policy.Layout, inputs: []const ImportBuffer) !void {
            const layout = try requested.normalized();
            var expected: usize = 0;
            for (layout.streams[0..layout.stream_count]) |stream| expected += stream.buffer_count;
            if (inputs.len != expected) return error.InvalidResource;
            var sources: [policy.max_streams * policy.max_buffers]Provider.Source = undefined;
            var at: usize = 0;
            var charge: usize = 0;
            for (layout.streams[0..layout.stream_count]) |stream| {
                if (stream.allocation_bytes != stream.frame_bytes) return error.InvalidLayout;
                for (0..stream.buffer_count) |_| {
                    const source = try self.provider.describe(inputs[at], stream.frame_bytes);
                    const key = source.identity;
                    // Per-frame coherency gates cannot safely synchronize two
                    // distinct frames backed by the same underlying DMA object.
                    for (sources[0..at]) |other| if (sameIdentity(key, other.identity)) return error.AliasedResource;
                    for (&self.resources) |*resources| for (resources) |*buffers| for (buffers) |*resource| {
                        if (resource.identity) |other| if (sameIdentity(key, other)) return error.AliasedResource;
                    };
                    charge = std.math.add(usize, charge, std.math.cast(usize, key.bytes) orelse return error.SizeOverflow) catch return error.SizeOverflow;
                    sources[at] = source;
                    at += 1;
                }
            }
            const result = try self.cache.prepareNew(&layout, charge);
            self.prepareImported(result, &layout, sources[0..at]) catch |failure| {
                self.retirements[result.slot] = try self.cache.failPreparation(result.claim);
                try self.cleanup(result.slot);
                return failure;
            };
            try self.cache.publish(result.claim);
            try self.cache.release(result.claim);
        }
        fn sameIdentity(a: Identity, b: Identity) bool {
            return a.device == b.device and a.inode == b.inode;
        }
        fn prepareImported(self: *Self, result: Cache.Checkout, layout: *const policy.Layout, sources: []const Provider.Source) !void {
            var at: usize = 0;
            for (layout.streams[0..layout.stream_count], 0..) |stream, s| for (0..stream.buffer_count) |b| {
                try self.provider.importPrepare(&self.resources[result.slot][s][b], sources[at]);
                self.allocations +|= 1;
                at += 1;
            };
        }
        fn checkoutImpl(self: *Self, requested: *const policy.Layout, concurrent: bool) !Cache.Checkout {
            var layout = try requested.normalized();
            for (layout.streams[0..layout.stream_count]) |*stream| stream.allocation_bytes = try self.provider.allocationBytes(stream.frame_bytes);
            const result = if (concurrent) try self.cache.checkoutConcurrent(&layout) else try self.cache.checkout(&layout);
            if (!result.fresh) return result;
            self.prepare(result, &layout) catch |failure| {
                self.retirements[result.slot] = try self.cache.failPreparation(result.claim);
                // Preserve a failed cleanup owner, and report that cleanup failure
                // rather than silently replacing it with the allocation error.
                try self.cleanup(result.slot);
                return failure;
            };
            try self.cache.publish(result.claim);
            return result;
        }
        fn prepare(self: *Self, result: Cache.Checkout, layout: *const policy.Layout) !void {
            for (layout.streams[0..layout.stream_count], 0..) |stream, s| {
                for (0..stream.buffer_count) |b| {
                    try self.provider.prepare(&self.resources[result.slot][s][b], @intCast(stream.allocation_bytes));
                    self.allocations +|= 1;
                }
            }
        }
        pub fn checkoutEvicting(self: *Self, layout: *const policy.Layout) !Cache.Checkout {
            return self.checkoutEvictingImpl(layout, false);
        }
        pub fn checkoutEvictingConcurrent(self: *Self, layout: *const policy.Layout) !Cache.Checkout {
            return self.checkoutEvictingImpl(layout, true);
        }
        fn checkoutEvictingImpl(self: *Self, layout: *const policy.Layout, concurrent: bool) !Cache.Checkout {
            while (true) {
                return self.checkoutImpl(layout, concurrent) catch |failure| {
                    if (failure != error.BufferFull) return failure;
                    var pending: ?u32 = null;
                    for (self.retirements, 0..) |retirement, i| if (retirement != null) {
                        pending = @intCast(i);
                        break;
                    };
                    if (pending) |index| {
                        try self.cleanup(index);
                        continue;
                    }
                    const index = self.cache.oldestIdle() orelse return failure;
                    self.retirements[index] = try self.cache.retireIdle(index);
                    try self.cleanup(index);
                    continue;
                };
            }
        }
        pub fn view(self: *Self, claim: policy.Claim, stream: u32, buffer: u32, writable: bool) !View {
            const index = try self.cache.slot(claim);
            const entry = &self.cache.entries[index].?;
            if (entry.state != .borrowed) return error.InvalidState;
            if (stream >= entry.layout.stream_count or buffer >= entry.layout.streams[stream].buffer_count) return error.InvalidResource;
            const resource = &self.resources[index][stream][buffer];
            const had_write = resource.write != null;
            const memory = if (writable) try self.provider.writable(resource) else resource.read orelse return error.InvalidResource;
            if (writable and !had_write and resource.write != null) self.writable_maps +|= 1;
            if (resource.read_offset > memory.len) return error.InvalidResource;
            return .{ .fd = resource.fd, .bytes = memory[resource.read_offset..], .frame_bytes = @intCast(entry.layout.streams[stream].frame_bytes), .offset = resource.offset };
        }
        pub fn release(self: *Self, claim: policy.Claim) !void {
            try self.cache.release(claim);
        }
        /// No I/O. All SDK/frame users must be joined first. Failed-fence backing
        /// stays unavailable and charged until trim/close/full-admission cleanup.
        pub fn discard(self: *Self, claim: policy.Claim) !void {
            const index = try self.cache.slot(claim);
            self.retirements[index] = try self.cache.discard(claim);
        }
        fn cleanup(self: *Self, index: u32) !void {
            const retirement = self.retirements[index] orelse return error.InvalidState;
            var failed = false;
            for (&self.resources[index]) |*stream| for (stream) |*resource| {
                self.provider.destroy(resource) catch {
                    self.cleanup_errors +|= 1;
                    failed = true;
                };
            };
            if (failed) return error.CleanupPending;
            try self.cache.finishRetirement(retirement);
            self.retirements[index] = null;
        }
        /// May trim idle entries while other layouts are borrowed. Retry also
        /// joins partially failed preparation/cleanup; active borrowers stay live.
        pub fn trim(self: *Self) !void {
            var failed = false;
            self.reapPending() catch {
                failed = true;
            };
            while (self.cache.oldestIdle()) |index| {
                self.retirements[index] = try self.cache.retireIdle(index);
                self.cleanup(index) catch {
                    failed = true;
                };
            }
            if (failed) return error.CleanupPending;
        }
        /// Retry owned retirement without evicting idle source/rollback modes.
        /// Factory preparation can reclaim failed target backing independently
        /// from already provisioned profiles needed by another camera/job.
        pub fn reapPending(self: *Self) !void {
            var failed = false;
            for (self.retirements, 0..) |retirement, i| if (retirement != null) {
                self.cleanup(@intCast(i)) catch {
                    failed = true;
                };
            };
            if (failed) return error.CleanupPending;
        }
        /// Owner is retained on failure. Caller must first retire all SDK users
        /// and asynchronous open/mode pins, then retry. Never copy a live owner.
        pub fn close(self: *Self) !void {
            if (self.cache.owners.used != 0) return error.Busy;
            try self.trim();
            try self.provider.close();
        }
    };
}

fn fixture() !policy.Layout {
    return policy.Layout.init("synthetic", &.{try policy.Stream.init(8, 4, 32, 128, 2, "BGR888", 0)});
}
fn ramAllocationFailures(allocator: std.mem.Allocator) !void {
    var owner = try Owner(2, Ram).init(.{ .allocator = allocator }, 1024, 2);
    defer owner.close() catch unreachable;
    const layout = try fixture();
    const loan = try owner.checkout(&layout);
    const buffer = try owner.view(loan.claim, 0, 0, true);
    @memset(buffer.bytes, 0x63);
    try owner.release(loan.claim);
    for (0..1000) |_| {
        const reused = try owner.checkout(&layout);
        const read = try owner.view(reused.claim, 0, 0, false);
        try std.testing.expect(read.bytes.ptr == buffer.bytes.ptr);
        try std.testing.expectEqual(@as(u8, 0x63), read.bytes[0]);
        try owner.release(reused.claim);
    }
    try std.testing.expectEqual(@as(u64, 2), owner.allocations);
    try std.testing.expectEqual(@as(u64, 1000), owner.cache.reuses);
}
test "RAM provider owns reused backing and retires every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ramAllocationFailures, .{});
}
test "bounded host eviction preserves active layouts and invalidates stale views" {
    const t = std.testing;
    var owner = try Owner(2, Ram).init(.{ .allocator = t.allocator }, 512, 2);
    defer owner.close() catch unreachable;
    const a = try fixture();
    var b = a;
    b.camera[0] = 'B';
    var c = a;
    c.camera[0] = 'C';
    const first = try owner.checkout(&a);
    const second = try owner.checkout(&b);
    try t.expectError(error.Busy, owner.close());
    try t.expectError(error.BufferFull, owner.checkoutEvicting(&c));
    try owner.release(first.claim);
    const third = try owner.checkoutEvicting(&c);
    try t.expect(third.fresh);
    try t.expectError(error.StaleClaim, owner.view(first.claim, 0, 0, false));
    try t.expectError(error.LayoutBusy, owner.checkout(&b));
    try t.expectError(error.InvalidResource, owner.view(second.claim, 1, 0, false));
    try owner.release(third.claim);
    try owner.trim();
    try t.expectEqual(@as(usize, 256), owner.cache.reservations.used);
    try owner.release(second.claim);
}
test "discarded coherency backing cannot be reused and cleanup precedes a bounded replacement" {
    const t = std.testing;
    const layout = try fixture();
    var owner = try Owner(1, Ram).init(.{ .allocator = t.allocator }, 256, 1);
    defer owner.close() catch unreachable;
    const first = try owner.checkout(&layout);
    try owner.discard(first.claim);
    try t.expectEqual(@as(usize, 256), owner.cache.reservations.used);
    try t.expectEqual(policy.State.retiring, owner.cache.entries[0].?.state);
    try t.expectError(error.StaleClaim, owner.view(first.claim, 0, 0, false));
    try t.expectError(error.StaleClaim, owner.release(first.claim));
    const replacement = try owner.checkoutEvictingConcurrent(&layout);
    try t.expect(replacement.fresh);
    try t.expectEqual(@as(u64, 4), owner.allocations);
    try t.expectEqual(@as(u64, 1), owner.cache.retired);
    try t.expectEqual(@as(u64, 0), owner.cache.reuses);
    try owner.release(replacement.claim);
}

const ImportFixture = struct {
    allocator: std.mem.Allocator,
    prepared: usize = 0,
    fail_at: usize = 0,
    cleanup_failures: usize = 0,
    pub const Source = struct { input: ImportBuffer, identity: Identity, frame_bytes: u64 };
    pub fn describe(_: *@This(), input: ImportBuffer, bytes: u64) !Source {
        if (input.fd <= 0 or input.offset + bytes > 1024) return error.InvalidResource;
        return .{ .input = input, .identity = .{ .device = 7, .inode = @intCast(input.fd), .bytes = 1024 }, .frame_bytes = bytes };
    }
    pub fn importPrepare(self: *@This(), resource: *Resource, source: Source) !void {
        resource.ram = try self.allocator.alloc(u8, @intCast(source.frame_bytes + source.input.offset));
        resource.read = resource.ram;
        resource.read_offset = @intCast(source.input.offset);
        resource.offset = source.input.offset;
        resource.identity = source.identity;
        resource.fd = source.input.fd + 100;
        self.prepared += 1;
        if (self.prepared == self.fail_at) return error.PreparationFailed;
    }
    pub fn writable(_: *@This(), resource: *Resource) ![]u8 {
        return resource.ram orelse error.InvalidResource;
    }
    pub fn destroy(self: *@This(), resource: *Resource) !void {
        if (resource.ram) |bytes| {
            if (self.cleanup_failures != 0) {
                self.cleanup_failures -= 1;
                return error.CleanupPending;
            }
            self.allocator.free(bytes);
        }
        resource.* = .{};
    }
    pub fn close(_: *@This()) !void {}
};

test "imports charge full objects before preparation and reject aliases across retained entries" {
    const t = std.testing;
    const layout = try fixture();
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator }, 2048, 2);
    defer owner.close() catch unreachable;
    try t.expectError(error.LayoutUnavailable, owner.checkoutExisting(&layout));
    const inputs = [_]ImportBuffer{ .{ .fd = 1, .offset = 7 }, .{ .fd = 2 } };
    try t.expectError(error.AliasedResource, owner.importBuffers(&layout, &.{ inputs[0], inputs[0] }));
    try t.expectEqual(@as(usize, 0), owner.provider.prepared);
    try owner.importBuffers(&layout, &inputs);
    try t.expectEqual(@as(usize, 2048), owner.cache.reservations.used);
    try t.expectError(error.AliasedResource, owner.importBuffers(&layout, &inputs));
    try t.expectError(error.BufferFull, owner.importBuffers(&layout, &.{ .{ .fd = 3 }, .{ .fd = 4 } }));
    try t.expectEqual(@as(usize, 2), owner.provider.prepared);
    const first = try owner.checkoutExisting(&layout);
    const view = try owner.view(first.claim, 0, 0, true);
    try t.expectEqual(@as(usize, 128), view.bytes.len);
    try t.expectEqual(@as(u64, 7), view.offset);
    try t.expectEqual(@as(c_int, 101), view.fd);
    try t.expectError(error.LayoutBusy, owner.checkoutExisting(&layout));
    try owner.release(first.claim);
    try owner.trim();
    try t.expectEqual(@as(usize, 0), owner.cache.reservations.used);
    try t.expectError(error.LayoutUnavailable, owner.checkoutExisting(&layout));
}

test "independent imported sets permit overlapping identical layouts without sharing a loan" {
    const t = std.testing;
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator }, 4096, 2);
    defer owner.close() catch unreachable;
    const layout = try fixture();
    try owner.importBuffers(&layout, &.{ .{ .fd = 1 }, .{ .fd = 2 } });
    try owner.importBuffers(&layout, &.{ .{ .fd = 3 }, .{ .fd = 4 } });
    const first = try owner.checkoutExisting(&layout);
    const second = try owner.checkoutExisting(&layout);
    try t.expect(first.slot != second.slot);
    try t.expectError(error.LayoutBusy, owner.checkoutExisting(&layout));
    try t.expectError(error.Busy, owner.close());
    try owner.discard(first.claim);
    try t.expectEqual(@as(usize, 4096), owner.cache.reservations.used);
    try t.expectError(error.StaleClaim, owner.view(first.claim, 0, 0, false));
    try owner.trim();
    try t.expectEqual(@as(usize, 2048), owner.cache.reservations.used);
    try owner.release(second.claim);
}

test "partial import cleanup retains original admission and alias protection until retry" {
    const t = std.testing;
    var owner = try Owner(1, ImportFixture).init(.{ .allocator = t.allocator, .fail_at = 2, .cleanup_failures = 1 }, 2048, 1);
    defer owner.close() catch unreachable;
    const layout = try fixture();
    try t.expectError(error.CleanupPending, owner.importBuffers(&layout, &.{ .{ .fd = 1 }, .{ .fd = 2 } }));
    try t.expectEqual(@as(usize, 2048), owner.cache.reservations.used);
    try t.expectEqual(policy.State.retiring, owner.cache.entries[0].?.state);
    try t.expectError(error.AliasedResource, owner.importBuffers(&layout, &.{ .{ .fd = 1 }, .{ .fd = 3 } }));
    try t.expectError(error.LayoutBusy, owner.checkoutExisting(&layout));
    try owner.trim();
    try t.expectEqual(@as(usize, 0), owner.cache.reservations.used);
    try owner.importBuffers(&layout, &.{ .{ .fd = 1 }, .{ .fd = 2 } });
}

fn importAllocationFailures(allocator: std.mem.Allocator) !void {
    var owner = try Owner(1, ImportFixture).init(.{ .allocator = allocator }, 2048, 1);
    defer owner.close() catch unreachable;
    const layout = try fixture();
    try owner.importBuffers(&layout, &.{ .{ .fd = 1, .offset = 7 }, .{ .fd = 2 } });
}
test "every imported allocation failure retires partially owned resources" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, importAllocationFailures, .{});
}

test "pending-only cleanup preserves an idle rollback profile and its storage" {
    const t = std.testing;
    var owner = try Owner(2, Ram).init(.{ .allocator = t.allocator }, 512, 2);
    defer owner.close() catch unreachable;
    const target = try fixture();
    var source = target;
    source.camera[0] = 'S';
    const failed = try owner.checkout(&target);
    const previous = try owner.checkout(&source);
    const memory = try owner.view(previous.claim, 0, 0, true);
    @memset(memory.bytes, 91);
    try owner.discard(failed.claim);
    try owner.release(previous.claim);
    try owner.reapPending();
    try t.expectEqual(@as(usize, 256), owner.cache.reservations.used);
    try t.expectError(error.LayoutUnavailable, owner.checkoutExisting(&target));
    const restored = try owner.checkoutExisting(&source);
    const intact = try owner.view(restored.claim, 0, 0, false);
    try t.expectEqual(memory.bytes.ptr, intact.bytes.ptr);
    for (intact.bytes) |value| try t.expectEqual(@as(u8, 91), value);
    try owner.release(restored.claim);
}
