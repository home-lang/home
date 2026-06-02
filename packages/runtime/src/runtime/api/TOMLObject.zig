// Copied from bun/src/runtime/api/TOMLObject.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the JS bridge +
// TOML parser deps):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSFunction`,
//     `jsc.ZigString`, `bun.JSError` — opaque locals + an `enum(i64)`
//     for `JSValue`. Same pattern as `lolhtml_jsc.zig` / `x509.zig`.
//   - `bun.ArenaAllocator`, `bun.ast.ASTMemoryAllocator`,
//     `bun.interchange.toml.TOML`, `bun.js_printer.{BufferWriter,BufferPrinter,printJSON}`,
//     `bun.logger.{Log,Source}`, `bun.String.borrowUTF8` — all parser/printer
//     surfaces parked. The `parse()` body is kept verbatim in a comment so
//     re-attachment is mechanical once the TOML/JSON pipeline lands.

//! `Bun.TOML.parse(text)` host fn. Parses TOML and re-emits as JSON so the
//! result lands as a normal JS object via `String.toJSByParseJSON`.

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

// Upstream body, parked verbatim:
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
//         const source = &logger.Source.initPathString("input.toml", input_slice.slice());
//         const parse_result = TOML.parse(source, &log, allocator, false) catch |err| {
//             if (err == error.StackOverflow) return globalThis.throwStackOverflow();
//             return globalThis.throwValue(try log.toJS(globalThis, default_allocator, "Failed to parse toml"));
//         };
//         const buffer_writer = js_printer.BufferWriter.init(allocator);
//         var writer = js_printer.BufferPrinter.init(buffer_writer);
//         _ = js_printer.printJSON(*js_printer.BufferPrinter, &writer, parse_result, source,
//             .{ .mangled_props = null }) catch {
//             return globalThis.throwValue(try log.toJS(globalThis, default_allocator, "Failed to print toml"));
//         };
//         const slice = writer.ctx.buffer.slice();
//         var out = bun.String.borrowUTF8(slice);
//         defer out.deref();
//         return out.toJSByParseJSON(globalThis);
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

test "TOMLObject: create returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(JSValue.zero, create(g));
}

test "TOMLObject: parse returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.zero, try parse(g, cf));
}

test "TOMLObject: JSValue tag is ABI-compatible with i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}

comptime {
    _ = &home_rt.upstream_sha;
}
