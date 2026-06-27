// Copied from bun/src/runtime/api/UnsafeObject.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//
// Stubs (re-attach in Phase 12.2 when home_rt.jsc grows JSGlobalObject /
// CallFrame / JSFunction / ZigString / ArrayBuffer / heap_breakdown /
// VirtualMachine.arena.dumpStats):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSFunction`,
//     `jsc.ArrayBuffer`, `jsc.ZigString`, `jsc.JSValue`, `bun.JSError`.
//     The hot bodies (`gcAggressionLevel`, `arrayBufferToString`, `dump_mimalloc`)
//     are parked under the same comptime gate used by
//     `home_rt/jsc/JSArray.zig` so the file compiles standalone.
//   - `create()` returns `.zero` instead of building a JS object; the
//     full structure is preserved as a comment for the
//     re-attachment.

//! `Bun.unsafe.*` host fns. Pure-ish helpers (GC aggression, ArrayBuffer →
//! string view, mimalloc heap dump) gated behind a JSC bridge.

const std = @import("std");
const home_rt = @import("home");

// JSC stubs — re-attach when the matching home_rt.jsc surface lands.
const JSGlobalObject = @import("home").jsc.JSGlobalObject;
const CallFrame = @import("home").jsc.CallFrame;
pub const JSValue = @import("home").jsc.JSValue;
pub const JSError = home_rt.JSError;

extern fn dump_zone_malloc_stats() void;

// Upstream `create()` body, parked verbatim under the comptime gate. Calls
// into `jsc.JSValue.createEmptyObject`, `JSFunction.create`, `ZigString.static`
// — none of which exist on home_rt.jsc yet.
//
//     pub fn create(globalThis: *jsc.JSGlobalObject) jsc.JSValue {
//         const object = JSValue.createEmptyObject(globalThis, 3);
//         const fields = comptime .{
//             .gcAggressionLevel = gcAggressionLevel,
//             .arrayBufferToString = arrayBufferToString,
//             .mimallocDump = dump_mimalloc,
//         };
//         inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
//             object.put(
//                 globalThis,
//                 comptime ZigString.static(name),
//                 jsc.JSFunction.create(globalThis, name, @field(fields, name), 1, .{}),
//             );
//         }
//         return object;
//     }
pub fn create(globalThis: *JSGlobalObject) JSValue {
    const jsc = home_rt.jsc;
    const object = JSValue.createEmptyObject(globalThis, 3);
    const fields = comptime .{
        .gcAggressionLevel = gcAggressionLevel,
        .arrayBufferToString = arrayBufferToString,
        .mimallocDump = dump_mimalloc,
    };
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
        object.put(
            globalThis,
            comptime jsc.ZigString.static(name),
            jsc.JSFunction.create(globalThis, name, @field(fields, name), 1, .{}),
        );
    }
    return object;
}

// Upstream body, parked. Reads/writes `globalThis.bunVM().aggressive_garbage_collection`.
// Returns js_undefined (not .zero) so the host-fn contract assert doesn't trip
// if called before the real body lands.
pub fn gcAggressionLevel(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalThis;
    _ = callframe;
    return .js_undefined;
}

// Upstream body, parked. Walks `jsc.ArrayBuffer.fromTypedArray` →
// `ZigString.markUTF16` / `ZigString.toJS`.
pub fn arrayBufferToString(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    const jsc = home_rt.jsc;
    const args = callframe.arguments_old(2).slice();
    if (args.len < 1 or !args[0].isCell() or !args[0].jsType().isTypedArrayOrArrayBuffer()) {
        return globalThis.throwInvalidArguments("Expected an ArrayBuffer", .{});
    }

    const array_buffer = jsc.ArrayBuffer.fromTypedArray(globalThis, args[0]);
    switch (array_buffer.typed_array_type) {
        // 16-bit views are reinterpreted as a UTF-16 string view (`.len` is the
        // element/code-unit count, not bytes).
        .Uint16Array, .Int16Array => {
            const ptr = array_buffer.ptr orelse return jsc.ZigString.init("").toJS(globalThis);
            var zig_str = jsc.ZigString.init("");
            zig_str._unsafe_ptr_do_not_use = @ptrCast(ptr);
            zig_str.len = array_buffer.len;
            zig_str.markUTF16();
            return zig_str.toJS(globalThis);
        },
        else => {
            return jsc.ZigString.init(array_buffer.slice()).toJS(globalThis);
        },
    }
}

// Upstream body, parked. Calls `globalThis.bunVM().arena.dumpStats()` plus
// the macOS-only `dump_zone_malloc_stats()` symbol.
fn dump_mimalloc(globalObject: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalObject;
    _ = callframe;
    return .js_undefined;
}

// `create` now builds a real JSC object (needs a live global), so it's covered
// via the native VM (Bun.unsafe) rather than a pure-Zig unit test.

test "UnsafeObject: JSValue tag is ABI-compatible with i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}

test "UnsafeObject: dump_mimalloc returns js_undefined under the stub" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.js_undefined, try dump_mimalloc(g, cf));
}

comptime {
    _ = &home_rt.upstream_sha;
}
