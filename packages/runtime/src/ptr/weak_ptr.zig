// Copied verbatim from bun/src/ptr/weak_ptr.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Wave-13 (2026-05-18) port. `@import("bun")` rewritten to `@import("home_rt")`;
// no JSC-bridge symbols present.

pub const WeakPtrData = packed struct(u32) {
    reference_count: u31,
    finalized: bool,

    pub const empty: @This() = .{
        .reference_count = 0,
        .finalized = false,
    };

    pub fn onFinalize(this: *WeakPtrData) bool {
        bun.debugAssert(!this.finalized);
        this.finalized = true;
        return this.reference_count == 0;
    }
};

/// Allow a type to be weakly referenced. This keeps a reference count of how
/// many weak-references exist, so that when the object is destroyed, the inner
/// contents can be freed, but the object itself is not destroyed until all
/// `WeakPtr`s are released. Even if the allocation is present, `WeakPtr(T).get`
/// will return null after the inner contents are freed.
pub fn WeakPtr(comptime T: type, data_field: []const u8) type {
    return struct {
        pub const Data = WeakPtrData;

        raw_ptr: ?*T,

        pub const empty: @This() = .{ .raw_ptr = null };

        pub fn initRef(req: *T) @This() {
            bun.debugAssert(!data(req).finalized);
            data(req).reference_count += 1;
            return .{ .raw_ptr = req };
        }

        pub fn deref(this: *@This()) void {
            if (this.raw_ptr) |value| {
                this.derefInternal(value);
            }
        }

        pub fn get(this: *@This()) ?*T {
            if (this.raw_ptr) |value| {
                if (!data(value).finalized) {
                    return value;
                }

                this.derefInternal(value);
            }
            return null;
        }

        fn derefInternal(this: *@This(), value: *T) void {
            const weak_data = data(value);
            this.raw_ptr = null;
            const count = weak_data.reference_count - 1;
            weak_data.reference_count = count;
            if (weak_data.finalized and count == 0) {
                bun.destroy(value);
            }
        }

        fn data(value: *T) *WeakPtrData {
            return &@field(value, data_field);
        }
    };
}

pub const bun = @import("home_rt");

test "weak_ptr: WeakPtrData defaults to empty + finalized=false" {
    const std = @import("std");
    const d = WeakPtrData.empty;
    try std.testing.expectEqual(@as(u31, 0), d.reference_count);
    try std.testing.expect(!d.finalized);
}

test "weak_ptr: WeakPtr(T).empty is a null raw_ptr" {
    const std = @import("std");
    const Holder = struct {
        weak_data: WeakPtrData = .empty,
        value: u32 = 0,
    };
    const W = WeakPtr(Holder, "weak_data");
    const e: W = .empty;
    try std.testing.expect(e.raw_ptr == null);
}
