//! Tier 0 `bun` compat shim.
//!
//! Re-exports the minimal surface that vendored Bun source needs to
//! compile against Home's stdlib. Originally landed as
//! `bundler/src/compat/bun.zig` during the Phase 4.5 §4.5.A.2
//! work; promoted to a top-level package because `bundler` IS the
//! Bun-flavoured TS/JS bundler and the bun-runtime surface lives next
//! to it as a peer rather than as an inner shim.
//!
//! The full external `bun.X` surface is 103 unique identifiers; this
//! file covers the seven Tier 0 symbols originally required by the
//! `IndexStringMap.zig` / `PathToSourceIndexMap.zig` Bun-bundler
//! vendors:
//!
//!   * `OOM`                — `error{OutOfMemory}` alias for explicit
//!                            error-return signatures (`bun.OOM!void`).
//!   * `handleOom`          — unwrap OOM-returning calls or convert an
//!                            OOM into a panic for call sites that
//!                            can't propagate.
//!   * `default_allocator`  — process-wide allocator. Re-exports
//!                            `std.heap.smp_allocator`.
//!   * `assert`             — alias for `std.debug.assert`.
//!   * `ast.Index`          — index newtype with a `.Int` (u32)
//!                            integer companion.
//!   * `StringHashMapUnmanaged` — alias for the std-lib generic.
//!   * `strings.isValidUTF8` — UTF-8 validation helper for copied diff
//!                             formatting code.
//!   * `fs.Path`            — slot for an interned path; only the
//!                            `text: []const u8` field is exercised
//!                            by Tier 0 callers.
//!
//! Each subsequent tier adds more surface as additional Bun source
//! files come online in `bundler` / `runtime`.

const std = @import("std");
const builtin = @import("builtin");
const T = std.testing;

pub const OOM = error{OutOfMemory};
pub const JSError = error{ JSException, OutOfMemory };

pub const Environment = struct {
    pub const ci_assert = false;
    pub const isDebug = builtin.mode == .Debug;
    pub const isWindows = builtin.os.tag == .windows;
    pub const isMac = builtin.os.tag == .macos;
};

fn HandleOomReturn(comptime TArg: type) type {
    return switch (@typeInfo(TArg)) {
        .error_union => |info| info.payload,
        .error_set => noreturn,
        else => @compileError("bun.handleOom expects an error union value or error"),
    };
}

pub fn handleOom(result: anytype) HandleOomReturn(@TypeOf(result)) {
    return switch (@typeInfo(@TypeOf(result))) {
        .error_union => result catch |err| {
            @panic(@errorName(err));
        },
        .error_set => @panic(@errorName(result)),
        else => unreachable,
    };
}

pub const default_allocator: std.mem.Allocator = std.heap.smp_allocator;

pub const assert = std.debug.assert;

pub fn debugAssert(ok: bool) void {
    if (builtin.mode == .Debug) std.debug.assert(ok);
}

pub fn create(allocator: std.mem.Allocator, comptime TArg: type, value: TArg) *TArg {
    const ptr = handleOom(allocator.create(TArg));
    ptr.* = value;
    return ptr;
}

pub const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

pub const strings = struct {
    pub fn isValidUTF8(input: []const u8) bool {
        return std.unicode.utf8ValidateSlice(input);
    }
};

pub const ast = struct {
    /// Strongly-typed source-file / module index. Upstream Bun stores
    /// the raw integer separately as `Index.Int` so callers can pass
    /// the unwrapped `u32` through hot-path collections without paying
    /// for the struct wrapper. We mirror that split here.
    pub const Index = struct {
        pub const Int = u32;
        value: Int,

        pub fn init(value: Int) Index {
            return .{ .value = value };
        }
    };
};

pub const fs = struct {
    /// Path record. Tier 0 callers read only `.text`; subsequent
    /// tiers will grow the struct (namespace, pretty path, interned
    /// id, …) as they need.
    pub const Path = struct {
        text: []const u8,
    };
};

test "compat: Tier 0 surface is well-shaped" {
    try T.expectEqual(@as(type, error{OutOfMemory}), OOM);
    try T.expectEqual(@as(type, error{ JSException, OutOfMemory }), JSError);
    assert(true);
    debugAssert(true);
    try T.expect(!Environment.ci_assert);
    try T.expectEqual(@as(type, u32), ast.Index.Int);
    const path = fs.Path{ .text = "/x.ts" };
    try T.expectEqualStrings("/x.ts", path.text);
    const slice = try default_allocator.alloc(u8, 4);
    defer default_allocator.free(slice);
    try T.expectEqual(@as(usize, 4), slice.len);
}

test "compat: ast.Index.init wraps + reads u32" {
    const idx = ast.Index.init(7);
    try T.expectEqual(@as(u32, 7), idx.value);
}

test "compat: StringHashMapUnmanaged alias works" {
    var map: StringHashMapUnmanaged(u32) = .{};
    defer map.deinit(T.allocator);
    try map.put(T.allocator, "a", 1);
    try map.put(T.allocator, "b", 2);
    try T.expectEqual(@as(?u32, 1), map.get("a"));
    try T.expectEqual(@as(?u32, 2), map.get("b"));
    try T.expectEqual(@as(?u32, null), map.get("c"));
}

test "compat: handleOom unwraps successful error unions" {
    const value: OOM!u32 = 42;
    try T.expectEqual(@as(u32, 42), handleOom(value));
}

test "compat: create allocates and initializes a value" {
    const ptr = create(T.allocator, u32, 9);
    defer T.allocator.destroy(ptr);
    try T.expectEqual(@as(u32, 9), ptr.*);
}

test "compat: strings validates UTF-8" {
    try T.expect(strings.isValidUTF8("hello"));
    try T.expect(!strings.isValidUTF8(&.{0xff}));
}
