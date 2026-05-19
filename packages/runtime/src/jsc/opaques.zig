// Phase 12.2 M1 — central JSC opaque-type aggregator.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M1 (Binding Layer Foundation), this
// file establishes the ~10 core JSC opaque types so downstream Zig files
// can refer to them by name without pulling in per-leaf headers. The
// individual leaves under `src/jsc/` (e.g. `JSGlobalObject.zig`,
// `JSCell.zig`, `JSObject.zig`, `VM.zig`) keep their richer per-file
// stubs; this aggregator re-exports the bare opaque shells in one place.
//
// `JSValue` is the central type. In the canonical Bun upstream
// (`bun/src/jsc/JSValue.zig`) it is `enum(i64)` because JSC encodes
// pointers + immediates into 64 bits. For the M1 scaffold we keep the
// stub-runnable shape (`opaque {}`) and let `bun_jsc.JSValue` re-attach
// the i64 encoding once M2 lands the inline accessors.
//
// Body land in M2–M6 once JSC C++ availability is settled. Until then
// any extern fn that lists these types will fail at link time — that's
// the expected M1 acceptance condition.

const std = @import("std");

/// The central JSC value type. Stub-runnable scaffold; the real encoding
/// (i64 with NaN-boxed pointers + immediates) lands in M2.
pub const JSValue = opaque {};

/// Per-realm global object. Owns the property table, the prototype chain,
/// and most extern-fn entrypoints take `*JSGlobalObject` as the first arg.
pub const JSGlobalObject = opaque {};

/// Base JavaScript object type. Subclassed by every heap-allocated value
/// that exposes properties to JS (Array, Function, Date, RegExp, etc.).
pub const JSObject = opaque {};

/// Legacy C-API alias for `*JSObject`, kept distinct from `*JSObject` so
/// the JSObjectRef.h surface compiles unchanged.
pub const JSObjectRef = opaque {};

/// Legacy C-API alias for `*JSGlobalContextRef`. Real bindings collapse
/// this onto `*JSGlobalObject`; we keep it opaque for M1.
pub const JSContextRef = opaque {};

/// Base class for all GC-allocated values. Carries the type byte that
/// fast-path dispatchers (inline caches, polymorphic ICs) load directly.
pub const JSCell = opaque {};

/// JS string primitive (heap-allocated, distinct from "small strings"
/// which are immediates packed into JSValue).
pub const JSString = opaque {};

/// JavaScript Promise object — thenable with `.then` / `.catch` /
/// `.finally`. The `JSInternalPromise` variant is host-private.
pub const JSPromise = opaque {};

/// The JSC VM instance. Owns the heap, the API lock, the watchdog, and
/// the microtask queue. One `*VM` per isolated runtime.
pub const VM = opaque {};

/// JSC exception cell. Wraps the thrown JSValue plus a captured stack.
pub const Exception = opaque {};

test "all opaques are pointer-sized" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSValue));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSGlobalObject));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSObject));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSObjectRef));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSContextRef));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSCell));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSString));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*JSPromise));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*VM));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(*Exception));
}

test "opaques are non-equal types" {
    // `*JSValue` and `*JSGlobalObject` are pointer-compatible at runtime
    // but distinct at the type level — the compiler refuses implicit
    // coercion between the two, which is what we want for stub safety.
    try std.testing.expect(@TypeOf(@as(*JSValue, undefined)) != @TypeOf(@as(*JSGlobalObject, undefined)));
    try std.testing.expect(@TypeOf(@as(*JSCell, undefined)) != @TypeOf(@as(*JSObject, undefined)));
}
