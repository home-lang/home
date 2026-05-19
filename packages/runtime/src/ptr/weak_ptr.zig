// Ported from bun/src/ptr/weak_ptr.zig at pinned SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
//
// Wave-15 Tier-1 grinder copy. `bun.debugAssert` + `bun.destroy` resolve
// via the matching helpers added to `home_rt.zig` alongside this port.

pub const WeakPtrData = packed struct(u32) {
    reference_count: u31,
    finalized: bool,

    pub const empty: @This() = .{
        .reference_count = 0,
        .finalized = false,
    };

    pub fn onFinalize(this: *WeakPtrData) bool {
        home_rt.debugAssert(!this.finalized);
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
            home_rt.debugAssert(!data(req).finalized);
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
                home_rt.destroy(value);
            }
        }

        fn data(value: *T) *WeakPtrData {
            return &@field(value, data_field);
        }
    };
}

const home_rt = @import("home_rt");

test "WeakPtrData: onFinalize sets finalized + reports zero-ref state" {
    var d = WeakPtrData.empty;
    try std.testing.expect(d.onFinalize());
    try std.testing.expect(d.finalized);

    var d2: WeakPtrData = .{ .reference_count = 2, .finalized = false };
    try std.testing.expect(!d2.onFinalize());
    try std.testing.expect(d2.finalized);
}

test "WeakPtr: initRef increments and deref clears" {
    const Target = struct {
        weak: WeakPtrData = .empty,
        value: u32 = 42,
    };

    const target = try home_rt.default_allocator.create(Target);
    defer home_rt.default_allocator.destroy(target);
    target.* = .{};

    var weak = WeakPtr(Target, "weak").initRef(target);
    try std.testing.expectEqual(@as(u31, 1), target.weak.reference_count);
    try std.testing.expectEqual(@as(?*Target, target), weak.get());

    weak.deref();
    try std.testing.expectEqual(@as(u31, 0), target.weak.reference_count);
    try std.testing.expectEqual(@as(?*Target, null), weak.raw_ptr);
}

const std = @import("std");
