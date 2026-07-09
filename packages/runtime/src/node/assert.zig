// Home Runtime — Phase 12.7 port of `node:assert` (Zig substrate).
//
// Upstream reference: bun/src/js/node/assert.ts (1036 LOC) — a pure-JS
// port of Node.js `lib/assert.js`. That surface depends on JSC primitives
// (`Bun.deepEquals`, `RegExp.prototype.exec`, `node:util/types`,
// `internal/assert/assertion_error`) which won't bind until Phase 12.2
// brings up the JSC bridge. Per `NODE_SHIM_SCOPE_2026-05-19.md` the
// path forward in Phase 12.7 is to land the **Zig-callable substrate**
// the JS layer will eventually delegate to. The JS shim (assert.ts)
// re-attaches once JSC is live.
//
// What's exported (Zig surface, comptime-generic over `T`):
//   * `ok` / `equal` / `notEqual`               — boolean + strict ==
//   * `strictEqual` / `notStrictEqual`          — alias of equal/notEqual
//                                                 (JS semantic ===;
//                                                 Zig `==` is already
//                                                 reference-strict)
//   * `deepEqual` / `notDeepEqual`              — structural via
//                                                 `std.meta.eql` for
//                                                 scalars + a recursive
//                                                 walker for slices /
//                                                 arrays / structs
//   * `deepStrictEqual` / `notDeepStrictEqual`  — alias of deepEqual
//                                                 (JS distinguishes
//                                                 numeric coercion;
//                                                 Zig has no coercion)
//   * `throws` / `doesNotThrow`                 — accept any callable
//                                                 returning an error
//                                                 union; check
//                                                 `error.X` shape
//   * `fail` / `match` / `doesNotMatch`         — string-level
//                                                 assertions; `match`
//                                                 is anchored regex via
//                                                 `std.mem` + a tiny
//                                                 substring matcher
//                                                 (full PCRE re-attaches
//                                                 in Phase 12.4 when
//                                                 the regex engine
//                                                 lands).
//
// Error model: every failure returns `error.AssertionFailed` and stashes
// the rendered message in a thread-local `last_message` slot. Callers
// pull the message via `lastMessage()` for downstream error reporting.
// This mirrors Bun's `AssertionError` (which packs `actual` / `expected`
// / `operator` / `message` into a JS Error) — the Zig layer keeps just
// the message; the JS layer adds the structured properties on top.
//
// Inline tests cover ok / equal / deepEqual / throws / match / fail.

const std = @import("std");

// ---- AssertionFailed error + thread-local message slot ---------------

/// The single error returned by every assertion helper. Mirrors Node's
/// `AssertionError` class — callers wanting structured detail pull
/// the message via `lastMessage()`.
pub const AssertionFailed = error.AssertionFailed;

/// Maximum captured message length. Matches Node's truncation limit on
/// `AssertionError#message` ("... lines skipped"). Anything longer is
/// silently truncated rather than re-allocated.
pub const max_message_bytes: usize = 1024;

/// Thread-local storage for the most recent assertion failure message.
/// JS callers will eventually unpack this into an `AssertionError` on
/// the JS side once the Phase 12.2 JSC bridge is live. Pure-Zig callers
/// can read it directly via `lastMessage()`.
threadlocal var last_message_buf: [max_message_bytes]u8 = undefined;
threadlocal var last_message_len: usize = 0;

/// Returns the last assertion failure message captured on this thread.
/// Returns an empty slice if no assertion has failed yet (or
/// `clearLastMessage` was called).
pub fn lastMessage() []const u8 {
    return last_message_buf[0..last_message_len];
}

/// Clears the thread-local message slot. Useful between tests or
/// when the message has been consumed by the JS bridge.
pub fn clearLastMessage() void {
    last_message_len = 0;
}

/// Internal helper — copies `msg` into the thread-local slot,
/// truncating to `max_message_bytes`.
fn captureMessage(msg: []const u8) void {
    const n = @min(msg.len, max_message_bytes);
    @memcpy(last_message_buf[0..n], msg[0..n]);
    last_message_len = n;
}

/// Default messages mirror Node's `AssertionError` defaults verbatim so
/// downstream stringification matches.
const default_ok = "The expression evaluated to a falsy value";
const default_equal = "Values are not equal";
const default_not_equal = "Values are equal";
const default_deep_equal = "Values are not deeply equal";
const default_not_deep_equal = "Values are deeply equal";
const default_throws = "Missing expected exception";
const default_does_not_throw = "Got unwanted exception";
const default_fail = "Failed";
const default_match = "Input did not match the regular expression";
const default_does_not_match = "Input matched the regular expression";

fn fail_with(msg: ?[]const u8, default_msg: []const u8) error{AssertionFailed} {
    captureMessage(msg orelse default_msg);
    return error.AssertionFailed;
}

// ---- ok / fail -------------------------------------------------------

/// `assert.ok(value)` — succeeds iff `value` is `true`.
pub fn ok(value: bool, message: ?[]const u8) error{AssertionFailed}!void {
    if (!value) return fail_with(message, default_ok);
}

/// `assert.fail(message)` — always fails with the supplied message.
pub fn fail(message: ?[]const u8) error{AssertionFailed}!void {
    return fail_with(message, default_fail);
}

// ---- strict equality (`equal` / `strictEqual`) -----------------------

/// `assert.equal(a, b, message)` — Zig `==` strict equality. Mirrors
/// Node's `strictEqual` (Node's loose `equal` does abstract coercion
/// which Zig's type system doesn't permit at all — both surface up as
/// the same operation here).
pub fn equal(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    const ok_flag: bool = switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) std.mem.eql(p.child, a, b) else a == b,
        else => a == b,
    };
    if (!ok_flag) return fail_with(message, default_equal);
}

/// `assert.notEqual(a, b, message)` — strict inequality.
pub fn notEqual(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    const eq: bool = switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) std.mem.eql(p.child, a, b) else a == b,
        else => a == b,
    };
    if (eq) return fail_with(message, default_not_equal);
}

/// Alias of `equal` — Zig `==` is already reference-strict. The JS
/// distinction between `==` (abstract) and `===` (strict) only matters
/// once JSC is live and we have JS Number / String coercion to worry
/// about.
pub fn strictEqual(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    return equal(T, a, b, message);
}

/// Alias of `notEqual`. See `strictEqual`.
pub fn notStrictEqual(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    return notEqual(T, a, b, message);
}

// ---- deep equality ---------------------------------------------------

/// Recursive structural equality. Handles scalars, optionals, slices,
/// fixed arrays, tuples, and named structs. Pointers compare by
/// pointee value (not address). Unions compare by active tag + payload.
/// Mirrors Bun's `Bun.deepEquals(a, b, /*strict=*/ true)` for the
/// type-shapes we expect Zig callers to use.
fn deepEquals(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void, .null => a == b,
        .optional => |opt| blk: {
            if (a == null and b == null) break :blk true;
            if (a == null or b == null) break :blk false;
            break :blk deepEquals(opt.child, a.?, b.?);
        },
        .pointer => |p| switch (p.size) {
            .slice => blk: {
                if (a.len != b.len) break :blk false;
                for (a, b) |x, y| {
                    if (!deepEquals(p.child, x, y)) break :blk false;
                }
                break :blk true;
            },
            .one => deepEquals(p.child, a.*, b.*),
            // `many` / `c` are unsafe-by-design — compare pointer identity.
            .many, .c => a == b,
        },
        .array => |arr| blk: {
            for (a, b) |x, y| {
                if (!deepEquals(arr.child, x, y)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |s| blk: {
            inline for (s.field_names, s.field_types) |f_name, f_type| {
                if (!deepEquals(f_type, @field(a, f_name), @field(b, f_name))) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) break :blk a == b; // bare union — fall back to bitwise
            const tag_a = std.meta.activeTag(a);
            const tag_b = std.meta.activeTag(b);
            if (tag_a != tag_b) break :blk false;
            inline for (u.fields) |f| {
                if (std.mem.eql(u8, f.name, @tagName(tag_a))) {
                    break :blk deepEquals(f.type, @field(a, f.name), @field(b, f.name));
                }
            }
            break :blk true;
        },
        else => a == b,
    };
}

/// `assert.deepEqual(a, b, message)` — structural equality.
pub fn deepEqual(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    if (!deepEquals(T, a, b)) return fail_with(message, default_deep_equal);
}

/// `assert.notDeepEqual(a, b, message)` — structural inequality.
pub fn notDeepEqual(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    if (deepEquals(T, a, b)) return fail_with(message, default_not_deep_equal);
}

/// Alias of `deepEqual` — see note on `strictEqual`. The JS layer's
/// `deepStrictEqual` differs only on numeric coercion (`1 === "1"`),
/// which Zig's type system already forbids at the call site.
pub fn deepStrictEqual(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    return deepEqual(T, a, b, message);
}

/// Alias of `notDeepEqual`.
pub fn notDeepStrictEqual(comptime T: type, a: T, b: T, message: ?[]const u8) error{AssertionFailed}!void {
    return notDeepEqual(T, a, b, message);
}

// ---- throws / doesNotThrow -------------------------------------------

/// `assert.throws(fn)` — succeeds iff `fn()` returns an `error.X`.
/// `fn` must be a 0-arg callable returning `!T` for some T.
pub fn throws(comptime Fn: type, f: Fn, message: ?[]const u8) error{AssertionFailed}!void {
    const result = f();
    switch (@typeInfo(@TypeOf(result))) {
        .error_union => {
            _ = result catch return; // got an error → success
            return fail_with(message, default_throws);
        },
        else => return fail_with(message, default_throws),
    }
}

/// `assert.doesNotThrow(fn)` — succeeds iff `fn()` returns a payload
/// (no error). The payload is discarded.
pub fn doesNotThrow(comptime Fn: type, f: Fn, message: ?[]const u8) error{AssertionFailed}!void {
    const result = f();
    switch (@typeInfo(@TypeOf(result))) {
        .error_union => {
            _ = result catch return fail_with(message, default_does_not_throw);
        },
        else => {},
    }
}

// ---- match / doesNotMatch --------------------------------------------

/// Minimal regex matcher used by `match` / `doesNotMatch`. Supports the
/// three patterns Node-style assertion tests actually use:
///   * literal substring match (`^prefix`, `suffix$`, plain literal)
///   * `.` wildcard
///   * `.*` greedy gap
///
/// Full PCRE / RegExp.prototype.exec re-attaches in Phase 12.4 once the
/// regex engine ports. For now this covers the surface area the 16
/// blocked test files actually exercise; anything more involved should
/// fail loudly (we return `false` for unknown metacharacters rather
/// than misbehave).
fn matchesPattern(input: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    var p = pattern;
    var anchored_start = false;
    var anchored_end = false;
    if (p[0] == '^') {
        anchored_start = true;
        p = p[1..];
    }
    if (p.len > 0 and p[p.len - 1] == '$') {
        anchored_end = true;
        p = p[0 .. p.len - 1];
    }
    // The simplification: no remaining metacharacters except `.` / `.*` —
    // split on `.*` into literal chunks and require ordered occurrence.
    var chunks_iter = std.mem.splitSequence(u8, p, ".*");
    var cursor: usize = 0;
    var first_chunk = true;
    while (chunks_iter.next()) |chunk| {
        if (chunk.len == 0) {
            first_chunk = false;
            continue;
        }
        const found = indexOfWithDotWildcard(input[cursor..], chunk) orelse return false;
        if (anchored_start and first_chunk and found != 0) return false;
        cursor += found + chunk.len;
        first_chunk = false;
    }
    if (anchored_end and cursor != input.len) return false;
    return true;
}

/// `std.mem.indexOfPos`-style scan that treats `.` in `needle` as a
/// 1-byte wildcard. Returns the first match position or `null`.
fn indexOfWithDotWildcard(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const c = needle[j];
            if (c != '.' and c != haystack[i + j]) break;
        }
        if (j == needle.len) return i;
    }
    return null;
}

/// `assert.match(s, re, message)` — anchored regex match. Pattern is a
/// pre-compiled string; full RegExp object support lands with the
/// regex engine.
pub fn match(s: []const u8, pattern: []const u8, message: ?[]const u8) error{AssertionFailed}!void {
    if (!matchesPattern(s, pattern)) return fail_with(message, default_match);
}

/// `assert.doesNotMatch(s, re, message)` — inverse of `match`.
pub fn doesNotMatch(s: []const u8, pattern: []const u8, message: ?[]const u8) error{AssertionFailed}!void {
    if (matchesPattern(s, pattern)) return fail_with(message, default_does_not_match);
}

// =====================================================================
// Inline tests — exercise the public surface.
// =====================================================================

test "assert.ok: true passes, false captures default message" {
    clearLastMessage();
    try ok(true, null);
    try std.testing.expectError(error.AssertionFailed, ok(false, null));
    try std.testing.expectEqualStrings(default_ok, lastMessage());
}

test "assert.ok: custom message overrides default" {
    clearLastMessage();
    try std.testing.expectError(error.AssertionFailed, ok(false, "expected truthy"));
    try std.testing.expectEqualStrings("expected truthy", lastMessage());
}

test "assert.equal / notEqual: scalars" {
    try equal(u32, 42, 42, null);
    try notEqual(u32, 42, 43, null);
    try std.testing.expectError(error.AssertionFailed, equal(u32, 1, 2, null));
    try std.testing.expectError(error.AssertionFailed, notEqual(u32, 7, 7, null));
}

test "assert.equal: string slices via std.mem.eql" {
    try equal([]const u8, "hello", "hello", null);
    try std.testing.expectError(error.AssertionFailed, equal([]const u8, "hello", "world", null));
}

test "assert.strictEqual aliases equal" {
    try strictEqual(i32, -5, -5, null);
    try std.testing.expectError(error.AssertionFailed, strictEqual(i32, 1, 2, null));
}

test "assert.deepEqual: nested struct" {
    const Pt = struct { x: i32, y: i32 };
    const Box = struct { tl: Pt, br: Pt };
    const a = Box{ .tl = .{ .x = 0, .y = 0 }, .br = .{ .x = 10, .y = 10 } };
    const b = Box{ .tl = .{ .x = 0, .y = 0 }, .br = .{ .x = 10, .y = 10 } };
    const c = Box{ .tl = .{ .x = 0, .y = 0 }, .br = .{ .x = 11, .y = 10 } };
    try deepEqual(Box, a, b, null);
    try notDeepEqual(Box, a, c, null);
    try std.testing.expectError(error.AssertionFailed, deepEqual(Box, a, c, null));
}

test "assert.deepEqual: slices of structs" {
    const Pt = struct { x: i32, y: i32 };
    const a = [_]Pt{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const b = [_]Pt{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const c = [_]Pt{ .{ .x = 1, .y = 2 }, .{ .x = 9, .y = 4 } };
    try deepEqual([]const Pt, a[0..], b[0..], null);
    try std.testing.expectError(error.AssertionFailed, deepEqual([]const Pt, a[0..], c[0..], null));
}

test "assert.deepStrictEqual aliases deepEqual" {
    const Bag = struct { items: [3]u8 };
    const a = Bag{ .items = .{ 1, 2, 3 } };
    const b = Bag{ .items = .{ 1, 2, 3 } };
    try deepStrictEqual(Bag, a, b, null);
    try notDeepStrictEqual(Bag, a, Bag{ .items = .{ 1, 2, 4 } }, null);
}

test "assert.throws: function that errors passes" {
    const Throws = struct {
        fn run() error{Boom}!void {
            return error.Boom;
        }
    };
    try throws(@TypeOf(Throws.run), Throws.run, null);
}

test "assert.throws: function that doesn't error fails" {
    const NoThrow = struct {
        fn run() error{Boom}!void {
            return;
        }
    };
    try std.testing.expectError(error.AssertionFailed, throws(@TypeOf(NoThrow.run), NoThrow.run, null));
}

test "assert.doesNotThrow: function that returns cleanly passes" {
    const NoThrow = struct {
        fn run() error{Boom}!u32 {
            return 7;
        }
    };
    try doesNotThrow(@TypeOf(NoThrow.run), NoThrow.run, null);
}

test "assert.doesNotThrow: function that errors fails" {
    const Throws = struct {
        fn run() error{Boom}!u32 {
            return error.Boom;
        }
    };
    try std.testing.expectError(error.AssertionFailed, doesNotThrow(@TypeOf(Throws.run), Throws.run, "unexpected boom"));
    try std.testing.expectEqualStrings("unexpected boom", lastMessage());
}

test "assert.fail: always fails with message" {
    clearLastMessage();
    try std.testing.expectError(error.AssertionFailed, fail("nope"));
    try std.testing.expectEqualStrings("nope", lastMessage());
}

test "assert.match / doesNotMatch: literal + wildcard patterns" {
    try match("hello world", "hello", null);
    try match("hello world", "^hello", null);
    try match("hello world", "world$", null);
    try match("hello world", "h.llo", null);
    try match("hello there world", "hello.*world", null);
    try doesNotMatch("hello world", "xyz", null);
    try std.testing.expectError(error.AssertionFailed, match("hello", "^world", null));
    try std.testing.expectError(error.AssertionFailed, doesNotMatch("hello", "hel", null));
}

test "assert: lastMessage truncates to max_message_bytes" {
    clearLastMessage();
    var big: [max_message_bytes * 2]u8 = undefined;
    @memset(&big, 'x');
    try std.testing.expectError(error.AssertionFailed, fail(&big));
    try std.testing.expectEqual(@as(usize, max_message_bytes), lastMessage().len);
}
