// Copied from bun/src/s3_signing/storage_class.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").

//! S3 storage class enum + lookup table. Pure data — no JSC, no I/O.
//! Mirrors the `x-amz-storage-class` header values accepted by the S3 REST API.
pub const StorageClass = enum {
    STANDARD,
    STANDARD_IA,
    INTELLIGENT_TIERING,
    EXPRESS_ONEZONE,
    ONEZONE_IA,
    GLACIER,
    GLACIER_IR,
    REDUCED_REDUNDANCY,
    OUTPOSTS,
    DEEP_ARCHIVE,
    SNOW,

    pub fn toString(this: @This()) []const u8 {
        return switch (this) {
            .STANDARD => "STANDARD",
            .STANDARD_IA => "STANDARD_IA",
            .INTELLIGENT_TIERING => "INTELLIGENT_TIERING",
            .EXPRESS_ONEZONE => "EXPRESS_ONEZONE",
            .ONEZONE_IA => "ONEZONE_IA",
            .GLACIER => "GLACIER",
            .GLACIER_IR => "GLACIER_IR",
            .REDUCED_REDUNDANCY => "REDUCED_REDUNDANCY",
            .OUTPOSTS => "OUTPOSTS",
            .DEEP_ARCHIVE => "DEEP_ARCHIVE",
            .SNOW => "SNOW",
        };
    }

    pub const Map = home_rt.ComptimeStringMap(StorageClass, .{
        .{ "STANDARD", .STANDARD },
        .{ "STANDARD_IA", .STANDARD_IA },
        .{ "INTELLIGENT_TIERING", .INTELLIGENT_TIERING },
        .{ "EXPRESS_ONEZONE", .EXPRESS_ONEZONE },
        .{ "ONEZONE_IA", .ONEZONE_IA },
        .{ "GLACIER", .GLACIER },
        .{ "GLACIER_IR", .GLACIER_IR },
        .{ "REDUCED_REDUNDANCY", .REDUCED_REDUNDANCY },
        .{ "OUTPOSTS", .OUTPOSTS },
        .{ "DEEP_ARCHIVE", .DEEP_ARCHIVE },
        .{ "SNOW", .SNOW },
    });
};

test "StorageClass.toString round-trips through Map" {
    const std = @import("std");
const bun = @import("bun");
    inline for (bun.meta.fieldsOf(StorageClass)) |f| {
        const tag: StorageClass = @field(StorageClass, f.name);
        const s = tag.toString();
        const got = StorageClass.Map.get(s) orelse return error.MissingMapping;
        try std.testing.expectEqual(tag, got);
    }
}

test "StorageClass.Map rejects unknown strings" {
    const std = @import("std");
    try std.testing.expect(StorageClass.Map.get("standard") == null); // case sensitive
    try std.testing.expect(StorageClass.Map.get("") == null);
    try std.testing.expect(StorageClass.Map.get("FROZEN") == null);
}

const home_rt = @import("home");
