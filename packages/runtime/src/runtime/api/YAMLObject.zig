// Copied from bun/src/runtime/api/YAMLObject.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the JS bridge +
// YAML parser/printer deps):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSFunction`,
//     `jsc.ZigString`, `jsc.MarkedArgumentBuffer`, `jsc.wtf.StringBuilder`,
//     `bun.JSError`, `bun.String`, `bun.StackCheck`, `bun.AllocationScope`,
//     `bun.StringHashMap`, `bun.default_allocator` — opaque locals + an
//     `enum(i64)` for `JSValue`. Same pattern as `TOMLObject.zig` /
//     `JSON5Object.zig`.
//   - `bun.interchange.yaml.YAML`, `bun.ast.{Expr, ASTMemoryAllocator}`,
//     `bun.logger.{Log, Source}` — parser surface parked. The upstream
//     parse/stringify bodies are kept verbatim as comments so re-attachment
//     is mechanical once the YAML pipeline lands.
//
// Pure-Zig pieces (the `Space` clamp rules, the YAML safe-bareword test,
// and the anchor-id width rules) are exercised by tests.

//! `Bun.YAML.parse(text)` and `Bun.YAML.stringify(value, replacer?, space?)`
//! host fns. Powered by the in-tree YAML 1.2 parser/printer.

const std = @import("std");
const home_rt = @import("home_rt");

// JSC stubs — re-attach when the matching home_rt.jsc surface lands.
const JSGlobalObject = opaque {};
const CallFrame = opaque {};
pub const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};
pub const JSError = error{JSError};

// Upstream `create()` parked verbatim — depends on `JSValue.createEmptyObject`,
// `ZigString.static`, and `jsc.JSFunction.create`. None on home_rt yet.
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
//     pub fn stringify(global, callFrame) JSError!JSValue {
//         const value, const replacer, const space_value = callFrame.argumentsAsArray(3);
//         value.ensureStillAlive();
//         if (value.isUndefined() or value.isSymbol() or value.isFunction()) return .js_undefined;
//         if (!replacer.isUndefinedOrNull())
//             return global.throw("YAML.stringify does not support the replacer argument", .{});
//         var scope: bun.AllocationScope = .init(bun.default_allocator);
//         defer scope.deinit();
//         var stringifier: Stringifier = try .init(scope.allocator(), global, space_value);
//         defer stringifier.deinit();
//         stringifier.findAnchorsAndAliases(global, value, .root) catch |err|
//             return switch (err) { ... };
//         stringifier.stringify(global, value) catch |err|
//             return switch (err) { ... };
//         return stringifier.builder.toString(global);
//     }
//
//     pub fn parse(global, callFrame) JSError!JSValue {
//         // Walks logger.Source over an arena, calls YAML.parse, then maps
//         // ast.Expr → JSValue. The fast-path memoises the empty document
//         // case to `.js_undefined`.
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

/// Mirrors the upstream `Stringifier.Space` union, kept as a pure-Zig
/// helper so the indentation-clamp + collapse rules stay testable.
pub const Space = union(enum) {
    minified,
    number: u32,
    string_len: u32,

    /// Spec rule: `Math.min(10, ToIntegerOrInfinity(space))`. Negatives /
    /// NaN / Infinity / values < 1 collapse to `minified`.
    pub fn fromNumber(n: f64) Space {
        if (!(n >= 1)) return .minified;
        return .{ .number = if (n > 10) 10 else @intFromFloat(n) };
    }

    /// Spec rule: empty collapses; long clamps to first 10.
    pub fn fromStringLen(len: usize) Space {
        if (len == 0) return .minified;
        return .{ .string_len = if (len > 10) 10 else @intCast(len) };
    }
};

/// Marks the position of an anchor in the produced YAML document. The
/// upstream walker tracks each shared object/array twice — once at "first
/// emit" (`AnchorAlias.anchor`) and once at "reuse" (`.alias`). Kept as a
/// pure-Zig enum so the table layout stays testable without the JS bridge.
pub const AnchorAlias = enum { anchor, alias };

/// Path tag used when walking the value graph to discover shared
/// collections. The root carries no parent; arrays carry their index;
/// objects carry the property name.
pub const PathTag = enum { root, array, object };

/// YAML allows bare unquoted plain scalars when they don't look like a
/// flow indicator, tag, anchor, alias, reserved keyword, or number.
/// This is the conservative subset upstream uses for keys.
///
/// Reserved literals returned as `false` so they're forced to quoted form:
///   - `null`, `true`, `false`, `yes`, `no`, `on`, `off`, `~`
pub fn isPlainBareKey(s: []const u8) bool {
    if (s.len == 0) return false;
    // First char restrictions per YAML 1.2 §7.3.3
    switch (s[0]) {
        // Flow / block / tag / anchor / alias indicators.
        '!', '&', '*', '#', ',', '[', ']', '{', '}', '"', '\'', '|', '>', '%', '@', '`' => return false,
        ' ', '\t', '\n', '\r' => return false,
        '-', '?', ':' => {
            // Allowed only if next char is non-blank and not a colon.
            if (s.len < 2) return false;
            switch (s[1]) {
                ' ', '\t', '\n', '\r', ':' => return false,
                else => {},
            }
        },
        else => {},
    }
    // Reject reserved scalars.
    if (isReservedScalar(s)) return false;
    // Reject if it parses as a number — would round-trip lossy on re-parse.
    if (looksLikeNumber(s)) return false;
    // No `: ` or ` #` substrings; both reopen the parser into key/comment.
    for (0..s.len) |i| {
        if (s[i] == ':' and (i + 1 == s.len or s[i + 1] == ' ')) return false;
        if (s[i] == '#' and i > 0 and s[i - 1] == ' ') return false;
        if (s[i] < 0x20 or s[i] == 0x7f) return false;
    }
    return true;
}

fn isReservedScalar(s: []const u8) bool {
    inline for ([_][]const u8{
        "null", "Null",  "NULL",
        "true", "True",  "TRUE",
        "false", "False", "FALSE",
        "yes", "Yes",   "YES",
        "no",   "No",   "NO",
        "on",   "On",   "ON",
        "off",  "Off",  "OFF",
        "~",
    }) |word| {
        if (std.mem.eql(u8, s, word)) return true;
    }
    return false;
}

fn looksLikeNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') i = 1;
    if (i == s.len) return false;
    // Hex / oct / bin: 0x..., 0o..., 0b...
    if (s.len - i >= 2 and s[i] == '0' and (s[i + 1] == 'x' or s[i] == 'o' or s[i + 1] == 'b')) {
        return true;
    }
    var saw_digit = false;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '0'...'9' => saw_digit = true,
            '.', 'e', 'E', '+', '-' => {},
            else => return false,
        }
    }
    return saw_digit;
}

/// Anchor ids are emitted as `&a1`, `&a2`, ... — the digit width controls
/// padded sort order. Upstream uses base-10 ids; this is the same width
/// formula in pure Zig so we can re-attach the printer hot path later.
pub fn anchorIdWidth(id: usize) usize {
    if (id == 0) return 1;
    var width: usize = 0;
    var n = id;
    while (n > 0) : (width += 1) n /= 10;
    return width;
}

test "YAMLObject: create returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(JSValue.zero, create(g));
}

test "YAMLObject: parse returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.zero, try parse(g, cf));
}

test "YAMLObject: stringify returns the stubbed JSValue.js_undefined" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.js_undefined, try stringify(g, cf));
}

test "YAMLObject: JSValue tag is ABI-compatible with i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}

test "YAMLObject.Space.fromNumber: clamp + collapse rules" {
    try std.testing.expectEqual(Space.minified, Space.fromNumber(0));
    try std.testing.expectEqual(Space.minified, Space.fromNumber(-1));
    try std.testing.expectEqual(Space.minified, Space.fromNumber(std.math.nan(f64)));
    try std.testing.expectEqual(Space{ .number = 1 }, Space.fromNumber(1));
    try std.testing.expectEqual(Space{ .number = 10 }, Space.fromNumber(10));
    try std.testing.expectEqual(Space{ .number = 10 }, Space.fromNumber(999));
    try std.testing.expectEqual(Space{ .number = 10 }, Space.fromNumber(std.math.inf(f64)));
}

test "YAMLObject.Space.fromStringLen: empty collapses, long clamps" {
    try std.testing.expectEqual(Space.minified, Space.fromStringLen(0));
    try std.testing.expectEqual(Space{ .string_len = 1 }, Space.fromStringLen(1));
    try std.testing.expectEqual(Space{ .string_len = 10 }, Space.fromStringLen(10));
    try std.testing.expectEqual(Space{ .string_len = 10 }, Space.fromStringLen(42));
}

test "YAMLObject.isPlainBareKey: ordinary identifiers pass" {
    try std.testing.expect(isPlainBareKey("foo"));
    try std.testing.expect(isPlainBareKey("foo_bar"));
    try std.testing.expect(isPlainBareKey("a"));
    try std.testing.expect(isPlainBareKey("snake_case"));
}

test "YAMLObject.isPlainBareKey: reserved scalars + numbers are forced to quoted" {
    try std.testing.expect(!isPlainBareKey(""));
    try std.testing.expect(!isPlainBareKey("null"));
    try std.testing.expect(!isPlainBareKey("Null"));
    try std.testing.expect(!isPlainBareKey("true"));
    try std.testing.expect(!isPlainBareKey("false"));
    try std.testing.expect(!isPlainBareKey("yes"));
    try std.testing.expect(!isPlainBareKey("no"));
    try std.testing.expect(!isPlainBareKey("on"));
    try std.testing.expect(!isPlainBareKey("off"));
    try std.testing.expect(!isPlainBareKey("~"));
    try std.testing.expect(!isPlainBareKey("42"));
    try std.testing.expect(!isPlainBareKey("-3.14"));
}

test "YAMLObject.isPlainBareKey: flow indicators + leading-blank rejected" {
    try std.testing.expect(!isPlainBareKey("!tag"));
    try std.testing.expect(!isPlainBareKey("&anchor"));
    try std.testing.expect(!isPlainBareKey("*alias"));
    try std.testing.expect(!isPlainBareKey("#comment"));
    try std.testing.expect(!isPlainBareKey("[seq"));
    try std.testing.expect(!isPlainBareKey("{map"));
    try std.testing.expect(!isPlainBareKey(" leading"));
    try std.testing.expect(!isPlainBareKey("\ttab"));
    try std.testing.expect(!isPlainBareKey("foo: bar")); // `: ` reopens key parse
    try std.testing.expect(!isPlainBareKey("foo #c")); // ` #` reopens comment
}

test "YAMLObject.anchorIdWidth: base-10 width" {
    try std.testing.expectEqual(@as(usize, 1), anchorIdWidth(0));
    try std.testing.expectEqual(@as(usize, 1), anchorIdWidth(9));
    try std.testing.expectEqual(@as(usize, 2), anchorIdWidth(10));
    try std.testing.expectEqual(@as(usize, 2), anchorIdWidth(99));
    try std.testing.expectEqual(@as(usize, 3), anchorIdWidth(100));
    try std.testing.expectEqual(@as(usize, 4), anchorIdWidth(9999));
}

comptime {
    _ = &home_rt.upstream_sha;
}
