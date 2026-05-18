// Copied from bun/src/jsc/EventLoopHandle.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `EventLoopHandle` is a non-owning union over the JS event loop and the
// "mini" event loop. Almost every method in the upstream file reaches through
// `this.js.virtual_machine.rareData()`, `this.mini.env.?.map`, etc., which
// can't compile until `VirtualMachine`, `MiniEventLoop`, `Blob.Store`,
// `FilePoll`, `bun.DotEnv.Loader`, and `bun.uws.Loop` all land. We keep:
//   - the `EventLoopKind` discriminant tag enum (pure-Zig),
//   - the `EventLoopHandle` union shape pointing at opaque
//     `EventLoop` / `MiniEventLoop` placeholders,
//   - the `EventLoopTask` / `EventLoopTaskPtr` union shapes (placeholder
//     payloads — the actual `jsc.ConcurrentTask` and
//     `jsc.AnyTaskWithExtraContext` re-land alongside `Task.zig`).
// Method bodies re-attach in Phase 12.2.

const std = @import("std");
const home_rt = @import("home_rt");

/// Discriminant for the `EventLoopHandle` union. Upstream lives in
/// `jsc.EventLoopKind`; we inline it here so this leaf compiles in
/// isolation. The tag values match upstream.
pub const EventLoopKind = enum(u8) {
    js,
    mini,
};

/// Opaque placeholder for the JS event loop (`jsc.EventLoop`). Upstream the
/// real type carries `virtual_machine`, `global`, `signal_handler`, and the
/// uSockets loop — all of which re-attach with `VirtualMachine` in 12.2.
pub const EventLoop = opaque {};

/// Opaque placeholder for the headless mini event loop (`jsc.MiniEventLoop`).
/// Used by build / install commands when no JS runtime is around.
pub const MiniEventLoop = opaque {};

/// Plain-data placeholder for `jsc.ConcurrentTask`. Real one lives in
/// `Task.zig` once it lands; it's a tagged-pointer union, 8 bytes wide.
pub const ConcurrentTaskPlaceholder = extern struct {
    raw: u64 = 0,
};

/// Plain-data placeholder for `jsc.AnyTaskWithExtraContext`.
pub const AnyTaskWithExtraContextPlaceholder = extern struct {
    raw: u64 = 0,
};

/// A non-owning reference to either the JS event loop or the mini event loop.
pub const EventLoopHandle = union(EventLoopKind) {
    js: *EventLoop,
    mini: *MiniEventLoop,

    pub fn cast(this: EventLoopHandle, comptime tag: EventLoopKind) switch (tag) {
        .js => *EventLoop,
        .mini => *MiniEventLoop,
    } {
        return @field(this, @tagName(tag));
    }
};

pub const EventLoopTask = union(EventLoopKind) {
    js: ConcurrentTaskPlaceholder,
    mini: AnyTaskWithExtraContextPlaceholder,

    pub fn init(kind: EventLoopKind) EventLoopTask {
        return switch (kind) {
            .js => .{ .js = .{} },
            .mini => .{ .mini = .{} },
        };
    }
};

pub const EventLoopTaskPtr = union {
    js: *ConcurrentTaskPlaceholder,
    mini: *AnyTaskWithExtraContextPlaceholder,
};

test "EventLoopKind tag values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(EventLoopKind.js));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EventLoopKind.mini));
}

test "EventLoopHandle.cast returns the right pointer" {
    // We can't materialize an opaque on the stack, but a dangling `*EventLoop`
    // is enough to prove the union round-trips and `cast()` dispatches.
    const fake: *EventLoop = @ptrFromInt(0xdead_beef);
    const h: EventLoopHandle = .{ .js = fake };
    try std.testing.expectEqual(fake, h.cast(.js));
}

test "EventLoopTask.init produces the right tag" {
    const t_js = EventLoopTask.init(.js);
    const t_mini = EventLoopTask.init(.mini);
    try std.testing.expect(t_js == .js);
    try std.testing.expect(t_mini == .mini);
}

comptime {
    _ = home_rt;
}
