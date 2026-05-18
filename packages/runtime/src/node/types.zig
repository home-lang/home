// Copied from bun/src/runtime/node/types.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// **Partial port (pure data + comptime lookup tables only).**
//
// Upstream `types.zig` (1251 lines) is the umbrella vocabulary file for
// `jsc.Node.*` — `BlobOrStringOrBuffer`, `StringOrBuffer`, `PathLike`,
// `PathOrFileDescriptor`, `Dirent`, `VectorArrayBuffer`, `Valid`, etc. The
// vast majority of it materializes JS values via `jsc.JSGlobalObject` /
// `bun.String.fromJS` / `Blob`, so it stays parked until the JSC surface
// re-lands.
//
// What's ported here (pure-Zig leaves, no JSC):
//   * `Encoding` enum (tag layout matches `src/jsc/bindings/BufferEncodingType.h`,
//     **load-bearing for the C++ codegen layer**) + the
//     `ComptimeStringMap` of Node's accepted alias strings + the
//     `isBinaryToText` predicate + `from(slice)` case-sensitive lookup.
//   * `FileSystemFlags` enum — the *integer* `O.*` flag combinations Node's
//     `fs.open()` accepts ("r", "w+", "ax", …) plus the string→i32
//     `ComptimeStringMap`. The `O.*` constants come from
//     `home_rt.node.node_fs_constant` which has been ported.
//
// What's omitted (re-attaches with the JSC surface):
//   * `BlobOrStringOrBuffer` / `StringOrBuffer` / `PathLike` / `PathOrBlob`
//     unions — all JSC-bound (`Blob`, `Buffer`, `ZigString.Slice`).
//   * `Encoding.fromJS` / `assert` / `fromJSWithDefaultOnEmpty` /
//     `encodeWithSize` / `encodeWithMaxSize` / `toJS` — JSC-bound.
//   * `FileSystemFlags.fromJS` / `fromJSNumberOnly` — JSC-bound.
//   * `Valid` namespace (path-length guards on `jsc.JSGlobalObject`).
//   * `VectorArrayBuffer` / `Dirent` / `modeFromJS` / `CallbackTask` /
//     `jsAssertEncodingValid` / `PathOrFileDescriptor` — JSC-bound.
//
// Imports rewritten: @import("bun") → @import("home_rt").

const std = @import("std");

const home_rt = @import("home_rt");
const strings = home_rt.strings;
const ComptimeStringMap = home_rt.ComptimeStringMap;
const O = home_rt.node.node_fs_constant.O;

/// Buffer encoding tag. **Load-bearing**: the integer ordering matches
/// `src/jsc/bindings/BufferEncodingType.h` byte-for-byte, since
/// `WebCore_BufferEncodingType_toJS` does an in-place cast. Do not reorder.
///
/// https://github.com/nodejs/node/blob/master/lib/buffer.js#L587
/// See `jsc.WebCore.encoding` for encoding and decoding functions.
pub const Encoding = enum(u8) {
    utf8,
    ucs2,
    utf16le,
    latin1,
    ascii,
    base64,
    base64url,
    hex,

    /// Refer to the buffer's encoding
    buffer,

    /// Canonical alias table — every string Node's buffer encoding parser
    /// accepts. Carried verbatim from upstream; do not edit without
    /// matching `src/jsc/bindings/BufferEncodingType.cpp`.
    pub const map = ComptimeStringMap(Encoding, .{
        .{ "utf-8", Encoding.utf8 },
        .{ "utf8", Encoding.utf8 },
        .{ "ucs-2", Encoding.utf16le },
        .{ "ucs2", Encoding.utf16le },
        .{ "utf16-le", Encoding.utf16le },
        .{ "utf16le", Encoding.utf16le },
        .{ "binary", Encoding.latin1 },
        .{ "latin1", Encoding.latin1 },
        .{ "ascii", Encoding.ascii },
        .{ "base64", Encoding.base64 },
        .{ "hex", Encoding.hex },
        .{ "buffer", Encoding.buffer },
        .{ "base64url", Encoding.base64url },
    });

    pub fn isBinaryToText(this: Encoding) bool {
        return switch (this) {
            .hex, .base64, .base64url => true,
            else => false,
        };
    }

    /// Case-sensitive lookup. Upstream additionally exposes a
    /// case-insensitive variant via `strings.inMapCaseInsensitive` —
    /// re-attaches once that helper ports.
    pub fn from(slice: []const u8) ?Encoding {
        return map.get(slice);
    }
};

/// Node's `fs.open()` flag string vocabulary, baked into an `enum(c_int)`
/// whose payload is the `O.*` bitmask combination libc expects. Mirrors
/// `node:fs.constants` semantics — see the upstream comment headers in the
/// commented-out cases for what each string maps to.
pub const FileSystemFlags = enum(c_int) {
    pub const tag_type = @typeInfo(FileSystemFlags).@"enum".tag_type;

    /// Open file for appending. Created if it does not exist.
    a = O.APPEND | O.WRONLY | O.CREAT,
    /// Open file for reading. An exception occurs if the file does not exist.
    r = O.RDONLY,
    /// Open file for writing. Created if it does not exist, truncated if it does.
    w = O.WRONLY | O.CREAT,

    _,

    /// String → `O.*`-bitmask table. Sourced from
    /// https://nodejs.org/api/fs.html#fs_file_system_flags — every alias is
    /// case-significant and carried verbatim.
    pub const map = ComptimeStringMap(i32, .{
        .{ "r", O.RDONLY },
        .{ "rs", O.RDONLY | O.SYNC },
        .{ "sr", O.RDONLY | O.SYNC },
        .{ "r+", O.RDWR },
        .{ "rs+", O.RDWR | O.SYNC },
        .{ "sr+", O.RDWR | O.SYNC },

        .{ "R", O.RDONLY },
        .{ "RS", O.RDONLY | O.SYNC },
        .{ "SR", O.RDONLY | O.SYNC },
        .{ "R+", O.RDWR },
        .{ "RS+", O.RDWR | O.SYNC },
        .{ "SR+", O.RDWR | O.SYNC },

        .{ "w", O.TRUNC | O.CREAT | O.WRONLY },
        .{ "wx", O.TRUNC | O.CREAT | O.WRONLY | O.EXCL },
        .{ "xw", O.TRUNC | O.CREAT | O.WRONLY | O.EXCL },

        .{ "W", O.TRUNC | O.CREAT | O.WRONLY },
        .{ "WX", O.TRUNC | O.CREAT | O.WRONLY | O.EXCL },
        .{ "XW", O.TRUNC | O.CREAT | O.WRONLY | O.EXCL },

        .{ "w+", O.TRUNC | O.CREAT | O.RDWR },
        .{ "wx+", O.TRUNC | O.CREAT | O.RDWR | O.EXCL },
        .{ "xw+", O.TRUNC | O.CREAT | O.RDWR | O.EXCL },

        .{ "W+", O.TRUNC | O.CREAT | O.RDWR },
        .{ "WX+", O.TRUNC | O.CREAT | O.RDWR | O.EXCL },
        .{ "XW+", O.TRUNC | O.CREAT | O.RDWR | O.EXCL },

        .{ "a", O.APPEND | O.CREAT | O.WRONLY },
        .{ "ax", O.APPEND | O.CREAT | O.WRONLY | O.EXCL },
        .{ "xa", O.APPEND | O.CREAT | O.WRONLY | O.EXCL },
        .{ "as", O.APPEND | O.CREAT | O.WRONLY | O.SYNC },
        .{ "sa", O.APPEND | O.CREAT | O.WRONLY | O.SYNC },

        .{ "A", O.APPEND | O.CREAT | O.WRONLY },
        .{ "AX", O.APPEND | O.CREAT | O.WRONLY | O.EXCL },
        .{ "XA", O.APPEND | O.CREAT | O.WRONLY | O.EXCL },
        .{ "AS", O.APPEND | O.CREAT | O.WRONLY | O.SYNC },
        .{ "SA", O.APPEND | O.CREAT | O.WRONLY | O.SYNC },

        .{ "a+", O.APPEND | O.CREAT | O.RDWR },
        .{ "ax+", O.APPEND | O.CREAT | O.RDWR | O.EXCL },
        .{ "xa+", O.APPEND | O.CREAT | O.RDWR | O.EXCL },
        .{ "as+", O.APPEND | O.CREAT | O.RDWR | O.SYNC },
        .{ "sa+", O.APPEND | O.CREAT | O.RDWR | O.SYNC },

        .{ "A+", O.APPEND | O.CREAT | O.RDWR },
        .{ "AX+", O.APPEND | O.CREAT | O.RDWR | O.EXCL },
        .{ "XA+", O.APPEND | O.CREAT | O.RDWR | O.EXCL },
        .{ "AS+", O.APPEND | O.CREAT | O.RDWR | O.SYNC },
        .{ "SA+", O.APPEND | O.CREAT | O.RDWR | O.SYNC },
    });

    pub fn asInt(flags: FileSystemFlags) tag_type {
        return @intFromEnum(flags);
    }
};

test "types: Encoding tag layout is load-bearing (matches BufferEncodingType.h)" {
    // Do NOT reorder these — the C++ codegen layer does an in-place cast.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Encoding.utf8));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Encoding.ucs2));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Encoding.utf16le));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Encoding.latin1));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Encoding.ascii));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Encoding.base64));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Encoding.base64url));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(Encoding.hex));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(Encoding.buffer));
}

test "types: Encoding.map collapses Node alias spellings to the canonical enum" {
    try std.testing.expectEqual(Encoding.utf8, Encoding.map.get("utf-8").?);
    try std.testing.expectEqual(Encoding.utf8, Encoding.map.get("utf8").?);
    try std.testing.expectEqual(Encoding.utf16le, Encoding.map.get("ucs-2").?);
    try std.testing.expectEqual(Encoding.utf16le, Encoding.map.get("ucs2").?);
    try std.testing.expectEqual(Encoding.utf16le, Encoding.map.get("utf16-le").?);
    try std.testing.expectEqual(Encoding.utf16le, Encoding.map.get("utf16le").?);
    try std.testing.expectEqual(Encoding.latin1, Encoding.map.get("binary").?);
    try std.testing.expectEqual(Encoding.latin1, Encoding.map.get("latin1").?);
    try std.testing.expectEqual(Encoding.base64url, Encoding.map.get("base64url").?);
    // Case-sensitive: the map only carries lowercased alias spellings.
    try std.testing.expectEqual(@as(?Encoding, null), Encoding.map.get("UTF-8"));
    try std.testing.expectEqual(@as(?Encoding, null), Encoding.map.get(""));
}

test "types: Encoding.from is a thin alias for case-sensitive map.get" {
    try std.testing.expectEqual(Encoding.hex, Encoding.from("hex").?);
    try std.testing.expectEqual(Encoding.buffer, Encoding.from("buffer").?);
    try std.testing.expectEqual(@as(?Encoding, null), Encoding.from("nope"));
}

test "types: Encoding.isBinaryToText flags exactly hex/base64/base64url" {
    try std.testing.expect(Encoding.hex.isBinaryToText());
    try std.testing.expect(Encoding.base64.isBinaryToText());
    try std.testing.expect(Encoding.base64url.isBinaryToText());
    try std.testing.expect(!Encoding.utf8.isBinaryToText());
    try std.testing.expect(!Encoding.ucs2.isBinaryToText());
    try std.testing.expect(!Encoding.utf16le.isBinaryToText());
    try std.testing.expect(!Encoding.latin1.isBinaryToText());
    try std.testing.expect(!Encoding.ascii.isBinaryToText());
    try std.testing.expect(!Encoding.buffer.isBinaryToText());
}

test "types: FileSystemFlags.map composes O.* flags correctly for common Node strings" {
    // "r" → read-only
    try std.testing.expectEqual(@as(i32, O.RDONLY), FileSystemFlags.map.get("r").?);
    // "w" → write-only with create + truncate (Node truncates on plain "w")
    try std.testing.expectEqual(@as(i32, O.TRUNC | O.CREAT | O.WRONLY), FileSystemFlags.map.get("w").?);
    // "wx" → like "w" but the file must NOT already exist (EXCL)
    try std.testing.expectEqual(@as(i32, O.TRUNC | O.CREAT | O.WRONLY | O.EXCL), FileSystemFlags.map.get("wx").?);
    // "a" → append, create if missing, write-only
    try std.testing.expectEqual(@as(i32, O.APPEND | O.CREAT | O.WRONLY), FileSystemFlags.map.get("a").?);
    // "a+" upgrades the append to read+write
    try std.testing.expectEqual(@as(i32, O.APPEND | O.CREAT | O.RDWR), FileSystemFlags.map.get("a+").?);
    // Uppercase aliases (Node accepts them) map to the same flags
    try std.testing.expectEqual(FileSystemFlags.map.get("r"), FileSystemFlags.map.get("R"));
    try std.testing.expectEqual(FileSystemFlags.map.get("w+"), FileSystemFlags.map.get("W+"));
    // Reverse-letter aliases ("xa" for "ax", "sr" for "rs") match.
    try std.testing.expectEqual(FileSystemFlags.map.get("ax"), FileSystemFlags.map.get("xa"));
    try std.testing.expectEqual(FileSystemFlags.map.get("rs"), FileSystemFlags.map.get("sr"));
}

test "types: FileSystemFlags.asInt unwraps the carried payload" {
    const r = FileSystemFlags.r;
    try std.testing.expectEqual(@as(FileSystemFlags.tag_type, O.RDONLY), r.asInt());
    const w = FileSystemFlags.w;
    try std.testing.expectEqual(@as(FileSystemFlags.tag_type, O.WRONLY | O.CREAT), w.asInt());
}
