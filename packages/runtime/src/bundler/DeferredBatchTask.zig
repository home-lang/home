// Home Runtime — ported from Bun.
// Upstream:  packages/runtime/upstream/src/bundler/DeferredBatchTask.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Renames applied (per packages/runtime/README.md naming convention):
//   - `@import("bun")`              -> `@import("home_rt")`
//   - `bun.Environment`             -> `home_rt.Environment`
//   - `bun.debugAssert` / `bun.assert` -> `home_rt.assert`
//   - `bun.ast.Index` / `bun.ast.Ref` -> `home_rt.ast.Index` / `home_rt.ast.Ref`
//
// **Symbol-dependent surface stubbed**: upstream's `getBundleV2`, `schedule`,
// and `runOnJSThread` reach `bun.BundleV2`, `jsc.Task.init`, and
// `jsc.ConcurrentTask.create` — `BundleV2` (`src/bundler/bundle_v2.zig`,
// thousands of lines) isn't ported, and the JSC `Task` constructor pulls in
// `TaggedPointerUnion` over the full task hierarchy. The three methods are
// armed with `@compileError` so anyone reaching them is reminded to land
// the BundleV2 substrate first. The data layout + `init`/`deinit` are pure
// data and port verbatim, which is what makes the field usable as a member
// of any future `BundleV2`.

const std = @import("std");

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;

/// This task is run once all parse and resolve tasks have been complete
/// and we have deferred onLoad plugins that we need to resume
///
/// It enqueues a task to be run on the JS thread which resolves the promise
/// for every onLoad callback which called `.defer()`.
pub const DeferredBatchTask = @This();

running: if (Environment.isDebug) bool else u0 = if (Environment.isDebug) false else 0,

pub fn init(this: *DeferredBatchTask) void {
    if (comptime Environment.isDebug) home_rt.assert(!this.running);
    this.* = .{
        .running = if (comptime Environment.isDebug) false else 0,
    };
}

pub fn getBundleV2(_: *DeferredBatchTask) noreturn {
    // Upstream returns `*bun.BundleV2` via @fieldParentPtr("drain_defer_task", ..).
    // `BundleV2` isn't ported yet — re-attach when `src/bundler/bundle_v2.zig`
    // lands.
    @compileError("DeferredBatchTask.getBundleV2: requires home_rt.bundler.BundleV2 (Phase 12.x); the substrate isn't ported yet");
}

pub fn schedule(_: *DeferredBatchTask) noreturn {
    @compileError("DeferredBatchTask.schedule: requires home_rt.jsc.Task.init + home_rt.event_loop.ConcurrentTask.create over BundleV2.jsLoopForPlugins (Phase 12.2 + bundle_v2 port)");
}

pub fn deinit(this: *DeferredBatchTask) void {
    if (comptime Environment.isDebug) {
        this.running = false;
    }
}

pub fn runOnJSThread(_: *DeferredBatchTask) noreturn {
    @compileError("DeferredBatchTask.runOnJSThread: requires home_rt.bundler.BundleV2 + plugins.drainDeferred (Phase 12.x)");
}

pub const Ref = home_rt.ast.Ref;

pub const Index = home_rt.ast.Index;

test "DeferredBatchTask: init zeroes the running flag" {
    var t: DeferredBatchTask = .{};
    t.init();
    if (comptime Environment.isDebug) {
        try std.testing.expect(!t.running);
    } else {
        try std.testing.expectEqual(@as(u0, 0), t.running);
    }
}

test "DeferredBatchTask: deinit resets the running flag in Debug" {
    var t: DeferredBatchTask = .{};
    t.init();
    if (comptime Environment.isDebug) {
        t.running = true;
    }
    t.deinit();
    if (comptime Environment.isDebug) {
        try std.testing.expect(!t.running);
    }
}

test "DeferredBatchTask: Ref / Index re-exports resolve" {
    _ = Ref;
    _ = Index;
    try std.testing.expectEqual(@as(Index.Int, 0), Index.runtime.value);
}
