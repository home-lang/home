// Copied from bun/src/bun_alloc/NullableAllocator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// A nullable wrapper around `std.mem.Allocator` that uses the
// null-pointer optimization on the vtable so the entire struct stays
// the same size as a regular Allocator (16 bytes on 64-bit). Upstream
// uses this in places where an allocator is sometimes absent (e.g. a
// `String` that may or may not own its bytes).
//
// Imports rewritten: `@import("bun")` → `@import("home_rt")`.
// `bun.String.isWTFAllocator` is stubbed to always return false until
// `home_rt.String` lands in Phase 12.2 (the WTF allocator is the JSC
// engine's per-thread `WTF::StringImpl` allocator; until that bridge is
// up there are no WTF allocators in flight). The `free` path
// consequently always uses `allocator.free(...)`. Updated stub will be
// a single-line edit once `home_rt.String.isWTFAllocator` exists.
// JSC-bridge omitted — re-lands in Phase 12.2.

//! A nullable allocator the same size as `std.mem.Allocator`.

const NullableAllocator = @This();

ptr: *anyopaque = undefined,
// Utilize the null pointer optimization on the vtable instead of
// the regular `ptr` because `ptr` may be undefined.
vtable: ?*const std.mem.Allocator.VTable = null,

pub inline fn init(allocator: ?std.mem.Allocator) NullableAllocator {
    return if (allocator) |a| .{
        .ptr = a.ptr,
        .vtable = a.vtable,
    } else .{};
}

pub inline fn isNull(this: NullableAllocator) bool {
    return this.vtable == null;
}

pub inline fn isWTFAllocator(this: NullableAllocator) bool {
    _ = this;
    // home_rt.String.isWTFAllocator stub — Phase 12.2 wire-up.
    return false;
}

pub inline fn get(this: NullableAllocator) ?std.mem.Allocator {
    return if (this.vtable) |vt| std.mem.Allocator{ .ptr = this.ptr, .vtable = vt } else null;
}

pub fn free(this: *const NullableAllocator, bytes: []const u8) void {
    if (this.get()) |allocator| {
        // JSC-bridge: WTFAllocator fast-path omitted — re-lands in Phase 12.2
        // when `home_rt.String.isWTFAllocator` becomes a real check.
        allocator.free(bytes);
    }
}

comptime {
    if (@sizeOf(NullableAllocator) != @sizeOf(std.mem.Allocator)) {
        @compileError("Expected the sizes to be the same.");
    }
}

const home_rt = @import("home_rt");
const std = @import("std");

test "NullableAllocator: null and round-trip" {
    const empty = NullableAllocator.init(null);
    try std.testing.expect(empty.isNull());
    try std.testing.expect(empty.get() == null);

    const nullable = NullableAllocator.init(std.testing.allocator);
    try std.testing.expect(!nullable.isNull());
    try std.testing.expect(nullable.get() != null);

    // WTFAllocator detection is stubbed to false in Phase 12 substrate.
    try std.testing.expect(!nullable.isWTFAllocator());
}

test "NullableAllocator: free round-trips through inner allocator" {
    const wrapper = NullableAllocator.init(std.testing.allocator);
    const bytes = try std.testing.allocator.alloc(u8, 8);
    wrapper.free(bytes);

    // Null wrapper: free is a no-op.
    const empty = NullableAllocator.init(null);
    empty.free("nope"); // does not crash
}

test "NullableAllocator: same size as std.mem.Allocator" {
    try std.testing.expectEqual(@sizeOf(std.mem.Allocator), @sizeOf(NullableAllocator));
}
