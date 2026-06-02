// Copied from bun/src/install_types/ExternalString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Imports rewritten:
//   `@import("bun")`        → `@import("home")`
//   `bun.Semver.String`     → sibling `@import("SemverString.zig").String`
//   `bun.Wyhash.hash`        → `std.hash.Wyhash.hash` (stdlib equivalent)
//
// The upstream sources `ExternalString.from`'s hash via `bun.Wyhash` (the
// std-equivalent 64-bit Wyhash); Home keeps the same algorithm via
// `std.hash.Wyhash.hash` so payloads round-trip with the lockfile format.
// The rest is layout-preserving.

//! `Semver.ExternalString` = `Semver.String` + cached 64-bit content hash.
//! Layout: { String value (8 bytes); u64 hash (8 bytes) } extern struct —
//! 16 bytes total — matching the on-disk lockfile representation.

pub const ExternalString = extern struct {
    value: String = String{},
    hash: u64 = 0,

    pub inline fn fmt(this: *const ExternalString, buf: []const u8) String.Formatter {
        return this.value.fmt(buf);
    }

    pub fn order(lhs: *const ExternalString, rhs: *const ExternalString, lhs_buf: []const u8, rhs_buf: []const u8) std.math.Order {
        if (lhs.hash == rhs.hash and lhs.hash > 0) return .eq;

        return lhs.value.order(&rhs.value, lhs_buf, rhs_buf);
    }

    /// ExternalString but without the hash
    pub inline fn from(in: string) ExternalString {
        return ExternalString{
            .value = String.init(in, in),
            .hash = std.hash.Wyhash.hash(0, in),
        };
    }

    pub inline fn isInline(this: ExternalString) bool {
        return this.value.isInline();
    }

    pub inline fn isEmpty(this: ExternalString) bool {
        return this.value.isEmpty();
    }

    pub inline fn len(this: ExternalString) usize {
        return this.value.len();
    }

    pub inline fn init(buf: string, in: string, hash: u64) ExternalString {
        return ExternalString{
            .value = String.init(buf, in),
            .hash = hash,
        };
    }

    pub inline fn slice(this: *const ExternalString, buf: string) string {
        return this.value.slice(buf);
    }
};

const string = []const u8;

const std = @import("std");
const String = @import("SemverString.zig").String;

test "ExternalString.empty round-trips" {
    const e = ExternalString{};
    try std.testing.expect(e.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), e.len());
    try std.testing.expectEqualStrings("", e.slice(""));
}

test "ExternalString.from inlines short ASCII and hashes via Wyhash" {
    const e = ExternalString.from("abc");
    try std.testing.expect(e.isInline());
    try std.testing.expectEqualStrings("abc", e.slice(""));
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, "abc"), e.hash);
}

test "ExternalString.from external for >8 bytes" {
    const e = ExternalString.from("hello, world!");
    try std.testing.expect(!e.isInline());
    try std.testing.expectEqualStrings("hello, world!", e.slice("hello, world!"));
}

test "ExternalString.init preserves caller-supplied hash" {
    const buf = "abc";
    const e = ExternalString.init(buf, buf, 0xdeadbeef);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), e.hash);
    try std.testing.expectEqualStrings(buf, e.slice(buf));
}

test "ExternalString.order: matching nonzero hashes short-circuit to eq" {
    var a = ExternalString.init("aaa", "aaa", 42);
    var b = ExternalString.init("bbb", "bbb", 42);
    try std.testing.expectEqual(std.math.Order.eq, a.order(&b, "aaa", "bbb"));
}

test "ExternalString.order: zero hashes fall through to content order" {
    var a = ExternalString.init("aaa", "aaa", 0);
    var b = ExternalString.init("aab", "aab", 0);
    try std.testing.expectEqual(std.math.Order.lt, a.order(&b, "aaa", "aab"));
    try std.testing.expectEqual(std.math.Order.gt, b.order(&a, "aab", "aaa"));
}

test "ExternalString layout is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ExternalString));
}

test "ExternalString.fmt writes the slice payload" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const e = ExternalString.from("abc");
    try (&e).fmt("").format(&w);
    try std.testing.expectEqualStrings("abc", w.buffered());
}
