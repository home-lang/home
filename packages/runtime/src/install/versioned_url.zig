// Copied from bun/src/install/versioned_url.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.
//
// Imports rewritten:
//   `@import("bun")`    -> sibling `../semver/semver.zig`
//   `bun.Semver.String` -> `Semver.String`
//
// This leaf is otherwise layout-preserving: it remains an extern `{ url,
// version }` pair used by npm resolution records.

pub const VersionedURL = VersionedURLType(u64);
pub const OldV2VersionedURL = VersionedURLType(u32);

pub fn VersionedURLType(comptime SemverIntType: type) type {
    return extern struct {
        url: String,
        version: Semver.VersionType(SemverIntType),

        pub fn eql(this: @This(), other: @This()) bool {
            return this.version.eql(other.version);
        }

        pub fn order(this: @This(), other: @This(), lhs_buf: []const u8, rhs_buf: []const u8) @import("std").math.Order {
            return this.version.order(other.version, lhs_buf, rhs_buf);
        }

        pub fn count(this: @This(), buf: []const u8, comptime Builder: type, builder: Builder) void {
            this.version.count(buf, comptime Builder, builder);
            builder.count(this.url.slice(buf));
        }

        pub fn clone(this: @This(), buf: []const u8, comptime Builder: type, builder: Builder) @This() {
            return @This(){
                .version = this.version.append(buf, Builder, builder),
                .url = builder.append(String, this.url.slice(buf)),
            };
        }

        pub fn migrate(this: @This()) VersionedURLType(u64) {
            if (comptime SemverIntType != u32) {
                @compileError("unexpected SemverIntType");
            }
            return .{
                .url = this.url,
                .version = this.version.migrate(),
            };
        }
    };
}

const std = @import("std");

const Semver = @import("../semver/semver.zig");
const String = Semver.String;

test "VersionedURL layout stores url plus u64 semver version" {
    try std.testing.expectEqual(@sizeOf(String) + @sizeOf(Semver.Version), @sizeOf(VersionedURL));
    try std.testing.expectEqual(@alignOf(Semver.Version), @alignOf(VersionedURL));
}

test "VersionedURL.eql delegates to semantic version equality" {
    const a = VersionedURL{
        .url = String.init("https://registry.npmjs.org/pkg/-/pkg-1.2.3.tgz", "https://registry.npmjs.org/pkg/-/pkg-1.2.3.tgz"),
        .version = .{ .major = 1, .minor = 2, .patch = 3 },
    };
    const b = VersionedURL{
        .url = String.init("different-url", "different-url"),
        .version = .{ .major = 1, .minor = 2, .patch = 3 },
    };
    const c = VersionedURL{
        .url = a.url,
        .version = .{ .major = 1, .minor = 2, .patch = 4 },
    };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "VersionedURL.order delegates to semantic version ordering" {
    const lower = VersionedURL{
        .url = String.from("a"),
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
    const higher = VersionedURL{
        .url = String.from("b"),
        .version = .{ .major = 1, .minor = 1, .patch = 0 },
    };

    try std.testing.expectEqual(std.math.Order.lt, lower.order(higher, "", ""));
    try std.testing.expectEqual(std.math.Order.gt, higher.order(lower, "", ""));
}

test "OldV2VersionedURL.migrate widens semver integer fields" {
    const old = OldV2VersionedURL{
        .url = String.from("tarball"),
        .version = .{ .major = 1, .minor = 2, .patch = 3 },
    };
    const migrated = old.migrate();

    try std.testing.expectEqual(@as(u64, 1), migrated.version.major);
    try std.testing.expectEqual(@as(u64, 2), migrated.version.minor);
    try std.testing.expectEqual(@as(u64, 3), migrated.version.patch);
    try std.testing.expectEqualStrings("tarball", migrated.url.slice(""));
}

test "VersionedURL.count and clone include the URL string" {
    const url_buf = "https://registry.npmjs.org/pkg/-/pkg-1.0.0.tgz";
    const original = VersionedURL{
        .url = String.init(url_buf, url_buf),
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
    var builder = CountingBuilder{};

    original.count(url_buf, *CountingBuilder, &builder);
    try std.testing.expectEqual(@as(usize, url_buf.len), builder.counted);

    const cloned = original.clone(url_buf, *CountingBuilder, &builder);
    try std.testing.expectEqualStrings(url_buf, cloned.url.slice(url_buf));
    try std.testing.expect(cloned.version.eql(original.version));
}

const CountingBuilder = struct {
    counted: usize = 0,

    pub fn count(this: *@This(), value: []const u8) void {
        this.counted += value.len;
    }

    pub fn append(_: *@This(), comptime Type: type, value: []const u8) Type {
        return switch (Type) {
            String => String.init(value, value),
            Semver.ExternalString => Semver.ExternalString.init(value, value, String.stringHash(value)),
            else => @compileError("unexpected VersionedURL test builder type"),
        };
    }
};
