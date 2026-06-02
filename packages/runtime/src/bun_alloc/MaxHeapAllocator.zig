// Copied from bun/src/bun_alloc/MaxHeapAllocator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Single-allocation arena: every `alloc` resets the underlying list to
// length zero, then grows the backing storage to fit the request. There
// is no `resize` — calls panic — and `free` is a no-op since the next
// `alloc` reclaims the slot. Used by upstream for tiny per-call scratch
// buffers where the caller never needs more than one live allocation at
// a time.
//
// Imports rewritten: `@import("bun")` → `@import("home")`,
// `bun.assert` → `home_rt.assert`, `bun.cast` → `home_rt.cast`.
// No JSC bridge.

//! Single allocation only.

const Self = @This();

array_list: std.array_list.AlignedManaged(u8, .of(std.c.max_align_t)),

fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    home_rt.assert(alignment.toByteUnits() <= @alignOf(std.c.max_align_t));
    var self = home_rt.cast(*Self, ptr);
    self.array_list.items.len = 0;
    self.array_list.ensureTotalCapacity(len) catch return null;
    self.array_list.items.len = len;
    return self.array_list.items.ptr;
}

fn resize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    _ = new_len;
    _ = buf;
    @panic("not implemented");
}

fn free(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {}

pub fn reset(self: *Self) void {
    self.array_list.items.len = 0;
}

pub fn deinit(self: *Self) void {
    self.array_list.deinit();
}

const vtable = std.mem.Allocator.VTable{
    .alloc = &alloc,
    .free = &free,
    .resize = &resize,
    .remap = &std.mem.Allocator.noRemap,
};

pub fn init(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator {
    self.array_list = .init(allocator);

    return std.mem.Allocator{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn isInstance(allocator: std.mem.Allocator) bool {
    return allocator.vtable == &vtable;
}

const home_rt = @import("home");
const std = @import("std");

test "MaxHeapAllocator: single-allocation arena reuses storage" {
    var arena: Self = undefined;
    const a = arena.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect(Self.isInstance(a));

    // First allocation grows the backing array.
    const first = try a.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 16), first.len);
    @memset(first, 0xAA);

    // Second allocation resets length to zero — the previous slice is
    // logically invalidated and the new allocation starts at offset 0.
    const second = try a.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), second.len);

    // reset() just zeros the length.
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.array_list.items.len);
}

test "MaxHeapAllocator: isInstance distinguishes its allocators" {
    var arena: Self = undefined;
    const a = arena.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(Self.isInstance(a));
    try std.testing.expect(!Self.isInstance(std.testing.allocator));
}
