// Copied from bun/src/runtime/api/JSONCObject.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the JS bridge +
// JSONC parser deps):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSFunction`,
//     `jsc.ZigString`, `bun.JSError` — opaque locals + an `enum(i64)`
//     for `JSValue`. Same pattern as `lolhtml_jsc.zig` / `x509.zig`.
//   - `bun.ArenaAllocator`, `bun.ast.ASTMemoryAllocator`,
//     `bun.interchange.json.parseTSConfig`, `bun.logger.{Log,Source}` —
//     the parser surface itself is parked. The `parse()` body is kept
//     verbatim as a comment so re-attachment is mechanical.

//! `Bun.JSONC.parse(text)` host fn. Wraps the tsconfig JSON-C parser so
//! comments + trailing commas are tolerated.

const std = @import("std");
const home_rt = @import("home_rt");

// JSC stubs — re-attach when the matching home_rt.jsc surface lands.
const JSGlobalObject = @import("home_rt").jsc.JSGlobalObject;
const CallFrame = @import("home_rt").jsc.CallFrame;
pub const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};
pub const JSError = error{JSError};

// Upstream body, parked verbatim — depends on `ASTMemoryAllocator`,
// `logger.{Log,Source}`, `json.parseTSConfig`, plus the JSC bridge methods on
// `JSValue` (`toSlice`, `throwInvalidArguments`, `throwStackOverflow`,
// `throwValue`, `log.toJS`, `parse_result.toJS`). None exist on home_rt yet.
//
//     pub fn create(globalThis: *jsc.JSGlobalObject) jsc.JSValue {
//         const object = JSValue.createEmptyObject(globalThis, 1);
//         object.put(globalThis, ZigString.static("parse"),
//             jsc.JSFunction.create(globalThis, "parse", parse, 1, .{}));
//         return object;
//     }
//
//     pub fn parse(globalThis, callframe) bun.JSError!jsc.JSValue {
//         var arena = bun.ArenaAllocator.init(globalThis.allocator());
//         const allocator = arena.allocator();
//         defer arena.deinit();
//         var ast_memory_allocator = bun.handleOom(allocator.create(ast.ASTMemoryAllocator));
//         var ast_scope = ast_memory_allocator.enter(allocator);
//         defer ast_scope.exit();
//         var log = logger.Log.init(default_allocator);
//         defer log.deinit();
//         const input_value = callframe.argument(0);
//         if (input_value.isEmptyOrUndefinedOrNull())
//             return globalThis.throwInvalidArguments("Expected a string to parse", .{});
//         var input_slice = try input_value.toSlice(globalThis, bun.default_allocator);
//         defer input_slice.deinit();
//         const source = &logger.Source.initPathString("input.jsonc", input_slice.slice());
//         const parse_result = json.parseTSConfig(source, &log, allocator, true) catch |err| {
//             if (err == error.StackOverflow) return globalThis.throwStackOverflow();
//             return globalThis.throwValue(try log.toJS(globalThis, default_allocator, "Failed to parse JSONC"));
//         };
//         return parse_result.toJS(allocator, globalThis) catch |err| switch (err) {
//             error.OutOfMemory => return error.OutOfMemory,
//             error.JSError => return error.JSError,
//             error.JSTerminated => return error.JSTerminated,
//             else => unreachable,
//         };
//     }
pub fn create(globalThis: *JSGlobalObject) JSValue {
    _ = globalThis;
    return .zero;
}

pub fn parse(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalThis;
    _ = callframe;
    return .zero;
}

test "JSONCObject: create returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(JSValue.zero, create(g));
}

test "JSONCObject: parse returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.zero, try parse(g, cf));
}

test "JSONCObject: JSValue tag is ABI-compatible with i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}

comptime {
    _ = &home_rt.upstream_sha;
}
