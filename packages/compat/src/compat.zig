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
//!   * `handleOom`          — convert an OOM into a panic for call
//!                            sites that can't propagate.
//!   * `default_allocator`  — process-wide allocator. Re-exports
//!                            `std.heap.smp_allocator`.
//!   * `assert`             — alias for `std.debug.assert`.
//!   * `ast.Index`          — index newtype with a `.Int` (u32)
//!                            integer companion.
//!   * `StringHashMapUnmanaged` — alias for the std-lib generic.
//!   * `fs.Path`            — slot for an interned path; only the
//!                            `text: []const u8` field is exercised
//!                            by Tier 0 callers.
//!
//! Each subsequent tier adds more surface as additional Bun source
//! files come online in `bundler` / `runtime`.

const std = @import("std");
const T = std.testing;

pub const OOM = error{OutOfMemory};

pub fn handleOom(err: anyerror) noreturn {
    _ = err;
    @panic("compat: out of memory");
}

pub const default_allocator: std.mem.Allocator = std.heap.smp_allocator;

pub const assert = std.debug.assert;

pub const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

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
    assert(true);
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
