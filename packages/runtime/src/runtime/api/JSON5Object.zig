// Copied from bun/src/runtime/api/JSON5Object.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the JS bridge +
// JSON5 parser/printer deps):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSFunction`,
//     `jsc.ZigString`, `jsc.JSPropertyIterator`, `jsc.wtf.StringBuilder`,
//     `bun.JSError`, `bun.String`, `bun.StackCheck`, `bun.ArenaAllocator`,
//     `bun.handleOom`, `bun.default_allocator` — opaque locals + an
//     `enum(i64)` for `JSValue`. Same pattern as `TOMLObject.zig` /
//     `JSONCObject.zig` / `lolhtml_jsc.zig`.
//   - `bun.interchange.json5.JSON5Parser`, `bun.ast.Expr` / `Stmt`,
//     `bun.ast.ASTMemoryAllocator`, `bun.logger.{Log, Source}`,
//     `bun.js_lexer.{isIdentifierStart, isIdentifierContinue}` — every
//     parser/printer surface is parked. The upstream parse/stringify
//     bodies are kept verbatim as comments so re-attachment is
//     mechanical when those subsystems land.
//
// The `Space` config tag table, control-character escape table, and
// indentation rules are pure Zig; once the strings/iterators land the
// `Stringifier` body can be re-attached one method at a time.

//! `Bun.JSON5.parse(text)` and `Bun.JSON5.stringify(value, replacer?, space?)`
//! host fns. JSON5 is JSON-with-comments, single-quoted strings, trailing
//! commas, hex literals, and bare identifier keys.

const std = @import("std");
const home_rt = @import("home");

// JSC stubs — re-attach when the matching home_rt.jsc surface lands.
const JSGlobalObject = @import("home").jsc.JSGlobalObject;
const CallFrame = @import("home").jsc.CallFrame;
pub const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};
pub const JSError = error{JSError};

// Upstream `create()` body parked verbatim — depends on
// `JSValue.createEmptyObject`, `ZigString.static`, and
// `jsc.JSFunction.create`. None exist on home_rt yet.
//
//     pub fn create(globalThis: *jsc.JSGlobalObject) jsc.JSValue {
//         const object = JSValue.createEmptyObject(globalThis, 2);
//         object.put(globalThis, ZigString.static("parse"),
//             jsc.JSFunction.create(globalThis, "parse", parse, 1, .{}));
//         object.put(globalThis, ZigString.static("stringify"),
//             jsc.JSFunction.create(globalThis, "stringify", stringify, 3, .{}));
//         return object;
//     }
//
//     pub fn stringify(global, callFrame) bun.JSError!jsc.JSValue {
//         const value, const replacer, const space_value = callFrame.argumentsAsArray(3);
//         value.ensureStillAlive();
//         if (value.isUndefined() or value.isSymbol() or value.isFunction()) return .js_undefined;
//         if (!replacer.isUndefinedOrNull())
//             return global.throw("JSON5.stringify does not support the replacer argument", .{});
//         var stringifier: Stringifier = try .init(global, space_value);
//         defer stringifier.deinit();
//         stringifier.stringifyValue(global, value) catch |err| return switch (err) {
//             error.OutOfMemory, error.JSError, error.JSTerminated => |js_err| js_err,
//             error.StackOverflow => global.throwStackOverflow(),
//         };
//         return stringifier.builder.toString(global);
//     }
//
//     pub fn parse(global, callFrame) bun.JSError!jsc.JSValue {
//         var arena: bun.ArenaAllocator = .init(bun.default_allocator);
//         defer arena.deinit();
//         const allocator = arena.allocator();
//         var ast_memory_allocator = bun.handleOom(allocator.create(ast.ASTMemoryAllocator));
//         var ast_scope = ast_memory_allocator.enter(allocator);
//         defer ast_scope.exit();
//         const input_value = callFrame.argument(0);
//         if (input_value.isEmptyOrUndefinedOrNull())
//             return global.throwInvalidArguments("Expected a string to parse", .{});
//         const input: jsc.Node.BlobOrStringOrBuffer = try .fromJS(global, allocator, input_value)
//             orelse input: {
//                 var str = try input_value.toBunString(global);
//                 defer str.deref();
//                 break :input .{ .string_or_buffer = .{ .string = str.toSlice(allocator) } };
//             };
//         defer input.deinit();
//         var log = logger.Log.init(bun.default_allocator);
//         defer log.deinit();
//         const source = &logger.Source.initPathString("input.json5", input.slice());
//         const root = json5.JSON5Parser.parse(source, &log, allocator) catch |err|
//             return switch (err) {
//                 error.OutOfMemory => |oom| oom,
//                 error.StackOverflow => global.throwStackOverflow(),
//                 else => {
//                     if (log.msgs.items.len > 0) {
//                         const first_msg = log.msgs.items[0];
//                         return global.throwValue(global.createSyntaxErrorInstance(
//                             "JSON5 Parse error: {s}", .{first_msg.data.text}));
//                     }
//                     return global.throwValue(global.createSyntaxErrorInstance(
//                         "JSON5 Parse error: Unable to parse JSON5 string", .{}));
//                 },
//             };
//         return exprToJS(root, global);
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

pub fn stringify(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalThis;
    _ = callframe;
    return .js_undefined;
}

/// `Space` mirrors the upstream `Stringifier.Space` union, kept as a pure-Zig
/// helper so the indentation-clamp rules stay testable. Once the JS bridge
/// lands the `init()` constructor in the parked body re-attaches.
pub const Space = union(enum) {
    minified,
    /// Number of spaces per indent step (clamped to 10 per the spec).
    number: u32,
    /// Custom indent string (clamped to first 10 chars per the spec).
    string_len: u32,

    /// Spec rule: `Math.min(10, ToIntegerOrInfinity(space))`.
    /// `NaN`, `Infinity`, negatives, and values < 1 collapse to `minified`.
    pub fn fromNumber(n: f64) Space {
        if (!(n >= 1)) return .minified; // catches NaN, -Infinity, 0, negatives
        return .{ .number = if (n > 10) 10 else @intFromFloat(n) };
    }

    /// Spec rule: empty string collapses to `minified`; long strings clamp
    /// to first 10 chars.
    pub fn fromStringLen(len: usize) Space {
        if (len == 0) return .minified;
        return .{ .string_len = if (len > 10) 10 else @intCast(len) };
    }
};

/// `appendQuotedString`'s escape decision table for control chars + JSON5's
/// distinguishing escapes (single-quote / `\0` / `\v` / `\xHH` for the
/// remaining controls). Returns `null` for chars that go through verbatim.
pub fn json5StringEscape(c: u16) ?[]const u8 {
    return switch (c) {
        0x00 => "\\0",
        0x08 => "\\b",
        0x09 => "\\t",
        0x0a => "\\n",
        0x0b => "\\v",
        0x0c => "\\f",
        0x0d => "\\r",
        0x27 => "\\'", // single quote — JSON5 quoting
        0x5c => "\\\\", // backslash
        0x2028 => "\\u2028",
        0x2029 => "\\u2029",
        else => null,
    };
}

pub fn isJson5ControlEscape(c: u16) bool {
    return switch (c) {
        0x01...0x07, 0x0e...0x1f, 0x7f => true,
        else => false,
    };
}

pub fn hexDigit(v: u16) u8 {
    const nibble: u8 = @intCast(v & 0x0f);
    return if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
}

test "JSON5Object: create returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(JSValue.zero, create(g));
}

test "JSON5Object: parse returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.zero, try parse(g, cf));
}

test "JSON5Object: stringify returns the stubbed JSValue.js_undefined" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.js_undefined, try stringify(g, cf));
}

test "JSON5Object: JSValue tag is ABI-compatible with i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}

test "JSON5Object.Space.fromNumber: clamp + collapse rules" {
    try std.testing.expectEqual(Space.minified, Space.fromNumber(0));
    try std.testing.expectEqual(Space.minified, Space.fromNumber(-3.5));
    try std.testing.expectEqual(Space.minified, Space.fromNumber(0.5));
    try std.testing.expectEqual(Space.minified, Space.fromNumber(std.math.nan(f64)));
    try std.testing.expectEqual(Space{ .number = 1 }, Space.fromNumber(1));
    try std.testing.expectEqual(Space{ .number = 4 }, Space.fromNumber(4));
    try std.testing.expectEqual(Space{ .number = 10 }, Space.fromNumber(10));
    try std.testing.expectEqual(Space{ .number = 10 }, Space.fromNumber(999));
    try std.testing.expectEqual(Space{ .number = 10 }, Space.fromNumber(std.math.inf(f64)));
}

test "JSON5Object.Space.fromStringLen: empty collapses, long clamps" {
    try std.testing.expectEqual(Space.minified, Space.fromStringLen(0));
    try std.testing.expectEqual(Space{ .string_len = 1 }, Space.fromStringLen(1));
    try std.testing.expectEqual(Space{ .string_len = 10 }, Space.fromStringLen(10));
    try std.testing.expectEqual(Space{ .string_len = 10 }, Space.fromStringLen(42));
}

test "JSON5Object.json5StringEscape: control chars + single quote + LS/PS" {
    try std.testing.expectEqualStrings("\\0", json5StringEscape(0x00).?);
    try std.testing.expectEqualStrings("\\b", json5StringEscape(0x08).?);
    try std.testing.expectEqualStrings("\\t", json5StringEscape(0x09).?);
    try std.testing.expectEqualStrings("\\n", json5StringEscape(0x0a).?);
    try std.testing.expectEqualStrings("\\v", json5StringEscape(0x0b).?);
    try std.testing.expectEqualStrings("\\f", json5StringEscape(0x0c).?);
    try std.testing.expectEqualStrings("\\r", json5StringEscape(0x0d).?);
    try std.testing.expectEqualStrings("\\'", json5StringEscape(0x27).?);
    try std.testing.expectEqualStrings("\\\\", json5StringEscape(0x5c).?);
    try std.testing.expectEqualStrings("\\u2028", json5StringEscape(0x2028).?);
    try std.testing.expectEqualStrings("\\u2029", json5StringEscape(0x2029).?);
    try std.testing.expect(json5StringEscape('A') == null);
    try std.testing.expect(json5StringEscape('"') == null); // double quote unescaped in single-quoted JSON5
}

test "JSON5Object.isJson5ControlEscape: \\xHH ranges only" {
    try std.testing.expect(isJson5ControlEscape(0x01));
    try std.testing.expect(isJson5ControlEscape(0x07));
    try std.testing.expect(!isJson5ControlEscape(0x08)); // \b → table entry, not \xHH
    try std.testing.expect(!isJson5ControlEscape(0x0d));
    try std.testing.expect(isJson5ControlEscape(0x0e));
    try std.testing.expect(isJson5ControlEscape(0x1f));
    try std.testing.expect(isJson5ControlEscape(0x7f));
    try std.testing.expect(!isJson5ControlEscape('A'));
}

test "JSON5Object.hexDigit: lowercase hex output" {
    try std.testing.expectEqual(@as(u8, '0'), hexDigit(0));
    try std.testing.expectEqual(@as(u8, '9'), hexDigit(9));
    try std.testing.expectEqual(@as(u8, 'a'), hexDigit(10));
    try std.testing.expectEqual(@as(u8, 'f'), hexDigit(15));
    // High bits ignored — only the low nibble is used.
    try std.testing.expectEqual(@as(u8, '0'), hexDigit(0xf0));
    try std.testing.expectEqual(@as(u8, 'a'), hexDigit(0xfa));
}

comptime {
    _ = &home_rt.upstream_sha;
}
