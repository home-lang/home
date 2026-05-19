// Phase 12.2 M1 — central JSC type-alias aggregator.
//
// Mirrors the C-API surface declared by JSC's public headers
// (`<JavaScriptCore/JSValueRef.h>`) so callers can spell the enums without
// pulling in `javascript_core_c_api.zig` directly. The leaf file
// (`javascript_core_c_api.zig`) still owns the canonical definitions used by
// the legacy C entrypoints; this file is the "new code" pathway referenced
// from `JSC_BRIDGE_SCOPE_2026-05-19.md` (M1 deliverable §3).
//
// These are pure enum scaffolds — no bodies, no extern lookups. The values
// match Apple's `<JSValueRef.h>` ABI so swapping in a real binding is a
// no-op at the call site.

const std = @import("std");

/// JSC C-API type tag returned by `JSValueGetType()`.
/// Source: `<JavaScriptCore/JSValueRef.h>` (`JSType`).
pub const JSType = enum(c_uint) {
    kJSTypeUndefined,
    kJSTypeNull,
    kJSTypeBoolean,
    kJSTypeNumber,
    kJSTypeString,
    kJSTypeObject,
    kJSTypeSymbol,
    kJSTypeBigInt,
};

/// JSC C-API typed-array tag returned by `JSValueGetTypedArrayType()`.
/// Source: `<JavaScriptCore/JSTypedArray.h>` (`JSTypedArrayType`).
pub const JSTypedArrayType = enum(c_uint) {
    kJSTypedArrayTypeInt8Array,
    kJSTypedArrayTypeInt16Array,
    kJSTypedArrayTypeInt32Array,
    kJSTypedArrayTypeUint8Array,
    kJSTypedArrayTypeUint8ClampedArray,
    kJSTypedArrayTypeUint16Array,
    kJSTypedArrayTypeUint32Array,
    kJSTypedArrayTypeFloat32Array,
    kJSTypedArrayTypeFloat64Array,
    kJSTypedArrayTypeArrayBuffer,
    kJSTypedArrayTypeNone,
    kJSTypedArrayTypeBigInt64Array,
    kJSTypedArrayTypeBigUint64Array,
    _,
};

test "JSType tag values match the JSC C ABI" {
    try std.testing.expectEqual(@as(c_uint, 0), @intFromEnum(JSType.kJSTypeUndefined));
    try std.testing.expectEqual(@as(c_uint, 1), @intFromEnum(JSType.kJSTypeNull));
    try std.testing.expectEqual(@as(c_uint, 2), @intFromEnum(JSType.kJSTypeBoolean));
    try std.testing.expectEqual(@as(c_uint, 3), @intFromEnum(JSType.kJSTypeNumber));
    try std.testing.expectEqual(@as(c_uint, 4), @intFromEnum(JSType.kJSTypeString));
    try std.testing.expectEqual(@as(c_uint, 5), @intFromEnum(JSType.kJSTypeObject));
    try std.testing.expectEqual(@as(c_uint, 6), @intFromEnum(JSType.kJSTypeSymbol));
    try std.testing.expectEqual(@as(c_uint, 7), @intFromEnum(JSType.kJSTypeBigInt));
}

test "JSTypedArrayType tag values match the JSC C ABI" {
    try std.testing.expectEqual(@as(c_uint, 0), @intFromEnum(JSTypedArrayType.kJSTypedArrayTypeInt8Array));
    try std.testing.expectEqual(@as(c_uint, 3), @intFromEnum(JSTypedArrayType.kJSTypedArrayTypeUint8Array));
    try std.testing.expectEqual(@as(c_uint, 9), @intFromEnum(JSTypedArrayType.kJSTypedArrayTypeArrayBuffer));
    try std.testing.expectEqual(@as(c_uint, 10), @intFromEnum(JSTypedArrayType.kJSTypedArrayTypeNone));
    try std.testing.expectEqual(@as(c_uint, 12), @intFromEnum(JSTypedArrayType.kJSTypedArrayTypeBigUint64Array));
}
