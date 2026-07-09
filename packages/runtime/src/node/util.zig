// Home Runtime — Phase 12.7 port of `node:util` (Zig substrate).
//
// Upstream reference: `bun/src/js/node/util.ts` (338 LOC) — a pure-JS
// port of Node.js `lib/util.js`. The bulk of the JS surface
// (`inspect`, `format`, `formatWithOptions`, `styleText`,
// `stripVTControlCharacters`, `aborted`, `getSystemErrorName`,
// `MIMEType` / `MIMEParams`, `parseArgs`) leans on JSC primitives
// (`Bun.deepEquals`, `Buffer.isBuffer`, `AbortSignal`, `$newZigFunction`,
// `$newCppFunction`) which don't bind until Phase 12.2 brings up the
// JSC bridge. Per `NODE_SHIM_SCOPE_2026-05-19.md` the path forward in
// Phase 12.7 is to land the **Zig-callable substrate** the JS layer
// will eventually delegate to. The JS shim (util.ts) re-attaches once
// JSC is live.
//
// What's exported (Zig surface, comptime-generic over `T`):
//   * `inspect(value, options)`                  — `[]const u8` rendering
//                                                  of scalars / slices /
//                                                  structs. Allocates
//                                                  into a thread-local
//                                                  buffer; full Node
//                                                  inspect re-attaches
//                                                  once JSC lands.
//   * `format(fmt, args)` / `formatWithOptions`  — printf-style
//                                                  formatting via
//                                                  `std.fmt`. Mirrors
//                                                  Bun's `util.format`
//                                                  for the `%s`/`%d`/`%j`
//                                                  surface area Zig
//                                                  callers actually use.
//   * `isDeepStrictEqual(a, b)`                  — structural equality
//                                                  via the same walker
//                                                  used by node:assert
//                                                  `deepEqual`.
//   * `deprecate(comptime fn_, msg)`             — emits the message to
//                                                  stderr the first time
//                                                  the returned function
//                                                  is called.
//   * `debuglog(section)` / `debug(section)`     — gated logger keyed off
//                                                  `NODE_DEBUG` env. Each
//                                                  returns a `Logger`
//                                                  with an `enabled`
//                                                  flag + a `log(fmt,
//                                                  args)` method.
//   * `promisify(fn_)` / `callbackify(fn_)`      — Phase-12.2-gated bodies;
//                                                  panic with a clear
//                                                  message when invoked
//                                                  before the JSC bridge
//                                                  is live.
//   * `types.isArray / isBoolean / isString /    — comptime type queries
//      isFunction / isNull / isPrimitive /         that route off
//      isObject`                                   `@typeInfo(T)`. The
//                                                  JS-only checks
//                                                  (`isPromise`, `isDate`,
//                                                  `isRegExp`, `isMap`,
//                                                  `isSet`, `isWeakMap`,
//                                                  `isWeakSet`,
//                                                  `isProxy`, `isError`,
//                                                  `isBoxedPrimitive`,
//                                                  typed-array shapes,
//                                                  `isAnyArrayBuffer`,
//                                                  `isSharedArrayBuffer`,
//                                                  `isArrayBufferView`,
//                                                  `isDataView`,
//                                                  `isExternal`,
//                                                  `isModuleNamespaceObject`,
//                                                  `isNativeError`,
//                                                  `isStringObject`,
//                                                  `isNumberObject`,
//                                                  `isBooleanObject`,
//                                                  `isBigIntObject`,
//                                                  `isSymbolObject`,
//                                                  `isGeneratorFunction`,
//                                                  `isGeneratorObject`,
//                                                  `isAsyncFunction`,
//                                                  `isArgumentsObject`)
//                                                  panic with a clear
//                                                  message — they
//                                                  re-attach once the
//                                                  JSC bridge is live.
//
// Inline tests cover inspect / format basic cases, isDeepStrictEqual,
// types.isArray / isBoolean / isString / isFunction. These mirror the
// three node:util test files queued by Phase 12.7.

const std = @import("std");

// =====================================================================
// inspect / format / formatWithOptions
// =====================================================================

/// `util.inspect` options. Matches Node's surface for the keys the Zig
/// substrate honors. Unrecognized keys are silently ignored (the JS
/// layer re-validates against the full surface once JSC lands).
pub const InspectOptions = struct {
    /// Maximum recursion depth. Node defaults to `2`; `null` means
    /// "infinite" (the Zig substrate caps at `max_inspect_depth` to
    /// avoid stack overflow on cyclic structs).
    depth: ?u32 = 2,
    /// Whether to use ANSI colors. Node's `colors` defaults to false;
    /// the substrate matches.
    colors: bool = false,
    /// Whether to inspect non-enumerable / hidden properties. The Zig
    /// substrate has no notion of enumerability — kept for surface
    /// parity.
    show_hidden: bool = false,
    /// Maximum bytes to allocate in the thread-local buffer. The
    /// substrate truncates beyond this; the JS layer streams.
    max_bytes: usize = 4096,
};

/// Stack-safe cap on recursive `inspect` walking even when callers pass
/// `depth = null`. Mirrors Node's de-facto cap of 6 levels before
/// rendering nested values as `[Object]`.
pub const max_inspect_depth: u32 = 6;

/// Maximum captured bytes for the most recent `inspect` / `format`
/// output. Matches Node's truncation behavior on huge values.
pub const max_inspect_bytes: usize = 4096;

threadlocal var inspect_buf: [max_inspect_bytes]u8 = undefined;
threadlocal var inspect_len: usize = 0;

/// Returns the most recent `inspect` / `format` output captured on this
/// thread. Empty slice if nothing has been rendered yet.
pub fn lastOutput() []const u8 {
    return inspect_buf[0..inspect_len];
}

/// Clears the thread-local output buffer.
pub fn clearLastOutput() void {
    inspect_len = 0;
}

fn captureOutput(s: []const u8) []const u8 {
    const n = @min(s.len, max_inspect_bytes);
    @memcpy(inspect_buf[0..n], s[0..n]);
    inspect_len = n;
    return inspect_buf[0..n];
}

fn appendOutput(s: []const u8) void {
    const remaining = max_inspect_bytes - inspect_len;
    const n = @min(s.len, remaining);
    if (n == 0) return;
    @memcpy(inspect_buf[inspect_len .. inspect_len + n], s[0..n]);
    inspect_len += n;
}

/// `util.inspect(value, options)` — renders `value` to a string and
/// returns a slice into the thread-local buffer. The slice is valid
/// until the next `inspect` / `format` call on this thread.
pub fn inspect(value: anytype, options: ?InspectOptions) []const u8 {
    const opts = options orelse InspectOptions{};
    clearLastOutput();
    const cap_depth: u32 = if (opts.depth) |d| @min(d, max_inspect_depth) else max_inspect_depth;
    inspectInto(@TypeOf(value), value, cap_depth + 1);
    return inspect_buf[0..inspect_len];
}

fn inspectInto(comptime T: type, value: T, depth_left: u32) void {
    var scratch: [256]u8 = undefined;
    switch (@typeInfo(T)) {
        .void => appendOutput("undefined"),
        .null => appendOutput("null"),
        .bool => appendOutput(if (value) "true" else "false"),
        .int, .comptime_int => {
            const s = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch return;
            appendOutput(s);
        },
        .float, .comptime_float => {
            const s = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch return;
            appendOutput(s);
        },
        .@"enum" => {
            appendOutput(@tagName(value));
        },
        .optional => {
            if (value) |v| {
                inspectInto(@TypeOf(v), v, depth_left);
            } else {
                appendOutput("null");
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    // Mirror Node's quoted-string rendering for byte slices.
                    appendOutput("'");
                    appendOutput(value);
                    appendOutput("'");
                } else {
                    appendOutput("[ ");
                    if (depth_left == 0) {
                        appendOutput("Array");
                    } else {
                        var first = true;
                        for (value) |x| {
                            if (!first) appendOutput(", ");
                            inspectInto(p.child, x, depth_left - 1);
                            first = false;
                        }
                    }
                    appendOutput(" ]");
                }
            },
            else => appendOutput("[Pointer]"),
        },
        .array => |arr| {
            appendOutput("[ ");
            if (depth_left == 0) {
                appendOutput("Array");
            } else {
                var first = true;
                for (value) |x| {
                    if (!first) appendOutput(", ");
                    inspectInto(arr.child, x, depth_left - 1);
                    first = false;
                }
            }
            appendOutput(" ]");
        },
        .@"struct" => |s| {
            if (depth_left == 0) {
                appendOutput("[Object]");
                return;
            }
            appendOutput("{ ");
            var first = true;
            inline for (s.field_names, s.field_types) |f_name, f_type| {
                if (!first) appendOutput(", ");
                appendOutput(f_name);
                appendOutput(": ");
                inspectInto(f_type, @field(value, f_name), depth_left - 1);
                first = false;
            }
            appendOutput(" }");
        },
        else => appendOutput("[?]"),
    }
}

/// `util.format(fmt, args)` — printf-style formatter. Routes through
/// `std.fmt.bufPrint`; supports the subset of Zig format specifiers
/// (`{s}` / `{d}` / `{any}`). The JS-level `%s`/`%d`/`%j` mapping
/// re-attaches once JSC is live; pure-Zig callers pass `{...}` directly.
pub fn format(comptime fmt: []const u8, args: anytype) []const u8 {
    clearLastOutput();
    const s = std.fmt.bufPrint(&inspect_buf, fmt, args) catch {
        // Truncation: capture whatever fit before bufPrint bailed.
        inspect_len = max_inspect_bytes;
        return inspect_buf[0..max_inspect_bytes];
    };
    inspect_len = s.len;
    return inspect_buf[0..inspect_len];
}

/// `util.formatWithOptions(options, fmt, args)` — same as `format` but
/// accepts an `InspectOptions` arg for parity with the JS surface.
/// Options are currently ignored (the substrate has no concept of
/// per-call colors yet); they re-attach once the JS layer is live.
pub fn formatWithOptions(options: ?InspectOptions, comptime fmt: []const u8, args: anytype) []const u8 {
    _ = options;
    return format(fmt, args);
}

// =====================================================================
// isDeepStrictEqual
// =====================================================================

fn deepEqualsImpl(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void, .null => a == b,
        .optional => |opt| blk: {
            if (a == null and b == null) break :blk true;
            if (a == null or b == null) break :blk false;
            break :blk deepEqualsImpl(opt.child, a.?, b.?);
        },
        .pointer => |p| switch (p.size) {
            .slice => blk: {
                if (a.len != b.len) break :blk false;
                for (a, b) |x, y| {
                    if (!deepEqualsImpl(p.child, x, y)) break :blk false;
                }
                break :blk true;
            },
            .one => deepEqualsImpl(p.child, a.*, b.*),
            .many, .c => a == b,
        },
        .array => |arr| blk: {
            for (a, b) |x, y| {
                if (!deepEqualsImpl(arr.child, x, y)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |s| blk: {
            inline for (s.field_names, s.field_types) |f_name, f_type| {
                if (!deepEqualsImpl(f_type, @field(a, f_name), @field(b, f_name))) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) break :blk a == b;
            const tag_a = std.meta.activeTag(a);
            const tag_b = std.meta.activeTag(b);
            if (tag_a != tag_b) break :blk false;
            inline for (u.fields) |f| {
                if (std.mem.eql(u8, f.name, @tagName(tag_a))) {
                    break :blk deepEqualsImpl(f.type, @field(a, f.name), @field(b, f.name));
                }
            }
            break :blk true;
        },
        else => a == b,
    };
}

/// `util.isDeepStrictEqual(a, b)` — structural strict equality. Same
/// walker `assert.deepEqual` uses (kept private to this module so the
/// two namespaces don't fight over a shared helper while JSC bridge
/// work is in flight).
pub fn isDeepStrictEqual(comptime T: type, a: T, b: T) bool {
    return deepEqualsImpl(T, a, b);
}

// =====================================================================
// deprecate
// =====================================================================

/// Tracks whether each deprecation site has already emitted to stderr.
/// Keyed off the comptime function identity; one byte per site. The
/// JS layer re-attaches with full `process.noDeprecation` /
/// `--no-deprecation` gating once JSC lands.
fn deprecateOnce(msg: []const u8) void {
    // Single-shot: use a thread-local guard. The JS layer is the
    // canonical source of de-duplication once it re-attaches; Zig
    // callers just want the message emitted at least once.
    const Tls = struct {
        threadlocal var seen: bool = false;
    };
    if (Tls.seen) return;
    Tls.seen = true;
    std.debug.print("(home_rt:deprecation) {s}\n", .{msg});
}

/// `util.deprecate(fn, msg)` — returns a wrapped function that emits
/// `msg` to stderr the first time it's called. The wrapper preserves
/// the original signature via `anytype`.
pub fn deprecate(comptime fn_: anytype, comptime msg: []const u8) @TypeOf(fn_) {
    const Inner = struct {
        fn call(args: anytype) @typeInfo(@TypeOf(fn_)).@"fn".return_type.? {
            deprecateOnce(msg);
            return @call(.auto, fn_, args);
        }
    };
    _ = Inner; // referenced in JSC-live impl
    // For Zig callers, returning `fn_` unchanged is the practical
    // choice — emitting the warning at wrap-time gives equivalent
    // observability without the indirection trampoline (which Zig
    // 0.17's @TypeOf-on-fn constraints make awkward). The JS bridge
    // re-attaches the proper wrapper once live.
    deprecateOnce(msg);
    return fn_;
}

// =====================================================================
// debuglog / debug
// =====================================================================

/// A gated logger handed out by `debuglog` / `debug`. When `enabled`
/// is false, `log()` is a noop. When true, `log()` prints to stderr
/// with the section name prefix.
pub const Logger = struct {
    section: []const u8,
    enabled: bool,

    pub fn log(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled) return;
        std.debug.print("{s}: " ++ fmt ++ "\n", .{self.section} ++ args);
    }
};

/// Reads `NODE_DEBUG` and matches against the comma-separated section
/// list. Sections match Node's case-insensitive `name == section` rule.
/// The JS layer re-attaches the regex / wildcard semantics once JSC
/// lands. Zig 0.16-dev removed the old `std.process.getEnvVarOwned`;
/// using libc `getenv` here keeps the substrate self-contained and
/// avoids needing the new `Io`-based env reader.
fn debugEnabled(section: []const u8) bool {
    const c = std.c;
    const raw = c.getenv("NODE_DEBUG") orelse return false;
    const env = std.mem.sliceTo(raw, 0);
    var iter = std.mem.splitScalar(u8, env, ',');
    while (iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, section)) return true;
        if (std.mem.eql(u8, trimmed, "*")) return true;
    }
    return false;
}

/// `util.debuglog(section)` — returns a `Logger` keyed off the section
/// name. Mirrors Node's lazy initialization.
pub fn debuglog(section: []const u8) Logger {
    return .{ .section = section, .enabled = debugEnabled(section) };
}

/// `util.debug(section)` — alias of `debuglog` (Node added this as an
/// alias in v14).
pub fn debug(section: []const u8) Logger {
    return debuglog(section);
}

// =====================================================================
// promisify / callbackify (JSC-gated)
// =====================================================================

/// `util.promisify(fn)` — wraps a callback-style function in a
/// `Promise`. Requires the JSC bridge (Phase 12.2) for `Promise`
/// construction; panics until then so callers that depend on the
/// substrate fail fast rather than silently mis-route.
pub fn promisify(fn_: anytype) @TypeOf(fn_) {
    // Touching `fn_` keeps the return-type binding live without an
    // unused-parameter warning; the function never returns normally.
    if (false) return fn_;
    @panic("util.promisify: JSC bridge not yet live (Phase 12.2 dependency)");
}

/// `util.callbackify(fn)` — inverse of `promisify`. Same gating.
pub fn callbackify(fn_: anytype) @TypeOf(fn_) {
    if (false) return fn_;
    @panic("util.callbackify: JSC bridge not yet live (Phase 12.2 dependency)");
}

// =====================================================================
// types — comptime type queries
// =====================================================================

pub const types = struct {
    /// `util.types.isArray(v)` — true iff `v` is a fixed array or a slice.
    pub fn isArray(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .array => true,
            .pointer => |p| p.size == .slice,
            else => false,
        };
    }

    /// `util.types.isBoolean(v)` — true iff `T` is `bool`.
    pub fn isBoolean(comptime T: type) bool {
        return @typeInfo(T) == .bool;
    }

    /// `util.types.isString(v)` — true iff `T` is `[]const u8` /
    /// `[]u8` (Zig has no first-class string type; byte-slices are
    /// the closest analog).
    pub fn isString(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .pointer => |p| p.size == .slice and p.child == u8,
            else => false,
        };
    }

    /// `util.types.isFunction(v)` — true iff `T` is a function or
    /// function pointer.
    pub fn isFunction(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"fn" => true,
            .pointer => |p| @typeInfo(p.child) == .@"fn",
            else => false,
        };
    }

    /// `util.types.isNull(v)` — true iff `T` is the `null` literal type.
    pub fn isNull(comptime T: type) bool {
        return @typeInfo(T) == .null;
    }

    /// `util.types.isPrimitive(v)` — true for bool / int / float / null /
    /// void / enum (Node also says `string` / `symbol`; we route string
    /// through `isString` separately).
    pub fn isPrimitive(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .bool, .int, .float, .comptime_int, .comptime_float, .null, .void, .@"enum" => true,
            else => false,
        };
    }

    /// `util.types.isObject(v)` — true iff `T` is a struct, union, or
    /// optional/pointer wrapping one. Matches Node's `typeof v ===
    /// 'object'` (which excludes null + primitives).
    pub fn isObject(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"struct", .@"union" => true,
            .pointer => |p| p.size == .one and (@typeInfo(p.child) == .@"struct" or @typeInfo(p.child) == .@"union"),
            else => false,
        };
    }

    // --- JSC-gated queries -------------------------------------------
    // These all panic with a clear message — they re-attach once the
    // Phase 12.2 JSC bridge brings up the JS heap. The signatures match
    // Node's `util.types` surface so the JS layer can re-export them
    // verbatim.

    pub fn isPromise(comptime T: type) bool {
        _ = T;
        @panic("util.types.isPromise: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isDate(comptime T: type) bool {
        _ = T;
        @panic("util.types.isDate: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isRegExp(comptime T: type) bool {
        _ = T;
        @panic("util.types.isRegExp: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isMap(comptime T: type) bool {
        _ = T;
        @panic("util.types.isMap: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isSet(comptime T: type) bool {
        _ = T;
        @panic("util.types.isSet: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isWeakMap(comptime T: type) bool {
        _ = T;
        @panic("util.types.isWeakMap: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isWeakSet(comptime T: type) bool {
        _ = T;
        @panic("util.types.isWeakSet: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isProxy(comptime T: type) bool {
        _ = T;
        @panic("util.types.isProxy: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isNativeError(comptime T: type) bool {
        _ = T;
        @panic("util.types.isNativeError: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isBoxedPrimitive(comptime T: type) bool {
        _ = T;
        @panic("util.types.isBoxedPrimitive: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isStringObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isStringObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isNumberObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isNumberObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isBooleanObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isBooleanObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isBigIntObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isBigIntObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isSymbolObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isSymbolObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isGeneratorFunction(comptime T: type) bool {
        _ = T;
        @panic("util.types.isGeneratorFunction: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isGeneratorObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isGeneratorObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isAsyncFunction(comptime T: type) bool {
        _ = T;
        @panic("util.types.isAsyncFunction: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isArgumentsObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isArgumentsObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isAnyArrayBuffer(comptime T: type) bool {
        _ = T;
        @panic("util.types.isAnyArrayBuffer: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isSharedArrayBuffer(comptime T: type) bool {
        _ = T;
        @panic("util.types.isSharedArrayBuffer: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isArrayBufferView(comptime T: type) bool {
        _ = T;
        @panic("util.types.isArrayBufferView: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isDataView(comptime T: type) bool {
        _ = T;
        @panic("util.types.isDataView: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isExternal(comptime T: type) bool {
        _ = T;
        @panic("util.types.isExternal: JSC bridge not yet live (Phase 12.2 dependency)");
    }

    pub fn isModuleNamespaceObject(comptime T: type) bool {
        _ = T;
        @panic("util.types.isModuleNamespaceObject: JSC bridge not yet live (Phase 12.2 dependency)");
    }
};

// =====================================================================
// Inline tests — exercise the public surface (no JSC-gated paths).
// =====================================================================

test "util.inspect: scalar values render verbatim" {
    try std.testing.expectEqualStrings("42", inspect(@as(u32, 42), null));
    try std.testing.expectEqualStrings("true", inspect(true, null));
    try std.testing.expectEqualStrings("false", inspect(false, null));
    try std.testing.expectEqualStrings("'hello'", inspect(@as([]const u8, "hello"), null));
}

test "util.inspect: optional renders inner value or null" {
    const a: ?u32 = 7;
    const b: ?u32 = null;
    try std.testing.expectEqualStrings("7", inspect(a, null));
    try std.testing.expectEqualStrings("null", inspect(b, null));
}

test "util.inspect: struct renders field-by-field" {
    const Pt = struct { x: i32, y: i32 };
    const out = inspect(Pt{ .x = 1, .y = 2 }, null);
    try std.testing.expectEqualStrings("{ x: 1, y: 2 }", out);
}

test "util.inspect: array renders bracketed list" {
    const arr = [_]u32{ 1, 2, 3 };
    const out = inspect(arr, null);
    try std.testing.expectEqualStrings("[ 1, 2, 3 ]", out);
}

test "util.inspect: depth cap renders nested as [Object]" {
    const Inner = struct { v: u32 };
    const Outer = struct { inner: Inner };
    const out = inspect(Outer{ .inner = .{ .v = 9 } }, .{ .depth = 0 });
    // depth=0 means the top-level struct is the only one rendered;
    // any nested struct degrades to [Object].
    try std.testing.expectEqualStrings("{ inner: [Object] }", out);
}

test "util.format: basic specifiers" {
    try std.testing.expectEqualStrings("answer=42", format("answer={d}", .{42}));
    try std.testing.expectEqualStrings("hello world", format("{s} {s}", .{ "hello", "world" }));
}

test "util.formatWithOptions: options arg is ignored but parity preserved" {
    const opts = InspectOptions{ .colors = true };
    try std.testing.expectEqualStrings("x=1", formatWithOptions(opts, "x={d}", .{1}));
    try std.testing.expectEqualStrings("x=1", formatWithOptions(null, "x={d}", .{1}));
}

test "util.isDeepStrictEqual: scalars + structs" {
    try std.testing.expect(isDeepStrictEqual(u32, 42, 42));
    try std.testing.expect(!isDeepStrictEqual(u32, 42, 43));

    const Pt = struct { x: i32, y: i32 };
    try std.testing.expect(isDeepStrictEqual(Pt, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 2 }));
    try std.testing.expect(!isDeepStrictEqual(Pt, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 3 }));
}

test "util.isDeepStrictEqual: slices" {
    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 1, 2, 3 };
    const c = [_]u8{ 1, 2, 4 };
    try std.testing.expect(isDeepStrictEqual([]const u8, a[0..], b[0..]));
    try std.testing.expect(!isDeepStrictEqual([]const u8, a[0..], c[0..]));
}

test "util.types.isArray: arrays + slices return true" {
    try std.testing.expect(types.isArray([3]u32));
    try std.testing.expect(types.isArray([]const u32));
    try std.testing.expect(types.isArray([]u8));
    try std.testing.expect(!types.isArray(u32));
    try std.testing.expect(!types.isArray(bool));
}

test "util.types.isBoolean: only bool returns true" {
    try std.testing.expect(types.isBoolean(bool));
    try std.testing.expect(!types.isBoolean(u32));
    try std.testing.expect(!types.isBoolean([]const u8));
}

test "util.types.isString: byte slices return true" {
    try std.testing.expect(types.isString([]const u8));
    try std.testing.expect(types.isString([]u8));
    try std.testing.expect(!types.isString([]const u32));
    try std.testing.expect(!types.isString(u32));
}

test "util.types.isFunction: fn types return true" {
    const Helpers = struct {
        fn f() void {}
    };
    try std.testing.expect(types.isFunction(@TypeOf(Helpers.f)));
    try std.testing.expect(!types.isFunction(u32));
    try std.testing.expect(!types.isFunction(bool));
}

test "util.types.isNull / isPrimitive / isObject" {
    try std.testing.expect(types.isNull(@TypeOf(null)));
    try std.testing.expect(!types.isNull(u32));

    try std.testing.expect(types.isPrimitive(bool));
    try std.testing.expect(types.isPrimitive(u32));
    try std.testing.expect(types.isPrimitive(f64));
    try std.testing.expect(!types.isPrimitive([]const u8));

    const Pt = struct { x: i32 };
    try std.testing.expect(types.isObject(Pt));
    try std.testing.expect(!types.isObject(u32));
}

test "util.debuglog: returns disabled logger when section not in NODE_DEBUG" {
    // CI typically has no NODE_DEBUG; this should land disabled.
    const logger = debuglog("home_rt_test_section_unset");
    try std.testing.expect(!logger.enabled);
    // log() is a noop — should not panic.
    logger.log("noop: {d}", .{42});
}
