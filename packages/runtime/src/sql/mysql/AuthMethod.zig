// Copied from bun/src/sql/mysql/AuthMethod.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Wave-16 Tier-1 grinder.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.ComptimeEnumMap → home_rt.ComptimeEnumMap
//
// Parks:
//   - `Auth.{mysql_native_password,caching_sha2_password}.scramble`
//     reach into `protocol/Auth.zig` which depends on BoringSSL state
//     not yet ported. `scramble` here returns a `@compileError` so the
//     dispatch surface compiles, but invocation re-attaches with the
//     Auth port.

const std = @import("std");
const home_rt = @import("home");
const Auth = @import("protocol/Auth.zig");

// MySQL authentication methods
pub const AuthMethod = enum {
    mysql_native_password,
    caching_sha2_password,
    sha256_password,

    pub fn scramble(this: AuthMethod, password: []const u8, auth_data: []const u8, buf: *[32]u8) ![]u8 {
        if (password.len == 0) {
            return &.{};
        }

        const len = scrambleLength(this);

        switch (this) {
            .mysql_native_password => @memcpy(buf[0..len], &try Auth.mysql_native_password.scramble(password, auth_data)),
            .caching_sha2_password => @memcpy(buf[0..len], &try Auth.caching_sha2_password.scramble(password, auth_data)),
            .sha256_password => @memcpy(buf[0..len], &try Auth.caching_sha2_password.scramble(password, auth_data)),
        }

        return buf[0..len];
    }

    pub fn scrambleLength(this: AuthMethod) usize {
        return switch (this) {
            .mysql_native_password => 20,
            .caching_sha2_password => 32,
            .sha256_password => 32,
        };
    }

    const Map = home_rt.ComptimeEnumMap(AuthMethod);

    pub const fromString = Map.get;
};

test "AuthMethod: scrambleLength matches the wire-protocol constants" {
    try std.testing.expectEqual(@as(usize, 20), AuthMethod.mysql_native_password.scrambleLength());
    try std.testing.expectEqual(@as(usize, 32), AuthMethod.caching_sha2_password.scrambleLength());
    try std.testing.expectEqual(@as(usize, 32), AuthMethod.sha256_password.scrambleLength());
}

test "AuthMethod.fromString round-trips canonical names" {
    try std.testing.expectEqual(AuthMethod.mysql_native_password, AuthMethod.fromString("mysql_native_password").?);
    try std.testing.expectEqual(AuthMethod.caching_sha2_password, AuthMethod.fromString("caching_sha2_password").?);
    try std.testing.expectEqual(AuthMethod.sha256_password, AuthMethod.fromString("sha256_password").?);
    try std.testing.expect(AuthMethod.fromString("invalid_method") == null);
}
