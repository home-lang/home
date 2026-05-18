//! Home Runtime — ported from Bun `src/safety/alloc.zig` (upstream SHA pinned in
//! `home_rt.upstream_sha`). Trimmed port: this file keeps the public
//! `CheckedAllocator` API surface so callers (notably `MultiArrayList`,
//! `BabyList`, etc.) compile unchanged, but the safety machinery is
//! gated to **disabled mode** until Home grows its own allocator
//! catalogue (`MimallocArena`, `LinuxMemFdAllocator`, `NullableAllocator`,
//! and the JSC `CachedBytecode` / WTF / heap-breakdown introspection
//! hooks that the upstream `hasPtr` / `guaranteedMismatch` path consults).
//!
//! Concretely:
//!   * `enabled` is wired to `home_rt.Environment.ci_assert`, which today
//!     evaluates to `false` (see `environment.zig`). When the flag is
//!     `false`, every method short-circuits to a no-op — matching what
//!     upstream Bun does in release builds.
//!   * `assertEq` / `assertEqFmt` accept any two `Allocator` values
//!     and (in disabled mode) return without inspecting them. When the
//!     allocator catalogue lands, we can lift the upstream `hasPtr`
//!     table verbatim into this file behind `enabled`.
//!   * `CheckedAllocator` stores the captured allocator as
//!     `?std.mem.Allocator` (instead of upstream's `NullableAllocator`
//!     packed pointer optimization) because Home doesn't have
//!     `NullableAllocator` yet. Layout-equivalent semantics; just a
//!     larger field in `enabled` mode.
//!
//! Once `home_rt.allocators.*` lands, swap the four marked TODOs to
//! match upstream behavior bit-for-bit.

const std = @import("std");
const home_rt = @import("home_rt");
const Allocator = std.mem.Allocator;

/// Mirror of upstream `bun.Environment.ci_assert`. Home's environment.zig
/// doesn't expose `ci_assert` yet; we conservatively keep it `false` so
/// the entire safety path compiles to a no-op (matching what upstream
/// does in release builds).
pub const enabled: bool = false;

/// Asserts that two allocators are equal. In disabled mode this is a
/// no-op — see file-level docs for the catalogue work needed to enable
/// the full check.
pub fn assertEq(alloc1: Allocator, alloc2: Allocator) void {
    _ = alloc1;
    _ = alloc2;
    if (comptime !enabled) return;
    // TODO: vtable + hasPtr-table compare, see upstream alloc.zig.
}

/// Asserts that two allocators are equal, with a formatted message.
pub fn assertEqFmt(
    alloc1: Allocator,
    alloc2: Allocator,
    comptime format: []const u8,
    args: anytype,
) void {
    _ = alloc1;
    _ = alloc2;
    _ = format;
    _ = args;
    if (comptime !enabled) return;
}

/// Use this in unmanaged containers to ensure multiple allocators aren't
/// being used with the same container. Each method of the container that
/// accepts an allocator parameter should call either `set` (for non-const
/// methods) or `assertEq` (for const methods).
///
/// In disabled mode (today's Home) the type carries zero fields and every
/// method compiles to a no-op, exactly matching what upstream Bun does in
/// release builds. The public method surface is identical so callers
/// don't need conditionals.
pub const CheckedAllocator = struct {
    const Self = @This();

    /// Stored allocator. `void` in disabled mode to keep `@sizeOf == 0`.
    stored: if (enabled) ?Allocator else void = if (enabled) null else {},

    pub inline fn init(alloc: Allocator) Self {
        var self: Self = .{};
        self.set(alloc);
        return self;
    }

    pub fn set(self: *Self, alloc: Allocator) void {
        if (comptime !enabled) return;
        if (self.stored == null) {
            self.stored = alloc;
        } else {
            self.assertEq(alloc);
        }
    }

    pub fn assertEq(self: Self, alloc: Allocator) void {
        _ = self;
        _ = alloc;
        if (comptime !enabled) return;
        // TODO: re-enable once allocator catalogue lands.
    }

    /// Transfers ownership of the collection to a new allocator.
    ///
    /// Valid only when both allocators are `MimallocArena`s upstream;
    /// in Home this is a no-op until that allocator lands.
    pub inline fn transferOwnership(self: *Self, new_allocator: anytype) void {
        _ = self;
        _ = new_allocator;
        if (comptime !enabled) return;
        // TODO: port full transferOwnership once MimallocArena lands.
    }
};

test "home_rt.safety.alloc: CheckedAllocator init+set compile in disabled mode" {
    var checked = CheckedAllocator{};
    checked.set(std.testing.allocator);
    checked.assertEq(std.testing.allocator);
    // Confirm zero-sized in disabled mode (matches upstream debug-off layout).
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(CheckedAllocator));
}

test "home_rt.safety.alloc: assertEq is a no-op when disabled" {
    assertEq(std.testing.allocator, std.testing.allocator);
    assertEqFmt(std.testing.allocator, std.testing.allocator, "msg", .{});
}
