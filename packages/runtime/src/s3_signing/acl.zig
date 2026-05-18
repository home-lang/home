// Copied from bun/src/s3_signing/acl.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt").

//! S3 canned ACLs. Pure enum + lookup table — no JSC, no I/O.
//! Maps the canned ACL header values defined by the S3 REST API.
pub const ACL = enum {
    /// Owner gets FULL_CONTROL. No one else has access rights (default).
    private,
    /// Owner gets FULL_CONTROL. The AllUsers group (see Who is a grantee?) gets READ access.
    public_read,
    /// Owner gets FULL_CONTROL. The AllUsers group gets READ and WRITE access. Granting this on a bucket is generally not recommended.
    public_read_write,
    /// Owner gets FULL_CONTROL. Amazon EC2 gets READ access to GET an Amazon Machine Image (AMI) bundle from Amazon S3.
    aws_exec_read,
    /// Owner gets FULL_CONTROL. The AuthenticatedUsers group gets READ access.
    authenticated_read,
    /// Object owner gets FULL_CONTROL. Bucket owner gets READ access. If you specify this canned ACL when creating a bucket, Amazon S3 ignores it.
    bucket_owner_read,
    /// Both the object owner and the bucket owner get FULL_CONTROL over the object. If you specify this canned ACL when creating a bucket, Amazon S3 ignores it.
    bucket_owner_full_control,
    log_delivery_write,

    pub fn toString(this: @This()) []const u8 {
        return switch (this) {
            .private => "private",
            .public_read => "public-read",
            .public_read_write => "public-read-write",
            .aws_exec_read => "aws-exec-read",
            .authenticated_read => "authenticated-read",
            .bucket_owner_read => "bucket-owner-read",
            .bucket_owner_full_control => "bucket-owner-full-control",
            .log_delivery_write => "log-delivery-write",
        };
    }

    pub const Map = home_rt.ComptimeStringMap(ACL, .{
        .{ "private", .private },
        .{ "public-read", .public_read },
        .{ "public-read-write", .public_read_write },
        .{ "aws-exec-read", .aws_exec_read },
        .{ "authenticated-read", .authenticated_read },
        .{ "bucket-owner-read", .bucket_owner_read },
        .{ "bucket-owner-full-control", .bucket_owner_full_control },
        .{ "log-delivery-write", .log_delivery_write },
    });
};

test "ACL.toString round-trips through Map" {
    const std = @import("std");
    const cases = [_]ACL{
        .private,
        .public_read,
        .public_read_write,
        .aws_exec_read,
        .authenticated_read,
        .bucket_owner_read,
        .bucket_owner_full_control,
        .log_delivery_write,
    };
    for (cases) |c| {
        const s = c.toString();
        const got = ACL.Map.get(s) orelse return error.MissingMapping;
        try std.testing.expectEqual(c, got);
    }
}

test "ACL.Map rejects unknown strings" {
    const std = @import("std");
    try std.testing.expect(ACL.Map.get("not-a-real-acl") == null);
    try std.testing.expect(ACL.Map.get("") == null);
}

const home_rt = @import("home_rt");
