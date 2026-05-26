// Copied from bun/src/jsc/AnyPromise.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, `VM`, `bun.JSTerminated`, `TopExceptionScope`,
// `toJSHostCall`, and the per-promise `unwrap`/`status`/`result`/`isHandled`/
// `setHandled`/`resolve`/`reject`/`rejectAsHandled`/`toJS`/
// `attachAsyncStackFromPromise` bridge methods on `JSPromise`/
// `JSInternalPromise` are not yet wired through `home_rt.jsc`. To preserve
// the public union-type surface that callers spell, we declare a local
// `Promise` opaque (with the method stubs the union dispatches into) and a
// matching `InternalPromise` opaque. Both stubs are intentionally distinct
// from the canonical `home_rt.jsc.JSPromise` / `JSInternalPromise` opaques —
// the upstream methods do not exist there yet, so reusing those types would
// fail to compile.
//
// The full bridge re-attaches in Phase 12.2 once `JSValue.attachAsyncStackFromPromise`,
// `JSPromise.unwrap`, etc. land alongside the rest of the JSC surface.

const std = @import("std");
const home_rt = @import("home_rt");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {};

// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
pub const JSValue = enum(i64) {
    zero = 0,
    _,

    pub fn attachAsyncStackFromPromise(self: JSValue, _: *JSGlobalObject, _: *Promise) void {
        _ = self;
    }
};

// JSC bridge VM stubbed — re-attaches in Phase 12.2.
const VM = opaque {};

/// Phase 12.2 re-attaches the real bridge methods. Until then,
/// `bun.JSTerminated` is `error{JSTerminated}` — matches upstream's alias.
pub const JSTerminated = error{JSTerminated};

/// JSC-bridge stubs for the JSPromise method surface AnyPromise dispatches
/// into. Re-attaches to `home_rt.jsc.JSPromise` in Phase 12.2 once those
/// methods land on the canonical opaque.
pub const Promise = opaque {
    pub const Status = enum(u32) { pending = 0, fulfilled = 1, rejected = 2 };
    pub const UnwrapMode = enum { mark_handled, leave_unhandled };
    pub const Unwrapped = union(enum) {
        pending: void,
        fulfilled: JSValue,
        rejected: JSValue,
        rejected_handled: JSValue,
    };

    pub fn unwrap(_: *Promise, _: *VM, _: UnwrapMode) Unwrapped {
        return .{ .pending = {} };
    }
    pub fn status(_: *Promise) Status {
        return .pending;
    }
    pub fn result(_: *Promise, _: *VM) JSValue {
        return .zero;
    }
    pub fn isHandled(_: *Promise) bool {
        return false;
    }
    pub fn setHandled(_: *Promise) void {}
    pub fn resolve(_: *Promise, _: *JSGlobalObject, _: JSValue) JSTerminated!void {}
    pub fn reject(_: *Promise, _: *JSGlobalObject, _: JSValue) JSTerminated!void {}
    pub fn rejectAsHandled(_: *Promise, _: *JSGlobalObject, _: JSValue) JSTerminated!void {}
    pub fn toJS(_: *Promise) JSValue {
        return .zero;
    }
};

/// JSInternalPromise subclasses JSPromise in C++; both stubs match that
/// shape (every Promise method also resolves through an InternalPromise).
pub const InternalPromise = opaque {
    pub fn unwrap(_: *InternalPromise, _: *VM, _: Promise.UnwrapMode) Promise.Unwrapped {
        return .{ .pending = {} };
    }
    pub fn status(_: *InternalPromise) Promise.Status {
        return .pending;
    }
    pub fn result(_: *InternalPromise, _: *VM) JSValue {
        return .zero;
    }
    pub fn isHandled(_: *InternalPromise) bool {
        return false;
    }
    pub fn setHandled(_: *InternalPromise) void {}
    pub fn resolve(_: *InternalPromise, _: *JSGlobalObject, _: JSValue) JSTerminated!void {}
    pub fn reject(_: *InternalPromise, _: *JSGlobalObject, _: JSValue) JSTerminated!void {}
    pub fn rejectAsHandled(_: *InternalPromise, _: *JSGlobalObject, _: JSValue) JSTerminated!void {}
    pub fn toJS(_: *InternalPromise) JSValue {
        return .zero;
    }
};

pub const AnyPromise = union(enum) {
    normal: *Promise,
    internal: *InternalPromise,

    pub fn unwrap(this: AnyPromise, vm: *VM, mode: Promise.UnwrapMode) Promise.Unwrapped {
        return switch (this) {
            inline else => |promise| promise.unwrap(vm, mode),
        };
    }
    pub fn status(this: AnyPromise) Promise.Status {
        return switch (this) {
            inline else => |promise| promise.status(),
        };
    }
    pub fn result(this: AnyPromise, vm: *VM) JSValue {
        return switch (this) {
            inline else => |promise| promise.result(vm),
        };
    }
    pub fn isHandled(this: AnyPromise) bool {
        return switch (this) {
            inline else => |promise| promise.isHandled(),
        };
    }
    pub fn setHandled(this: AnyPromise, vm: *VM) void {
        _ = vm;
        switch (this) {
            inline else => |promise| promise.setHandled(),
        }
    }

    pub fn resolve(this: AnyPromise, globalThis: *JSGlobalObject, value: JSValue) JSTerminated!void {
        switch (this) {
            inline else => |promise| try promise.resolve(globalThis, value),
        }
    }

    pub fn reject(this: AnyPromise, globalThis: *JSGlobalObject, value: JSValue) JSTerminated!void {
        switch (this) {
            inline else => |promise| try promise.reject(globalThis, value),
        }
    }

    /// Like `reject` but first attaches async stack frames from this promise's
    /// await chain to the error. Use when rejecting from native code at the
    /// top of the event loop. JSInternalPromise subclasses JSPromise in C++,
    /// so both variants are handled.
    pub fn rejectWithAsyncStack(this: AnyPromise, globalThis: *JSGlobalObject, value: JSValue) JSTerminated!void {
        value.attachAsyncStackFromPromise(globalThis, this.asJSPromise());
        try this.reject(globalThis, value);
    }

    /// JSInternalPromise subclasses JSPromise in C++ — this cast is safe for
    /// any C++ function taking JSPromise*.
    pub fn asJSPromise(this: AnyPromise) *Promise {
        return switch (this) {
            .normal => |p| p,
            .internal => |p| @ptrCast(p),
        };
    }

    pub fn rejectAsHandled(this: AnyPromise, globalThis: *JSGlobalObject, value: JSValue) JSTerminated!void {
        switch (this) {
            inline else => |promise| try promise.rejectAsHandled(globalThis, value),
        }
    }

    pub fn asValue(this: AnyPromise) JSValue {
        return switch (this) {
            inline else => |promise| promise.toJS(),
        };
    }

    // Upstream `wrap()` builds a `Wrapper` closure that calls
    // `jsc.toJSHostCall(global, @src(), Fn, args)` from inside a C-callable
    // callback, plus a `TopExceptionScope` around `JSC__AnyPromise__wrap`.
    // Both helpers are parked until the JSC bridge re-attaches — the leaf
    // port keeps a `// TODO(jsc-bridge)` placeholder rather than emit a
    // dangling extern.
    pub fn wrap(_: AnyPromise, _: anytype, comptime _: anytype, _: anytype) JSTerminated!void {}
};

test "AnyPromise.asJSPromise returns normal pointer through" {
    var stub_promise: u8 = 0;
    const p: *Promise = @ptrCast(&stub_promise);
    const any: AnyPromise = .{ .normal = p };
    try std.testing.expect(any.asJSPromise() == p);
}

test "AnyPromise.asJSPromise casts internal to JSPromise pointer" {
    var stub_internal: u8 = 0;
    const ip: *InternalPromise = @ptrCast(&stub_internal);
    const any: AnyPromise = .{ .internal = ip };
    const p = any.asJSPromise();
    try std.testing.expect(@intFromPtr(p) == @intFromPtr(ip));
}

test "AnyPromise.status delegates to .pending stubs" {
    var stub: u8 = 0;
    const any: AnyPromise = .{ .normal = @ptrCast(&stub) };
    try std.testing.expectEqual(Promise.Status.pending, any.status());
}

test "home_rt is wired" {
    try std.testing.expectEqualStrings(
        "fd0b6f1a271fca0b8124b69f230b100f4d636af6",
        home_rt.upstream_sha,
    );
}
