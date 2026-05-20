// Phase 12.2 M6 — Promise construction + resolution helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M6 (the final scaffold milestone
// before C++ wiring), this file is the central dispatch point for host
// code that needs to bridge an async Zig operation back into JS. JSC's
// C API exposes the underlying machinery as `JSObjectMakeDeferredPromise`
// (returns a tuple of `(promise, resolveFn, rejectFn)`) plus the standard
// `JSObjectCallAsFunction` pathway for invoking the resolve/reject
// closures. The helpers below collapse those into a uniform Zig surface.
//
// The canonical "host emits a promise" flow is:
//
//     const trio = jsc.promise.newPromise(ctx);
//     // …kick off async work; on completion:
//     jsc.promise.resolvePromise(ctx, trio.promise, result_value);
//     // …or on failure:
//     jsc.promise.rejectPromise(ctx, trio.promise, error_value);
//
// The `resolve`/`reject` functions in the returned trio are also kept
// callable directly (they're plain JS functions) — `resolvePromise` /
// `rejectPromise` are the "stash and forget" sugar on top.
//
// `isPromise(v)` is the predicate counterpart — total, never throws,
// returns `false` for non-Promise inputs (including thenables that
// quack but aren't actually JSPromise instances). Use this before
// `await`-style consumption to avoid spurious unwrap of a non-Promise.
//
// `JSObjectMakeDeferredPromise` is now part of `jsc/extern_fns.zig`,
// because Apple's public JavaScriptCore C API exposes it directly. Promise
// status/result inspection and VM microtask draining still require the
// C++ bridge Bun uses internally, so this file only constructs promises
// and invokes retained resolver functions today.
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSPromise.zig` L78 (`create` — deferred ctor)
//   - `~/Code/bun/src/jsc/JSPromise.zig` L142 (`resolve` / `reject`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2615 (`isAnyPromise`)
//
// All bodies panic with `TODO(phase-12.2-M3)`; the M6 contract is the
// shape of the surface, not its semantics.

const std = @import("std");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSPromise = opaques.JSPromise;

/// Result of `newPromise` — the freshly constructed promise plus its
/// two-function resolver pair. All three fields are non-optional
/// `*JSValue` (JSC's `JSObjectMakeDeferredPromise` never returns null
/// on success; allocation failure is a hard abort at the C++ level).
///
/// Layout matches Bun's `JSPromise.Strong` upstream wrapper so call
/// sites that thread the trio through internal state can reuse the same
/// field names without rename churn.
pub const DeferredPromise = struct {
    /// The promise object itself — a `Promise` instance pending until
    /// either `resolve_fn` or `reject_fn` is invoked.
    promise: *JSValue,

    /// One-shot resolve closure. Calling it with a value transitions
    /// the promise to the fulfilled state with that value. Calling it
    /// again after the first transition is a silent no-op.
    resolve_fn: *JSValue,

    /// One-shot reject closure. Calling it with a value transitions
    /// the promise to the rejected state with that value as the
    /// rejection reason. Same once-only semantics as `resolve_fn`.
    reject_fn: *JSValue,
};

/// Construct a fresh deferred Promise. Returns the promise plus its
/// resolver pair. The promise begins life in the pending state and
/// transitions on the first call to either resolver.
///
pub fn newPromise(ctx: *JSContextRef) DeferredPromise {
    var exception: ?*JSValue = null;
    var resolve_fn: ?*JSObject = null;
    var reject_fn: ?*JSObject = null;
    const promise = extern_fns.JSObjectMakeDeferredPromise(ctx, &resolve_fn, &reject_fn, &exception) orelse {
        @panic("JSObjectMakeDeferredPromise returned null");
    };
    if (exception != null or resolve_fn == null or reject_fn == null) {
        @panic("JSObjectMakeDeferredPromise failed to create resolver pair");
    }
    return .{
        .promise = valueFromObject(promise),
        .resolve_fn = valueFromObject(resolve_fn.?),
        .reject_fn = valueFromObject(reject_fn.?),
    };
}

/// Invoke one of the resolver functions returned by `newPromise`.
/// This is the faithful public-C-API operation; callers that need to
/// settle later must retain either `resolve_fn` or `reject_fn`.
pub fn callResolver(ctx: *JSContextRef, resolver_fn: *JSValue, value: *JSValue) void {
    var exception: ?*JSValue = null;
    var arguments = [_]?*JSValue{value};
    _ = extern_fns.JSObjectCallAsFunction(
        ctx,
        objectFromValue(resolver_fn),
        null,
        arguments.len,
        &arguments,
        &exception,
    );
    if (exception != null) {
        @panic("Promise resolver threw");
    }
}

/// Resolve `promise` with `value`. Sugar over invoking the resolver
/// closure returned by `newPromise`; useful when only the promise
/// handle is retained (e.g. it was strong-ref'd into a host-side map
/// keyed by request id).
///
/// Forwards (M3) to `JSObjectCallAsFunction` (extern_fns.zig L84)
/// against the promise's internal resolve hook. Silent no-op if the
/// promise has already settled.
pub fn resolvePromise(ctx: *JSContextRef, promise: *JSValue, value: *JSValue) void {
    _ = ctx;
    _ = promise;
    _ = value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Reject `promise` with `error_value` as the rejection reason. Sugar
/// over invoking the reject closure returned by `newPromise`; same
/// once-only semantics as `resolvePromise`.
///
/// Forwards (M3) to `JSObjectCallAsFunction` (extern_fns.zig L84)
/// against the promise's internal reject hook.
pub fn rejectPromise(ctx: *JSContextRef, promise: *JSValue, error_value: *JSValue) void {
    _ = ctx;
    _ = promise;
    _ = error_value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `IsPromise(v)`. Returns `true` iff `v` is a JSC `Promise` instance
/// (matches the `[[PromiseState]]` internal slot). Never throws.
/// Returns `false` for thenables that aren't actual Promise instances
/// — use this before host-side `await`-style unwrap to avoid mis-
/// dispatching on a generic thenable.
///
/// Forwards (M3) to JSC's internal `isPromise` predicate (declared
/// alongside `JSObjectMakeDeferredPromise` in the M3 wiring batch).
pub fn isPromise(ctx: *JSContextRef, value: *JSValue) bool {
    _ = ctx;
    _ = value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

fn valueFromObject(object: *JSObject) *JSValue {
    return @ptrCast(object);
}

fn objectFromValue(value: *JSValue) *JSObject {
    return @ptrCast(value);
}

test "promise helpers expose the expected M6 signatures" {
    // Compile-time signature check — bodies panic until M3 lands the
    // C++ engine; we only assert that each helper exists as a function
    // and has not drifted off the M6 spec.
    try std.testing.expect(@typeInfo(@TypeOf(newPromise)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(resolvePromise)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(rejectPromise)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(callResolver)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(isPromise)) == .@"fn");
    // `DeferredPromise` is a plain struct carrying the three fields the
    // M6 spec calls out: `promise`, `resolve_fn`, `reject_fn`. Field
    // order is not API-relevant but the names are — downstream call
    // sites destructure via `.promise` / `.resolve_fn` / `.reject_fn`.
    try std.testing.expect(@typeInfo(DeferredPromise) == .@"struct");
    try std.testing.expect(@hasField(DeferredPromise, "promise"));
    try std.testing.expect(@hasField(DeferredPromise, "resolve_fn"));
    try std.testing.expect(@hasField(DeferredPromise, "reject_fn"));
}

test "promise return types match the M6 contract" {
    // `newPromise` returns a `DeferredPromise` struct (by value). All
    // three trio fields are non-optional `*JSValue` — JSC's
    // `JSObjectMakeDeferredPromise` never returns null on success.
    const new_info = @typeInfo(@TypeOf(newPromise)).@"fn";
    try std.testing.expect(new_info.return_type.? == DeferredPromise);
    inline for (.{ "promise", "resolve_fn", "reject_fn" }) |field_name| {
        try std.testing.expect(@FieldType(DeferredPromise, field_name) == *JSValue);
    }
    // `resolvePromise` / `rejectPromise` are `void`-returning (settling
    // a promise is a fire-and-forget side effect).
    const resolve_info = @typeInfo(@TypeOf(resolvePromise)).@"fn";
    const reject_info = @typeInfo(@TypeOf(rejectPromise)).@"fn";
    const call_resolver_info = @typeInfo(@TypeOf(callResolver)).@"fn";
    try std.testing.expect(resolve_info.return_type.? == void);
    try std.testing.expect(reject_info.return_type.? == void);
    try std.testing.expect(call_resolver_info.return_type.? == void);
    // The two settling helpers share an identical signature shape.
    try std.testing.expect(@TypeOf(resolvePromise) == @TypeOf(rejectPromise));
    // `isPromise` is a predicate — returns plain bool, no optional.
    const is_info = @typeInfo(@TypeOf(isPromise)).@"fn";
    try std.testing.expect(is_info.return_type.? == bool);
}

// Silence unused-import lint — `JSPromise` is reserved for the M3
// wiring where the `*JSObjectMakeDeferredPromise` return type is a
// `*JSObject` that downcasts to `*JSPromise` for type-safe slot access.
// Keeping the alias keeps the M3 diff against this file minimal.
comptime {
    _ = JSPromise;
}
