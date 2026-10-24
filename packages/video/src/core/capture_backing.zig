//! Owned persistent backing for capture_allocation policy. Caller serializes
//! access and fixes the provider for the lifetime of this non-copyable owner.
//! Mapping is NOT CPU access admission: the camera still owns coherency fences.
const std = @import("std");
pub const policy = @import("capture_allocation.zig");
pub const ImportBuffer = struct { fd: c_int, offset: u64 = 0 };
pub const objects = @import("capture_objects.zig");
pub const Identity = objects.Identity;
pub const ImportPlane = objects.Plane;
pub const ImportFrame = objects.Frame;
const FrameObjects = struct {
    plane_count: u8,
    extra: [objects.max_planes - 1]Resource = @splat(.{}),
    planes: [objects.max_planes]objects.Binding = std.mem.zeroes([objects.max_planes]objects.Binding),
};
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
        frames: [capacity][policy.max_streams][policy.max_buffers]?*FrameObjects = @splat(@splat(@splat(null))),
        metadata_allocator: std.mem.Allocator,
        retirements: [capacity]?policy.Retirement = @splat(null),
        cleanup_errors: u64 = 0,
        allocations: u64 = 0,
        writable_maps: u64 = 0,
        pub fn init(provider: Provider, max_bytes: usize, max_entries: usize) !Self {
            const allocator = if (@hasField(Provider, "allocator") and @TypeOf(@field(@as(Provider, undefined), "allocator")) == std.mem.Allocator) provider.allocator else std.heap.page_allocator;
            return initWithAllocator(provider, max_bytes, max_entries, allocator);
        }
        /// Only multi-plane imports allocate metadata; ordinary frames retain
        /// inline single-object storage. Metadata is owned through cleanup retry.
        pub fn initWithAllocator(provider: Provider, max_bytes: usize, max_entries: usize, allocator: std.mem.Allocator) !Self {
            return .{ .provider = provider, .cache = try Cache.init(max_bytes, max_entries), .metadata_allocator = allocator };
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
            const claim = try self.importBuffersBorrowed(requested, inputs);
            try self.cache.release(claim);
        }
        /// Returns the newly prepared loan directly, even if an older matching
        /// profile becomes idle while an asynchronous producer is preparing it.
        pub fn importBuffersBorrowed(self: *Self, requested: *const policy.Layout, inputs: []const ImportBuffer) !policy.Claim {
            const layout = try requested.normalized();
            var expected: usize = 0;
            for (layout.streams[0..layout.stream_count]) |stream| expected += stream.buffer_count;
            if (inputs.len != expected) return error.InvalidResource;
            var frames: [policy.max_streams * policy.max_buffers]ImportFrame = undefined;
            var at: usize = 0;
            for (layout.streams[0..layout.stream_count]) |stream| for (0..stream.buffer_count) |_| {
                frames[at] = try ImportFrame.init(&.{.{ .fd = inputs[at].fd, .offset = inputs[at].offset, .bytes = stream.frame_bytes }});
                at += 1;
            };
            return self.importFramesBorrowed(&layout, frames[0..at]);
        }
        /// Import one to four non-overlapping planes per frame. FD aliases may
        /// share a physical object within one frame; all other frames/entries
        /// must have independent objects. Charge/map each whole object once.
        pub fn importFrames(self: *Self, requested: *const policy.Layout, inputs: []const ImportFrame) !void {
            const claim = try self.importFramesBorrowed(requested, inputs);
            try self.cache.release(claim);
        }
        pub fn importFramesBorrowed(self: *Self, requested: *const policy.Layout, inputs: []const ImportFrame) !policy.Claim {
            const layout = try requested.normalized();
            var expected: usize = 0;
            for (layout.streams[0..layout.stream_count]) |stream| expected += stream.buffer_count;
            if (inputs.len != expected) return error.InvalidResource;
            const Prepared = struct { plan: objects.Plan, sources: [objects.max_planes]Provider.Source };
            var prepared: [policy.max_streams * policy.max_buffers]Prepared = undefined;
            var at: usize = 0;
            var charge: usize = 0;
            for (layout.streams[0..layout.stream_count]) |stream| {
                if (stream.allocation_bytes != stream.frame_bytes) return error.InvalidLayout;
                for (0..stream.buffer_count) |_| {
                    const frame = &inputs[at];
                    if (frame.plane_count == 0 or frame.plane_count > objects.max_planes) return error.InvalidResource;
                    var identities: [objects.max_planes]Identity = undefined;
                    for (frame.planes[0..frame.plane_count], 0..) |plane, p| {
                        try objects.validatePlane(plane);
                        const source = try self.provider.describe(.{ .fd = plane.fd, .offset = plane.offset }, plane.bytes);
                        identities[p] = source.identity;
                    }
                    const plan = try objects.Plan.init(frame, identities[0..frame.plane_count], stream.frame_bytes);
                    for (prepared[0..at]) |*previous| if (plan.aliases(&previous.plan)) return error.AliasedResource;
                    for (plan.objects[0..plan.object_count]) |object| {
                        for (&self.resources, 0..) |*entries, ei| for (entries, 0..) |*buffers, si| for (buffers, 0..) |*resource, bi| {
                            if (resource.identity) |other| if (objects.sameObject(object.identity, other)) return error.AliasedResource;
                            if (self.frames[ei][si][bi]) |frame_objects| for (&frame_objects.extra) |*extra| {
                                if (extra.identity) |other| if (objects.sameObject(object.identity, other)) return error.AliasedResource;
                            };
                        };
                    }
                    charge = std.math.add(usize, charge, plan.charge) catch return error.SizeOverflow;
                    prepared[at].plan = plan;
                    for (plan.objects[0..plan.object_count], 0..) |object, o| {
                        const source = try self.provider.describe(.{ .fd = object.fd, .offset = object.offset }, object.bytes);
                        if (!std.meta.eql(source.identity, object.identity)) return error.InvalidResource;
                        prepared[at].sources[o] = source;
                    }
                    at += 1;
                }
            }
            const result = try self.cache.prepareNew(&layout, charge);
            self.prepareFrames(result, &layout, prepared[0..at]) catch |failure| {
                self.retirements[result.slot] = try self.cache.failPreparation(result.claim);
                try self.cleanup(result.slot);
                return failure;
            };
            try self.cache.publish(result.claim);
            return result.claim;
        }
        fn prepareFrames(self: *Self, result: Cache.Checkout, layout: *const policy.Layout, prepared: anytype) !void {
            var at: usize = 0;
            for (layout.streams[0..layout.stream_count], 0..) |stream, si| for (0..stream.buffer_count) |bi| {
                const item = &prepared[at];
                if (item.plan.plane_count > 1) {
                    const metadata = try self.metadata_allocator.create(FrameObjects);
                    metadata.* = .{ .plane_count = item.plan.plane_count, .planes = item.plan.planes };
                    self.frames[result.slot][si][bi] = metadata;
                }
                for (item.sources[0..item.plan.object_count], 0..) |source, oi| {
                    try self.provider.importPrepare(self.resourceAt(result.slot, si, bi, oi), source);
                    self.allocations +|= 1;
                }
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
        fn checkedBuffer(self: *Self, claim: policy.Claim, stream: u32, buffer: u32) !u32 {
            const index = try self.cache.slot(claim);
            const entry = &self.cache.entries[index].?;
            if (entry.state != .borrowed) return error.InvalidState;
            if (stream >= entry.layout.stream_count or buffer >= entry.layout.streams[stream].buffer_count) return error.InvalidResource;
            return index;
        }
        pub fn planeCount(self: *Self, claim: policy.Claim, stream: u32, buffer: u32) !u8 {
            const index = try self.checkedBuffer(claim, stream, buffer);
            return if (self.frames[index][stream][buffer]) |frame| frame.plane_count else 1;
        }
        pub fn view(self: *Self, claim: policy.Claim, stream: u32, buffer: u32, writable: bool) !View {
            if (try self.planeCount(claim, stream, buffer) != 1) return error.Unsupported;
            return self.viewPlane(claim, stream, buffer, 0, writable);
        }
        pub fn viewPlane(self: *Self, claim: policy.Claim, stream: u32, buffer: u32, plane: u32, writable: bool) !View {
            const index = try self.checkedBuffer(claim, stream, buffer);
            const frame = self.frames[index][stream][buffer];
            if (plane >= (if (frame) |value| value.plane_count else @as(u8, 1))) return error.InvalidResource;
            const primary = &self.resources[index][stream][buffer];
            const imported = primary.identity != null;
            const binding: objects.Binding = if (frame) |value| value.planes[plane] else .{
                .object = 0,
                .offset = primary.offset,
                .bytes = if (imported) (primary.read orelse return error.InvalidResource).len - primary.read_offset else self.cache.entries[index].?.layout.streams[stream].frame_bytes,
            };
            const resource = self.resourceAt(index, stream, buffer, binding.object);
            const had_write = resource.write != null;
            const memory = if (writable) try self.provider.writable(resource) else resource.read orelse return error.InvalidResource;
            if (writable and !had_write and resource.write != null) self.writable_maps +|= 1;
            if (binding.offset < resource.offset) return error.InvalidResource;
            const start = std.math.add(usize, resource.read_offset, std.math.cast(usize, binding.offset - resource.offset) orelse return error.InvalidResource) catch return error.InvalidResource;
            const length = std.math.cast(usize, binding.bytes) orelse return error.InvalidResource;
            if (start > memory.len or length > memory.len - start) return error.InvalidResource;
            // Managed backing retains its historical allocation capacity. Each
            // imported plane exposes only its checked declared window.
            const visible = if (imported) memory[start..][0..length] else memory[start..];
            return .{ .fd = resource.fd, .bytes = visible, .frame_bytes = length, .offset = binding.offset };
        }
        fn resourceAt(self: *Self, slot: usize, stream: usize, buffer: usize, object: usize) *Resource {
            return if (object == 0) &self.resources[slot][stream][buffer] else &self.frames[slot][stream][buffer].?.extra[object - 1];
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
            for (&self.resources[index], 0..) |*stream, si| for (stream, 0..) |*resource, bi| {
                var frame_failed = false;
                self.provider.destroy(resource) catch {
                    self.cleanup_errors +|= 1;
                    frame_failed = true;
                };
                if (self.frames[index][si][bi]) |frame| {
                    for (&frame.extra) |*extra| self.provider.destroy(extra) catch {
                        self.cleanup_errors +|= 1;
                        frame_failed = true;
                    };
                    if (!frame_failed) {
                        self.metadata_allocator.destroy(frame);
                        self.frames[index][si][bi] = null;
                    }
                }
                failed = failed or frame_failed;
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

fn planarFixture() !policy.Layout {
    return policy.Layout.init("planar", &.{try policy.Stream.init(8, 4, 8, 48, 2, "YUV420", 0)});
}
fn planeFrames() ![2]ImportFrame {
    return .{
        try ImportFrame.init(&.{ .{ .fd = 1, .offset = 13, .bytes = 32 }, .{ .fd = 2, .offset = 85, .bytes = 8 }, .{ .fd = 2, .offset = 101, .bytes = 8 } }),
        try ImportFrame.init(&.{ .{ .fd = 3, .offset = 33, .bytes = 32 }, .{ .fd = 4, .offset = 65, .bytes = 8 }, .{ .fd = 5, .offset = 65, .bytes = 8 } }),
    };
}
test "multiple frame objects share one map per physical inode and retain independent plane windows" {
    const t = std.testing;
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator }, 10240, 2);
    defer owner.close() catch unreachable;
    const layout = try planarFixture();
    const frames = try planeFrames();
    try owner.importFrames(&layout, &frames);
    try t.expectEqual(@as(u64, 5), owner.allocations);
    try t.expectEqual(@as(usize, 5120), owner.cache.reservations.used);
    const loan = try owner.checkoutExisting(&layout);
    try t.expectEqual(@as(u8, 3), try owner.planeCount(loan.claim, 0, 0));
    try t.expectError(error.Unsupported, owner.view(loan.claim, 0, 0, true));
    const y = try owner.viewPlane(loan.claim, 0, 0, 0, true);
    const u = try owner.viewPlane(loan.claim, 0, 0, 1, true);
    const v = try owner.viewPlane(loan.claim, 0, 0, 2, true);
    try t.expect(y.fd != u.fd and u.fd == v.fd);
    try t.expectEqual(@as(u64, 85), u.offset);
    try t.expectEqual(@as(u64, 101), v.offset);
    try t.expectEqual(@as(usize, 16), @intFromPtr(v.bytes.ptr) - @intFromPtr(u.bytes.ptr));
    @memset(y.bytes, 31);
    @memset(u.bytes, 63);
    @memset(v.bytes, 95);
    try t.expectEqualSlices(u8, &@as([8]u8, @splat(63)), (try owner.viewPlane(loan.claim, 0, 0, 1, false)).bytes);
    try t.expectEqualSlices(u8, &@as([8]u8, @splat(95)), (try owner.viewPlane(loan.claim, 0, 0, 2, false)).bytes);
    try t.expectError(error.InvalidResource, owner.viewPlane(loan.claim, 0, 0, 3, false));
    try t.expectError(error.Busy, owner.close());
    try owner.release(loan.claim);
    const reused = try owner.checkoutExisting(&layout);
    try t.expectEqual(y.bytes.ptr, (try owner.viewPlane(reused.claim, 0, 0, 0, false)).bytes.ptr);
    try owner.release(reused.claim);
}
test "plane aliases across frames and retained profiles, overlaps and byte budgets reject before preparation" {
    const t = std.testing;
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator }, 10240, 2);
    defer owner.close() catch unreachable;
    const layout = try planarFixture();
    var frames = try planeFrames();
    frames[1].planes[0].fd = 1;
    try t.expectError(error.AliasedResource, owner.importFrames(&layout, &frames));
    try t.expectEqual(@as(usize, 0), owner.provider.prepared);
    frames = try planeFrames();
    frames[0].planes[2].offset = 90;
    try t.expectError(error.OverlappingPlanes, owner.importFrames(&layout, &frames));
    try t.expectEqual(@as(usize, 0), owner.cache.reservations.used);
    frames = try planeFrames();
    try owner.importFrames(&layout, &frames);
    var other = layout;
    other.camera[0] = 'X';
    try t.expectError(error.AliasedResource, owner.importFrames(&other, &frames));
    var small = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator }, 5119, 2);
    defer small.close() catch unreachable;
    try t.expectError(error.PayloadTooLarge, small.importFrames(&layout, &frames));
    try t.expectEqual(@as(usize, 0), small.provider.prepared);
}
test "partial multi-object import cleanup retains the whole charge through retry" {
    const t = std.testing;
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator, .fail_at = 2, .cleanup_failures = 1 }, 10240, 2);
    defer owner.close() catch unreachable;
    const layout = try planarFixture();
    const frames = try planeFrames();
    try t.expectError(error.CleanupPending, owner.importFrames(&layout, &frames));
    try t.expectEqual(@as(usize, 5120), owner.cache.reservations.used);
    try t.expectError(error.LayoutBusy, owner.checkoutExisting(&layout));
    try owner.reapPending();
    try t.expectEqual(@as(usize, 0), owner.cache.reservations.used);
    try owner.importFrames(&layout, &frames);
    const loan = try owner.checkoutExisting(&layout);
    try t.expectEqual(@as(u8, 3), try owner.planeCount(loan.claim, 0, 0));
    try owner.release(loan.claim);
}
fn planeAllocationFailures(allocator: std.mem.Allocator) !void {
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = allocator }, 10240, 2);
    defer owner.close() catch unreachable;
    const layout = try planarFixture();
    const frames = try planeFrames();
    try owner.importFrames(&layout, &frames);
    const loan = try owner.checkoutExisting(&layout);
    _ = try owner.viewPlane(loan.claim, 0, 1, 2, false);
    try owner.release(loan.claim);
}
test "every plane-object allocation failure unwinds all earlier objects" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, planeAllocationFailures, .{});
}

test "factory imports reserve the newly supplied objects when an older matching profile is idle" {
    const t = std.testing;
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator }, 10240, 2);
    defer owner.close() catch unreachable;
    const layout = try planarFixture();
    const old = try planeFrames();
    try owner.importFrames(&layout, &old);
    var fresh = old;
    for (&fresh) |*frame| for (frame.planes[0..frame.plane_count]) |*plane| {
        plane.fd += 10;
    };
    const claim = try owner.importFramesBorrowed(&layout, &fresh);
    const provided = try owner.viewPlane(claim, 0, 0, 0, false);
    try t.expectEqual(@as(c_int, 111), provided.fd);
    try t.expectEqual(@as(usize, 10240), owner.cache.reservations.used);
    try t.expectEqual(@as(usize, 1), owner.cache.owners.used);
    const previous = try owner.checkoutExisting(&layout);
    try t.expectEqual(@as(c_int, 101), (try owner.viewPlane(previous.claim, 0, 0, 0, false)).fd);
    try owner.release(previous.claim);
    try owner.release(claim);
}

test "raw malformed frame records reject before provider arithmetic or preparation" {
    const t = std.testing;
    var owner = try Owner(2, ImportFixture).init(.{ .allocator = t.allocator }, 10240, 2);
    defer owner.close() catch unreachable;
    const layout = try planarFixture();
    var frames = try planeFrames();
    frames[0].planes[0].offset = std.math.maxInt(u64);
    try t.expectError(error.InvalidResource, owner.importFrames(&layout, &frames));
    frames = try planeFrames();
    frames[0].planes[0].bytes = std.math.maxInt(u64);
    try t.expectError(error.InvalidResource, owner.importFrames(&layout, &frames));
    try t.expectEqual(@as(usize, 0), owner.provider.prepared);
}

test "single-plane backing needs no metadata allocation and multi-plane admission unwinds metadata failure" {
    const t = std.testing;
    var metadata = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var managed = try Owner(1, Ram).initWithAllocator(.{ .allocator = t.allocator }, 10240, 1, metadata.allocator());
    defer managed.close() catch unreachable;
    const layout = try fixture();
    const loan = try managed.checkout(&layout);
    try managed.release(loan.claim);
    try managed.trim();
    try t.expect(!metadata.has_induced_failure);

    var imported = try Owner(1, ImportFixture).initWithAllocator(.{ .allocator = t.allocator }, 10240, 1, metadata.allocator());
    defer imported.close() catch unreachable;
    try imported.importBuffers(&layout, &.{ .{ .fd = 21, .offset = 12 }, .{ .fd = 22, .offset = 9 } });
    const flat = try imported.checkoutExisting(&layout);
    const view = try imported.view(flat.claim, 0, 0, false);
    try t.expectEqual(@as(usize, 128), view.bytes.len);
    try t.expectEqual(@as(u64, 12), view.offset);
    try imported.release(flat.claim);
    try imported.trim();
    try t.expect(!metadata.has_induced_failure);
    const prepared = imported.provider.prepared;
    try t.expectError(error.OutOfMemory, imported.importFrames(&try planarFixture(), &try planeFrames()));
    try t.expect(metadata.has_induced_failure);
    try t.expectEqual(prepared, imported.provider.prepared);
    try t.expectEqual(@as(usize, 0), imported.cache.reservations.used);
    try t.expectEqual(@as(usize, 0), imported.cache.owners.used);
}
