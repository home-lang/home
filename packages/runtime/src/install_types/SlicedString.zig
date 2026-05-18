// Copied from bun/src/install_types/SlicedString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Imports rewritten:
//   `@import("bun")`         → none (leaf-only deps)
//   `bun.Environment`         → inline `allow_assert` const (matches
//                               `home_rt.Environment.allow_assert` policy:
//                               on in Debug, off otherwise)
//   `bun.assert`              → `std.debug.assert`
//   `bun.Wyhash11`            → sibling import of the SemverString
//                               implementation's `stringHash` helper
//                               (Wyhash11 with seed 0 — same algorithm)
//   `bun.isSliceInBuffer`     → inlined `isSliceInBufferShim`
//   `bun.Output.panic`        → `@panic` (no bun.Output substrate yet)
//   `bun.Semver.String`        → sibling `@import("SemverString.zig").String`
//   `bun.Semver.ExternalString`→ sibling `@import("ExternalString.zig").ExternalString`
//
// Trimming versus upstream: none — the structure is preserved verbatim
// modulo the import-shim mechanics.

//! `Semver.SlicedString`: a `{ buf, slice }` pair where `slice` is a
//! sub-slice of `buf`. Used by the semver parser to advance through input
//! while preserving the original buffer for offset-into-buf encoding.

const SlicedString = @This();

buf: string,
slice: string,

pub inline fn init(buf: string, slice: string) SlicedString {
    if (allow_assert and !@inComptime()) {
        if (@intFromPtr(buf.ptr) > @intFromPtr(slice.ptr)) {
            @panic("SlicedString.init buf is not in front of slice");
        }
    }
    return SlicedString{ .buf = buf, .slice = slice };
}

pub inline fn external(this: SlicedString) ExternalString {
    if (comptime allow_assert) {
        std.debug.assert(@intFromPtr(this.buf.ptr) <= @intFromPtr(this.slice.ptr) and ((@intFromPtr(this.slice.ptr) + this.slice.len) <= (@intFromPtr(this.buf.ptr) + this.buf.len)));
    }

    return ExternalString.init(this.buf, this.slice, String.stringHash(this.slice));
}

pub inline fn value(this: SlicedString) String {
    if (comptime allow_assert) {
        std.debug.assert(@intFromPtr(this.buf.ptr) <= @intFromPtr(this.slice.ptr) and ((@intFromPtr(this.slice.ptr) + this.slice.len) <= (@intFromPtr(this.buf.ptr) + this.buf.len)));
    }

    return String.init(this.buf, this.slice);
}

pub inline fn sub(this: SlicedString, input: string) SlicedString {
    if (allow_assert) {
        if (!isSliceInBufferShim(input, this.buf)) {
            @panic("SlicedString.sub input is not a substring of the parent slice");
        }
    }
    return SlicedString{ .buf = this.buf, .slice = input };
}

// Inlined Bun-compat shim — mirrors `bun.isSliceInBuffer`: true iff `slice`
// lies entirely within `buf` (pointer-wise). Empty slices match any buffer.
inline fn isSliceInBufferShim(slice: []const u8, buf: []const u8) bool {
    if (slice.len == 0) return true;
    const buf_start = @intFromPtr(buf.ptr);
    const buf_end = buf_start + buf.len;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    return slice_start >= buf_start and slice_end <= buf_end;
}

// Mirrors `home_rt.Environment.allow_assert` — enabled in Debug builds,
// off in release modes. Avoids pulling the `home_rt` module so this leaf
// has no module-conflict footprint when included through the package tree.
const allow_assert = @import("builtin").mode == .Debug;

const string = []const u8;

const std = @import("std");

const ExternalString = @import("ExternalString.zig").ExternalString;
const String = @import("SemverString.zig").String;

test "SlicedString.init produces { buf, slice } pair" {
    const buf = "hello world";
    const s = SlicedString.init(buf, buf[6..11]);
    try std.testing.expectEqualStrings(buf, s.buf);
    try std.testing.expectEqualStrings("world", s.slice);
}

test "SlicedString.value encodes inline for ≤8 bytes" {
    const buf = "abc";
    const v = SlicedString.init(buf, buf).value();
    try std.testing.expect(v.isInline());
    try std.testing.expectEqualStrings("abc", v.slice(""));
}

test "SlicedString.value encodes external pointer for >8 bytes" {
    const buf = "hello, world!";
    const v = SlicedString.init(buf, buf).value();
    try std.testing.expect(!v.isInline());
    try std.testing.expectEqualStrings(buf, v.slice(buf));
}

test "SlicedString.external hashes slice via SemverString.stringHash" {
    const buf = "abcdef";
    const e = SlicedString.init(buf, buf).external();
    try std.testing.expectEqual(String.stringHash(buf), e.hash);
}

test "SlicedString.sub narrows the slice while preserving buf" {
    const buf = "abcdef";
    const parent = SlicedString.init(buf, buf);
    const child = parent.sub(buf[1..4]);
    try std.testing.expectEqualStrings(buf, child.buf);
    try std.testing.expectEqualStrings("bcd", child.slice);
}

test "SlicedString.sub allows the empty slice (matches any buffer)" {
    const buf = "abc";
    const parent = SlicedString.init(buf, buf);
    const empty = parent.sub(buf[0..0]);
    try std.testing.expectEqual(@as(usize, 0), empty.slice.len);
}
