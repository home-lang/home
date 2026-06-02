// Copied from bun/src/ptr/ptr.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Tier-0 batch: only `Cow` is ported. All other smart-pointer imports are
// trimmed and tracked as TODO markers below. No Zig 0.17 rewrites required in
// this file itself.

//! The `ptr` module contains smart pointer types that are used throughout Bun.
pub const Cow = @import("./Cow.zig").Cow;

pub const CowSlice = @import("./CowSlice.zig").CowSlice;
pub const CowSliceZ = @import("./CowSlice.zig").CowSliceZ;
pub const CowString = CowSlice(u8);

// TODO(phase-12.1): port owned / Owned / OwnedIn / DynamicOwned in a follow-up batch.
// pub const owned = @import("./owned.zig");
// pub const Owned = owned.Owned;
// pub const OwnedIn = owned.OwnedIn;
// pub const DynamicOwned = owned.Dynamic;

// TODO(phase-12.1): port shared / Shared / AtomicShared in a follow-up batch.
// pub const shared = @import("./shared.zig");
// pub const Shared = shared.Shared;
// pub const AtomicShared = shared.AtomicShared;
// TODO(phase-12.1): port ExternalShared in a follow-up batch.
// pub const ExternalShared = @import("./external_shared.zig").ExternalShared;

// TODO(phase-12.1): port ref_count / RefCount / ThreadSafeRefCount / RefPtr in a follow-up batch.
// pub const ref_count = @import("./ref_count.zig");
// pub const RefCount = ref_count.RefCount;
// pub const ThreadSafeRefCount = ref_count.ThreadSafeRefCount;
// pub const RefPtr = ref_count.RefPtr;

// TODO(phase-12.1): port raw_ref_count / RawRefCount in a follow-up batch.
// pub const raw_ref_count = @import("./raw_ref_count.zig");
// pub const RawRefCount = raw_ref_count.RawRefCount;

pub const TaggedPointer = @import("./tagged_pointer.zig").TaggedPointer;
pub const TaggedPointerUnion = @import("./tagged_pointer.zig").TaggedPointerUnion;

// TODO(phase-12.1): port WeakPtr in a follow-up batch.
// pub const WeakPtr = @import("./weak_ptr.zig").WeakPtr;

const std = @import("std");
const testing = std.testing;

test "ptr aggregator re-exports Cow" {
    const VTable = struct {
        fn copy(src: *const u32, _: std.mem.Allocator) u32 {
            return src.*;
        }
        fn deinit(_: *u32, _: std.mem.Allocator) void {}
    };
    const C = Cow(u32, VTable);
    var x: u32 = 13;
    var cow = C.borrow(&x);
    try testing.expectEqual(@as(u32, 13), cow.inner().*);
}
