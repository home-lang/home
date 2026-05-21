// Copied from bun/src/bun_alloc/maybe_owned.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.
//
// Imports rewritten: `@import("bun")` -> `@import("home_rt")`.
// The generic allocator facade is exposed through `home_rt.allocators` so this
// Bun allocator leaf participates in Home's runtime module graph.

/// This type models allocator state for values that can be either owned or borrowed:
///
/// ```
/// // Either forwards to a parent allocator, or is borrowed.
/// const MaybeOwnedStd = home_rt.allocators.MaybeOwned(std.mem.Allocator);
///
/// var owned_alloc = MaybeOwnedStd.initOwned(std.testing.allocator);
/// var borrowed_alloc = MaybeOwnedStd.initBorrowed();
///
/// owned_alloc.deinit(); // deinitializes the parent if it owns resources
/// borrowed_alloc.deinit(); // no-op
/// ```
///
/// This type is a `GenericAllocator`; see `src/allocators.zig`.
pub fn MaybeOwned(comptime Allocator: type) type {
    return struct {
        const Self = @This();

        _parent: home_rt.allocators.Nullable(Allocator),

        /// Same as `.initBorrowed()`. This allocator cannot be used to allocate memory; a panic
        /// will occur.
        pub const borrowed = .initBorrowed();

        /// Creates a `MaybeOwned` allocator that owns memory.
        ///
        /// Allocations are forwarded to a default-initialized `Allocator`.
        pub fn init() Self {
            return .initOwned(defaultParent(Allocator));
        }

        /// Creates a `MaybeOwned` allocator that owns memory, and forwards to a specific
        /// allocator.
        ///
        /// Allocations are forwarded to `parent_alloc`.
        pub fn initOwned(parent_alloc: Allocator) Self {
            return .initRaw(parent_alloc);
        }

        /// Creates a `MaybeOwned` allocator that does not own any memory. This allocator cannot
        /// be used to allocate new memory (a panic will occur), and its implementation of `free`
        /// is a no-op.
        pub fn initBorrowed() Self {
            return .initRaw(null);
        }

        pub fn deinit(self: *Self) void {
            var maybe_parent = self.intoParent();
            if (maybe_parent) |*parent_alloc| {
                home_rt.memory.deinit(parent_alloc);
            }
        }

        pub fn isOwned(self: Self) bool {
            return self.rawParent() != null;
        }

        pub fn allocator(self: Self) std.mem.Allocator {
            const maybe_parent = self.rawParent();
            return if (maybe_parent) |parent_alloc|
                home_rt.allocators.asStd(parent_alloc)
            else
                .{ .ptr = undefined, .vtable = &null_vtable };
        }

        const BorrowedParent = home_rt.allocators.Borrowed(Allocator);

        pub fn parent(self: Self) ?BorrowedParent {
            const maybe_parent = self.rawParent();
            return if (maybe_parent) |parent_alloc|
                home_rt.allocators.borrow(parent_alloc)
            else
                null;
        }

        pub fn intoParent(self: *Self) ?Allocator {
            defer self.* = undefined;
            return self.rawParent();
        }

        /// Used by smart pointer types and allocator wrappers. See `home_rt.allocators.borrow`.
        pub const Borrowed = MaybeOwned(BorrowedParent);

        pub fn borrow(self: Self) Borrowed {
            return .{ ._parent = home_rt.allocators.initNullable(BorrowedParent, self.parent()) };
        }

        fn initRaw(parent_alloc: ?Allocator) Self {
            return .{ ._parent = home_rt.allocators.initNullable(Allocator, parent_alloc) };
        }

        fn rawParent(self: Self) ?Allocator {
            return home_rt.allocators.unpackNullable(Allocator, self._parent);
        }
    };
}

fn defaultParent(comptime Allocator: type) Allocator {
    return if (comptime Allocator == std.mem.Allocator)
        home_rt.default_allocator
    else
        home_rt.memory.initDefault(Allocator);
}

fn nullAlloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = .{ ptr, len, alignment, ret_addr };
    std.debug.panic("cannot allocate with a borrowed `MaybeOwned` allocator", .{});
}

const null_vtable: std.mem.Allocator.VTable = .{
    .alloc = nullAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

const home_rt = @import("home_rt");
const std = @import("std");
const Alignment = std.mem.Alignment;

test "MaybeOwned: borrowed std allocator has no parent" {
    const BorrowedStd = MaybeOwned(std.mem.Allocator);
    const borrowed = BorrowedStd.initBorrowed();

    try std.testing.expect(!borrowed.isOwned());
    try std.testing.expect(borrowed.parent() == null);
}

test "MaybeOwned: owned std allocator forwards allocations" {
    var owned = MaybeOwned(std.mem.Allocator).initOwned(std.testing.allocator);
    defer owned.deinit();

    try std.testing.expect(owned.isOwned());
    try std.testing.expect(owned.parent() != null);

    const allocator = owned.allocator();
    const bytes = try allocator.alloc(u8, 12);
    defer allocator.free(bytes);
    @memset(bytes, 0xC3);

    const expected: [12]u8 = @splat(0xC3);
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "MaybeOwned: borrow keeps std allocator usable without taking ownership" {
    const owned = MaybeOwned(std.mem.Allocator).initOwned(std.testing.allocator);
    const borrowed_view = owned.borrow();

    try std.testing.expect(borrowed_view.isOwned());
    const allocator = borrowed_view.allocator();
    const bytes = try allocator.alloc(u8, 4);
    allocator.free(bytes);
}
