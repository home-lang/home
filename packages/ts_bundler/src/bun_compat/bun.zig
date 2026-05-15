//! Tier 0 `bun` compat shim — Phase 4.5 §4.5.A.2.
//!
//! Re-exports the minimal surface the vendored Bun bundler source
//! needs to compile against Home's stdlib + ts-bundler internals.
//! The full external `bun.X` surface is 103 unique identifiers; this
//! file covers the seven Tier 0 symbols required by
//! `bun/IndexStringMap.zig` (25 LOC, 2 refs) and `bun/PathToSourceIndexMap.zig`
//! (46 LOC, 8 refs):
//!
//!   * `OOM`                — `error{OutOfMemory}` alias for explicit
//!                            error-return signatures
//!                            (`bun.OOM!void`).
//!   * `handleOom`          — convert an OOM error into a panic for
//!                            call sites that can't propagate.
//!   * `default_allocator`  — process-wide allocator. Re-exports
//!                            `std.heap.smp_allocator`.
//!   * `assert`             — alias for `std.debug.assert`.
//!   * `ast.Index`          — index newtype with a `.Int` (u32)
//!                            integer companion.
//!   * `StringHashMapUnmanaged` — alias for the std-lib generic.
//!   * `fs.Path`            — slot for an interned path; only the
//!                            `text: []const u8` field is exercised
//!                            by Tier 0 files.
//!
//! Each tier in `PORTING_STATUS.md` adds more surface. Subsequent
//! tiers will extend this file (or split into siblings under
//! `bun_compat/`) rather than maintain a separate import alias.

const std = @import("std");

pub const OOM = error{OutOfMemory};

pub fn handleOom(err: anyerror) noreturn {
    _ = err;
    @panic("bun_compat: out of memory");
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
    /// Path record. Tier 0 callers (`PathToSourceIndexMap.getPath` /
    /// `putPath`) read only `.text`; subsequent tiers will grow the
    /// struct (namespace, pretty path, interned id, …) as they need.
    pub const Path = struct {
        text: []const u8,
    };
};
