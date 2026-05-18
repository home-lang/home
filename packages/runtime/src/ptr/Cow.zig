// Copied from bun/src/ptr/Cow.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Zig 0.17 compat: `toOwned` snapshots `this.borrowed` into a local before
// reassigning `this.*`; without that, Zig 0.17 RLS schedules the union
// rewrite ahead of the borrowed-field read and trips the active-field safety
// check. No other rewrites; no `@import("bun")` in upstream.

/// Type which could be borrowed or owned
/// The name is from the Rust std's `Cow` type
/// Can't think of a better name
pub fn Cow(comptime T: type, comptime VTable: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice) {
        @compileError("Cow should not be used with slice types. Use CowSlice or CowSliceZ instead.");
    }

    const Handler = struct {
        fn copy(this: *const T, allocator: Allocator) T {
            if (!@hasDecl(VTable, "copy")) @compileError(@typeName(VTable) ++ " needs `copy()` function");
            return VTable.copy(this, allocator);
        }

        fn deinit(this: *T, allocator: Allocator) void {
            if (!@hasDecl(VTable, "deinit")) @compileError(@typeName(VTable) ++ " needs `deinit()` function");
            return VTable.deinit(this, allocator);
        }
    };

    return union(enum) {
        borrowed: *const T,
        owned: T,

        pub fn borrow(val: *const T) @This() {
            return .{
                .borrowed = val,
            };
        }

        pub fn own(val: T) @This() {
            return .{
                .owned = val,
            };
        }

        pub fn replace(this: *@This(), allocator: Allocator, newval: T) void {
            if (this.* == .owned) {
                this.deinit(allocator);
            }
            this.* = .{ .owned = newval };
        }

        /// Get the underlying value.
        pub inline fn inner(this: *const @This()) *const T {
            return switch (this.*) {
                .borrowed => this.borrowed,
                .owned => &this.owned,
            };
        }

        pub inline fn innerMut(this: *@This()) ?*T {
            return switch (this.*) {
                .borrowed => null,
                .owned => &this.owned,
            };
        }

        pub fn toOwned(this: *@This(), allocator: Allocator) *T {
            switch (this.*) {
                .borrowed => {
                    // Zig 0.17 compat: snapshot the borrowed pointer before
                    // reassigning `this.*` — see banner.
                    const borrowed_ptr = this.borrowed;
                    this.* = .{
                        .owned = Handler.copy(borrowed_ptr, allocator),
                    };
                },
                .owned => {},
            }
            return &this.owned;
        }

        pub fn deinit(this: *@This(), allocator: Allocator) void {
            if (this.* == .owned) {
                Handler.deinit(&this.owned, allocator);
            }
        }
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

test "Cow borrow / own / toOwned" {
    const Boxed = struct { value: u32 };
    const VTable = struct {
        fn copy(src: *const Boxed, _: Allocator) Boxed {
            return .{ .value = src.value };
        }
        fn deinit(_: *Boxed, _: Allocator) void {}
    };
    const C = Cow(Boxed, VTable);

    var src: Boxed = .{ .value = 7 };
    var cow = C.borrow(&src);
    try testing.expectEqual(@as(u32, 7), cow.inner().value);
    try testing.expect(cow.innerMut() == null);

    const out = cow.toOwned(testing.allocator);
    try testing.expectEqual(@as(u32, 7), out.value);
    try testing.expect(cow.innerMut() != null);

    var owned_cow = C.own(.{ .value = 42 });
    defer owned_cow.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 42), owned_cow.inner().value);
    owned_cow.replace(testing.allocator, .{ .value = 99 });
    try testing.expectEqual(@as(u32, 99), owned_cow.inner().value);
}
