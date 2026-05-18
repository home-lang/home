// Copied from bun/src/install/install.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted the bag of package/dependency ID type aliases + sentinel
// constants from `install.zig` so other ported install leaves (Meta, Tree,
// Behavior, …) can reference them without dragging in the full
// PackageManager. Pure Zig — no `@import("bun")` rewrite needed.

const std = @import("std");

/// 32-bit identifier indexing into `Lockfile.packages`.
/// `std.math.maxInt(PackageID)` is reserved as `invalid_package_id`.
pub const PackageID = u32;

/// 32-bit identifier indexing into `Lockfile.buffers.dependencies`.
/// `std.math.maxInt(DependencyID)` is reserved as `invalid_dependency_id`.
pub const DependencyID = u32;

/// Sentinel returned wherever a lookup is unable to resolve a package.
pub const invalid_package_id: PackageID = std.math.maxInt(PackageID);

/// Sentinel returned wherever a lookup is unable to resolve a dependency.
pub const invalid_dependency_id: DependencyID = std.math.maxInt(DependencyID);

/// 64-bit hash combining a package name with a specific resolved version.
/// Computed by `String.Builder.stringHash` over `<name>@<version>`.
pub const PackageNameAndVersionHash = u64;

/// 64-bit hash of a package name. Computed by `String.Builder.stringHash`.
pub const PackageNameHash = u64;

/// Lower 32 bits of `PackageNameHash`. Used where a u32 is sufficient for
/// disambiguation (manifest cache, npm CDN URL bucket).
pub const TruncatedPackageNameHash = u32;

test "invalid_package_id is the maxInt sentinel" {
    try std.testing.expectEqual(@as(PackageID, std.math.maxInt(u32)), invalid_package_id);
}

test "invalid_dependency_id is the maxInt sentinel" {
    try std.testing.expectEqual(@as(DependencyID, std.math.maxInt(u32)), invalid_dependency_id);
}

test "TruncatedPackageNameHash drops the high 32 bits of PackageNameHash" {
    const full: PackageNameHash = 0xDEADBEEF_CAFEBABE;
    const truncated: TruncatedPackageNameHash = @truncate(full);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), truncated);
}

test "PackageID and DependencyID share the same backing integer width" {
    try std.testing.expectEqual(@bitSizeOf(PackageID), @bitSizeOf(DependencyID));
    try std.testing.expectEqual(@as(usize, 32), @bitSizeOf(PackageID));
}
