// Copied from bun/src/bun_alloc/memory.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.
//
// Imports rewritten: `@import("bun")` -> `@import("home")`.
// The allocator helpers are wired through Home's runtime facade while keeping
// the same public memory utility surface for downstream Bun leaves.

//! Basic utilities for working with memory and objects.

/// Allocates memory for a value of type `T` using the provided allocator, and initializes the
/// memory with `value`.
///
/// Mirrors Bun's memory helper API for Home runtime callers.
pub fn create(comptime T: type, allocator: std.mem.Allocator, value: T) home_rt.OOM!*T {
    const ptr = try allocator.create(T);
    ptr.* = value;
    return ptr;
}

/// Frees memory previously allocated by `create`.
///
/// The memory must have been allocated by the `create` function in this namespace, not
/// directly by `allocator.create`.
pub fn destroy(allocator: std.mem.Allocator, ptr: anytype) void {
    allocator.destroy(ptr);
}

/// Default-initializes a value of type `T`.
///
/// This method tries the following, in order:
///
/// * `.initDefault()`, if a method with that name exists
/// * `.init()`, if a method with that name exists
/// * `.{}`, otherwise
pub fn initDefault(comptime T: type) T {
    return if (comptime std.meta.hasFn(T, "initDefault"))
        .initDefault()
    else if (comptime std.meta.hasFn(T, "init"))
        .init()
    else
        .{};
}

/// Returns true if `T` should not be required to have a `deinit` method.
///
/// This method is primarily for external types where a `deinit` method can't be added.
/// For other types, prefer adding a `deinit` method or adding `pub const deinit = void;` if
/// possible.
fn exemptedFromDeinit(comptime T: type) bool {
    return switch (T) {
        std.mem.Allocator => true,
        else => {
            _ = T.deinit; // no deinit method? add one, set to void, or add an exemption
            return false;
        },
    };
}

fn deinitIsVoid(comptime T: type) bool {
    return switch (@TypeOf(T.deinit)) {
        type => T.deinit == void,
        void => true,
        else => false,
    };
}

/// Calls `deinit` on `ptr_or_slice`, or on every element of `ptr_or_slice`, if the pointer points
/// to a struct or tagged union.
///
/// This function first does the following:
///
/// * If `ptr_or_slice` is a single-item pointer of type `*T`:
///   - If `T` is a struct or tagged union, calls `ptr_or_slice.deinit()`
///   - If `T` is an optional, checks if `ptr_or_slice` points to a non-null value, and if so,
///     calls `home_rt.memory.deinit` with a pointer to the payload.
/// * If `ptr_or_slice` is a slice, for each element of the slice, calls `home_rt.memory.deinit` with
///   a pointer to the element.
///
/// Then, if `ptr_or_slice` is non-const, this function also sets all memory referenced by the
/// pointer to `undefined`.
///
/// This method does not free `ptr_or_slice` itself.
pub fn deinit(ptr_or_slice: anytype) void {
    const PtrType = @TypeOf(ptr_or_slice);
    const ptr_info = @typeInfo(PtrType);
    switch (comptime ptr_info.pointer.size) {
        .slice => {
            for (ptr_or_slice) |*elem| {
                deinit(elem);
            }
            return;
        },
        .one => {},
        else => @compileError("unsupported pointer type: " ++ @typeName(PtrType)),
    }

    const Child = ptr_info.pointer.child;
    const mutable = !ptr_info.pointer.attrs.@"const";
    defer {
        if (comptime mutable) {
            ptr_or_slice.* = undefined;
        }
    }

    switch (comptime @typeInfo(Child)) {
        .void, .bool, .int, .float, .pointer, .comptime_float, .comptime_int => return,
        .undefined, .null, .error_set, .@"enum", .vector => return,
        .array => {
            for (ptr_or_slice) |*elem| {
                deinit(elem);
            }
            return;
        },
        .@"struct" => {},
        .optional => {
            if (ptr_or_slice.*) |*payload| {
                deinit(payload);
            }
            return;
        },
        .error_union => {
            if (ptr_or_slice.*) |*payload| {
                deinit(payload);
            } else |_| {}
            return;
        },
        .@"union" => |u| {
            if (comptime u.tag_type == null) {
                @compileError("cannot deinit an untagged union: " ++ @typeName(Child));
            }
        },
        .type, .noreturn, .@"fn", .@"opaque", .frame, .@"anyframe", .enum_literal, .spirv => {
            @compileError("unsupported type for deinit: " ++ @typeName(Child));
        },
    }

    if (comptime !exemptedFromDeinit(Child) and !deinitIsVoid(Child)) {
        ptr_or_slice.deinit();
    }
}

/// Rebase a slice from one memory buffer to another buffer.
///
/// Given a slice which points into a memory buffer with base `old_base`, return
/// a slice which points to the same offset in a new memory buffer with base
/// `new_base`, preserving the length of the slice.
///
///
/// ```
/// const old_base = [6]u8{};
/// assert(@ptrToInt(&old_base) == 0x32);
///
///            0x32 0x33 0x34 0x35 0x36 0x37
/// old_base |????|????|????|????|????|????|
///                    ^
///                    |<-- slice --->|
///
/// const new_base = [6]u8{};
/// assert(@ptrToInt(&new_base) == 0x74);
/// const output = rebaseSlice(slice, old_base, new_base)
///
///            0x74 0x75 0x76 0x77 0x78 0x79
/// new_base |????|????|????|????|????|????|
///                    ^
///                    |<-- output -->|
/// ```
pub fn rebaseSlice(slice: []const u8, old_base: [*]const u8, new_base: [*]const u8) []const u8 {
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(old_base);
    return new_base[offset..][0..slice.len];
}

/// Removes the sentinel from a sentinel-terminated slice or many-item pointer. The resulting
/// non-sentinel-terminated slice can be freed with `allocator.free`.
///
/// `ptr` must be `[:x]T` or `[*:x]T`, or their const equivalents, and it must have been allocated
/// by `allocator`.
///
/// Most allocators will perform this operation without allocating any memory, but unlike a simple
/// cast, this function will not cause issues with allocators that need to know the exact size of
/// the allocation to free it.
pub fn dropSentinel(ptr: anytype, allocator: std.mem.Allocator) home_rt.OOM!DropSentinel(@TypeOf(ptr)) {
    const info = @typeInfo(@TypeOf(ptr)).pointer;
    const Child = info.child;
    if (comptime info.sentinel_ptr == null) {
        @compileError("pointer must have sentinel");
    }

    const slice = switch (comptime info.size) {
        .many => std.mem.span(ptr),
        .slice => ptr,
        else => @compileError("only slices and many-item pointers are supported"),
    };
    const unsentinel: DropSentinel(@TypeOf(ptr)) = slice[0..slice.len];
    const allocated = switch (comptime info.size) {
        .many => ptr[0 .. slice.len + 1],
        .slice => ptr.ptr[0 .. slice.len + 1],
        else => unreachable,
    };

    if (allocator.remap(@constCast(allocated), unsentinel.len)) |new| return new;
    defer allocator.free(@constCast(allocated));
    return allocator.dupe(Child, unsentinel);
}

fn DropSentinel(comptime Ptr: type) type {
    const info = @typeInfo(Ptr).pointer;
    return if (info.attrs.@"const") []const info.child else []info.child;
}

const std = @import("std");
const bun = @import("bun");
const Allocator = std.mem.Allocator;

const home_rt = @import("home");

test "memory: create initializes and destroy frees" {
    const Payload = struct {
        a: u32,
        b: []const u8,
    };

    const ptr = try create(Payload, std.testing.allocator, .{ .a = 42, .b = "home" });
    defer destroy(std.testing.allocator, ptr);

    try std.testing.expectEqual(@as(u32, 42), ptr.a);
    try std.testing.expectEqualStrings("home", ptr.b);
}

test "memory: initDefault prefers initDefault then init then empty" {
    const WithInitDefault = struct {
        value: u8,
        pub fn initDefault() @This() {
            return .{ .value = 1 };
        }
    };
    const WithInit = struct {
        value: u8,
        pub fn init() @This() {
            return .{ .value = 2 };
        }
    };
    const Empty = struct {};

    try std.testing.expectEqual(@as(u8, 1), initDefault(WithInitDefault).value);
    try std.testing.expectEqual(@as(u8, 2), initDefault(WithInit).value);
    try std.testing.expectEqual(Empty{}, initDefault(Empty));
}

test "memory: deinit handles optionals and slices" {
    const Item = struct {
        count: *usize,

        pub fn deinit(self: *@This()) void {
            self.count.* += 1;
        }
    };

    var count: usize = 0;
    var maybe: ?Item = .{ .count = &count };
    deinit(&maybe);
    try std.testing.expectEqual(@as(usize, 1), count);

    var items = [_]Item{
        .{ .count = &count },
        .{ .count = &count },
    };
    deinit(items[0..]);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "memory: dropSentinel returns a freeable slice" {
    const allocator = std.testing.allocator;
    const value = try bun.dupeZ(allocator, u8, "home");
    const slice = try dropSentinel(value, allocator);
    defer allocator.free(slice);

    try std.testing.expectEqualStrings("home", slice);
}
