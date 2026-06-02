// Copied from bun/src/runtime/api/glob.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun")                              → @import("home")
//
// This is an aggressive skeleton port. The upstream file is a thin JSC
// wrapper around `home_rt.glob.BunGlobWalker` (already ported in
// `src/glob/`). All JSC binding entry points (constructor, __scan,
// __scanSync, match) are parked under a JSC stub surface because
// the necessary JSGlobalObject/JSValue/CallFrame/ArgumentsSlice
// substrate is not yet wired through home_rt.
//
// What survives the port:
//   - The `Glob` struct itself (pattern + has_pending_activity).
//   - `incrPendingActivityFlag` / `decrPendingActivityFlag` — pure atomic helpers.
//   - `hasPendingActivity` — exported callconv(.c) accessor used by JSC GC.
//   - `finalize` — frees the pattern via `home_rt.c_allocator`.
//
// JSC stubs (re-attach in Phase 12.2 when the corresponding home_rt.jsc
// surface lands; same convention as `runtime/api/lolhtml_jsc.zig` /
// `runtime/api/bun/x509.zig`):
//   - `JSGlobalObject`, `CallFrame`, `ArgumentsSlice` — opaque.
//   - `JSValue` — `enum(i64)` ABI-match (matches `home_rt/jsc/JSArray.zig`).
//   - `JSError` — single-variant `error{JSError}`.

const std = @import("std");
const home_rt = @import("home");

// JSC stubs — re-attach when home_rt.jsc grows the matching surface.
const JSGlobalObject = @import("home").jsc.JSGlobalObject;
const CallFrame = @import("home").jsc.CallFrame;
const ArgumentsSlice = opaque {};
pub const JSValue = @import("home").jsc.JSValue;
pub const JSError = @import("home").JSError;

const Glob = @This();

pub const js = home_rt.jsc.Codegen.JSGlob;
pub const toJS = js.toJS;
pub const fromJS = js.fromJS;
pub const fromJSDirect = js.fromJSDirect;

pattern: []const u8,
has_pending_activity: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

pub const WalkTask = struct {
    has_pending_activity: ?*std.atomic.Value(usize) = null,

    pub const AsyncGlobWalkTask = home_rt.jsc.ConcurrentPromiseTask(WalkTask);

    pub fn run(this: *WalkTask) void {
        if (this.has_pending_activity) |pending| {
            decrPendingActivityFlag(pending);
        }
    }

    pub fn then(this: *WalkTask, promise: anytype) home_rt.JSTerminated!void {
        _ = this;
        _ = promise;
    }
};

/// GC accessor — wired into JSC's `hasPendingActivity` for the Glob class
/// so the engine knows when the object is safe to finalize.
pub fn hasPendingActivity(this: *Glob) callconv(.c) bool {
    return this.has_pending_activity.load(.seq_cst) > 0;
}

pub fn incrPendingActivityFlag(has_pending_activity: *std.atomic.Value(usize)) void {
    _ = has_pending_activity.fetchAdd(1, .seq_cst);
}

pub fn decrPendingActivityFlag(has_pending_activity: *std.atomic.Value(usize)) void {
    _ = has_pending_activity.fetchSub(1, .seq_cst);
}

/// Frees the heap-owned `pattern` slice. Upstream additionally calls
/// `bun.destroy(this)`; the equivalent home_rt.destroy helper is parked
/// pending the New/Destroy port — callers are responsible for the
/// outer struct lifetime under the skeleton surface.
pub fn finalizePattern(this: *Glob, allocator: std.mem.Allocator) void {
    allocator.free(this.pattern);
}

pub fn finalize(this: *Glob) callconv(.c) void {
    finalizePattern(this, home_rt.default_allocator);
    home_rt.destroy(this);
}

// ---- Parked JSC entry points -----------------------------------------
//
// These mirror the upstream public surface so the eventual JSC re-attach
// is a body-only edit. Each currently throws `error.JSError` to keep the
// surface compile-checked under the stub.

pub fn constructor(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!*Glob {
    _ = globalThis;
    _ = callframe;
    return error.JSError;
}

pub fn @"__scan"(this: *Glob, globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = this;
    _ = globalThis;
    _ = callframe;
    return error.JSError;
}

pub fn @"__scanSync"(this: *Glob, globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = this;
    _ = globalThis;
    _ = callframe;
    return error.JSError;
}

pub fn match(this: *Glob, globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = this;
    _ = globalThis;
    _ = callframe;
    return error.JSError;
}

test "glob: pending-activity atomic round-trips through incr/decr" {
    var g: Glob = .{ .pattern = "**/*.zig" };
    try std.testing.expect(!g.hasPendingActivity());
    incrPendingActivityFlag(&g.has_pending_activity);
    try std.testing.expect(g.hasPendingActivity());
    incrPendingActivityFlag(&g.has_pending_activity);
    try std.testing.expectEqual(@as(usize, 2), g.has_pending_activity.load(.seq_cst));
    decrPendingActivityFlag(&g.has_pending_activity);
    try std.testing.expect(g.hasPendingActivity());
    decrPendingActivityFlag(&g.has_pending_activity);
    try std.testing.expect(!g.hasPendingActivity());
}

test "glob: pattern field stores upstream-style glob expression" {
    const g: Glob = .{ .pattern = "src/**/*.{ts,tsx}" };
    try std.testing.expectEqualStrings("src/**/*.{ts,tsx}", g.pattern);
}

test "glob: finalizePattern frees the owned slice" {
    const dup = try std.testing.allocator.dupe(u8, "*.zig");
    var g: Glob = .{ .pattern = dup };
    g.finalizePattern(std.testing.allocator);
    // If we leaked, the test allocator would fire on teardown.
}

test "glob: JSValue tag size matches i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}
