// Phase 12.2 M6 — iterator-protocol walker.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M6 (the final scaffold milestone
// before C++ wiring), this file is the central entry point for "I have
// a JS iterable, walk it from Zig" calls. JSC does not expose a single
// C-API entrypoint for the iterator protocol — host code instead drives
// it manually: look up `Symbol.iterator`, call it to get an iterator,
// then call `iterator.next()` in a loop until `{ done: true }`.
//
// The `iterate` helper collapses that boilerplate into a single call:
//
//     jsc.iterator.iterate(ctx, my_iterable, struct {
//         fn cb(v: *JSValue) bool {
//             // …consume `v`. Return `false` to stop early.
//             return true;
//         }
//     }.cb);
//
// The callback is invoked once per yielded element. Returning `false`
// from the callback aborts the walk early (the iterator's `return()`
// hook, if present, is invoked to give the iterable a chance to clean
// up — matching ECMAScript `for-of` early-break semantics). Returning
// `true` continues to the next element.
//
// Implementation under M3 will:
//   1. `GetMethod(iterable, @@iterator)` → iterator factory.
//   2. `Call(factory, iterable, [])` → iterator object.
//   3. Loop:
//      a. `Call(iterator.next, iterator, [])` → `{ value, done }`.
//      b. If `done`, exit loop.
//      c. Invoke `callback(value)`. If callback returns `false`, call
//         `iterator.return()` (best-effort) and exit loop.
//
// All of these compose on the M2 property + M5 call surface, so once
// the C++ engine is alive the body is ~40 lines of plain Zig — no new
// extern fns required.
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSArrayIterator.zig` (the array-fast-path that
//     skips the generic protocol when the iterable is a plain Array)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2940 (`forEach` — the per-
//     element callback wrapper)
//
// The body panics with `TODO(phase-12.2-M3)`; the M6 contract is the
// shape of the surface, not its semantics.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;

/// Callback signature for `iterate`. Receives each yielded JSValue in
/// turn; returning `false` aborts the walk early (and triggers the
/// iterator's `return()` cleanup hook, if any). Returning `true`
/// continues to the next element.
///
/// The callback is a plain `*const fn(JSValue) bool` rather than a
/// closure — JSC's call surface is C-ABI and doesn't carry environment
/// state, so callers that need closure-like behaviour should stash the
/// state in a thread-local or in module-level state before invoking
/// `iterate`.
pub const IterCallback = *const fn (value: *JSValue) bool;

/// Walk the iterable protocol on `iterable_value`, invoking `callback`
/// once per yielded element. Stops on the first `false` return from
/// `callback` (giving the iterable a chance to clean up via its
/// `return()` hook).
///
/// Composes (M3) the M2 property surface (`getProperty(iterable,
/// "@@iterator")`) with the M5 call surface (`callMethod(iter, "next")`
/// in a loop). No new extern fn needed — the body fans out across the
/// existing M1 entries.
///
/// Throws are caught and logged but not propagated — the walk continues
/// past a per-element throw, matching Bun's `forEach` semantics. Hosts
/// that want strict propagation should layer a try/catch around the
/// callback themselves.
pub fn iterate(
    ctx: *JSContextRef,
    iterable_value: *JSValue,
    callback: IterCallback,
) void {
    _ = ctx;
    _ = iterable_value;
    _ = callback;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

test "iterator helpers expose the expected M6 signatures" {
    // Compile-time signature check — body panics until M3 lands the
    // C++ engine; we only assert that the helper exists as a function
    // and has not drifted off the M6 spec.
    try std.testing.expect(@typeInfo(@TypeOf(iterate)) == .@"fn");
    // `IterCallback` is a pointer-to-fn type — verify the shape so a
    // future drift away from `(JSValue) bool` trips a compile error.
    const cb_info = @typeInfo(IterCallback);
    try std.testing.expect(cb_info == .pointer);
    try std.testing.expect(cb_info.pointer.attrs.@"const");
    try std.testing.expect(@typeInfo(cb_info.pointer.child) == .@"fn");
}

test "iterate return type matches the M6 contract" {
    // `iterate` is `void`-returning — it drives the iterator protocol
    // and yields each element to the callback; the only "result" is
    // the side effect of invoking the callback. Early-break is
    // expressed by returning `false` from the callback, not by
    // returning a value from `iterate`.
    const it_info = @typeInfo(@TypeOf(iterate)).@"fn";
    try std.testing.expect(it_info.return_type.? == void);
    // The callback itself returns `bool` — verifies the M6 spec's
    // "return false to stop early" contract.
    const cb_fn = @typeInfo(@typeInfo(IterCallback).pointer.child).@"fn";
    try std.testing.expect(cb_fn.return_type.? == bool);
}
