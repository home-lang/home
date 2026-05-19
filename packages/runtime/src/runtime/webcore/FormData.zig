// Copied (partial) from bun/src/runtime/webcore/FormData.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Scope:
//   * The pure-parse `Encoding` union (URLEncoded vs Multipart) and the
//     `getBoundary(content_type)` helper that callers use to detect the
//     fetch-Body encoding from the `Content-Type` header. Both touch only
//     `[]const u8` so they land cleanly without JSC.
//
//   * `Field` is reduced to the plain-binary payload variant of the upstream
//     `Field` struct (`value`, `is_file`, `zero_count`). The
//     `bun.Semver.String`-backed `filename`/`content_type` fields and the
//     `Field.External`/`Entry` aliases are JSC- and Semver-coupled and stay
//     parked until those substrates land.
//
//   * The JSC-bridged surface — `AsyncFormData`, `toJS`,
//     `toJSFromMultipartData`, `forEachMultipartEntry`,
//     `fromMultipartData`, the `Map = std.ArrayHashMapUnmanaged(...)`
//     keyed on `bun.Semver.String` — all require JSC + Semver and are not
//     ported here.
//
// Rewritten imports: `@import("bun")` → `@import("home_rt")`; `strings.*`
// resolves to `home_rt.strings` (which currently exposes `indexOf`,
// `indexOfChar`, `startsWith`, ... — see `strings.zig`).

const std = @import("std");
const home_rt = @import("home_rt");
const strings = home_rt.strings;

pub const FormData = struct {
    pub const Encoding = union(enum) {
        URLEncoded: void,
        Multipart: []const u8, // boundary

        pub fn get(content_type: []const u8) ?Encoding {
            if (strings.indexOf(content_type, "application/x-www-form-urlencoded") != null)
                return Encoding{ .URLEncoded = {} };

            if (strings.indexOf(content_type, "multipart/form-data") == null) return null;

            const boundary = getBoundary(content_type) orelse return null;
            return .{
                .Multipart = boundary,
            };
        }
    };

    pub fn getBoundary(content_type: []const u8) ?[]const u8 {
        const boundary_index = strings.indexOf(content_type, "boundary=") orelse return null;
        const boundary_start = boundary_index + "boundary=".len;
        const begin = content_type[boundary_start..];
        if (begin.len == 0)
            return null;

        const boundary_end = strings.indexOfChar(begin, ';') orelse @as(u32, @truncate(begin.len));
        if (begin[0] == '"') {
            if (boundary_end > 1 and begin[boundary_end - 1] == '"') {
                return begin[1 .. boundary_end - 1];
            }
            // Opening quote with no matching closing quote — malformed.
            return null;
        }

        return begin[0..boundary_end];
    }

    /// Subset of upstream `Field` — Semver-/JSC-typed members are omitted
    /// (`filename`, `content_type`, and the `Entry`/`External` aliases) until
    /// those substrates land.
    pub const Field = struct {
        /// Raw slice into the input buffer. Not using a Semver.String because
        /// file bodies are binary data that can contain null bytes, which
        /// Semver.String's inline storage treats as terminators.
        value: []const u8 = "",
        is_file: bool = false,
        zero_count: u8 = 0,
    };
};

test "FormData.Encoding: URL-encoded detection" {
    const enc = FormData.Encoding.get("application/x-www-form-urlencoded; charset=utf-8");
    try std.testing.expect(enc != null);
    try std.testing.expect(enc.? == .URLEncoded);
}

test "FormData.Encoding: multipart detection + boundary capture" {
    const enc = FormData.Encoding.get("multipart/form-data; boundary=abc123");
    try std.testing.expect(enc != null);
    switch (enc.?) {
        .Multipart => |b| try std.testing.expectEqualStrings("abc123", b),
        else => try std.testing.expect(false),
    }
}

test "FormData.Encoding: unknown content-type returns null" {
    try std.testing.expectEqual(@as(?FormData.Encoding, null), FormData.Encoding.get("text/plain"));
    // multipart without boundary= is malformed → null
    try std.testing.expectEqual(@as(?FormData.Encoding, null), FormData.Encoding.get("multipart/form-data"));
}

test "FormData.getBoundary: quoted boundary unwraps quotes" {
    const b = FormData.getBoundary("multipart/form-data; boundary=\"xy\"") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("xy", b);
}

test "FormData.getBoundary: unterminated quote is malformed" {
    try std.testing.expectEqual(@as(?[]const u8, null), FormData.getBoundary("multipart/form-data; boundary=\"oops"));
}

test "FormData.getBoundary: terminator semicolon trims trailing params" {
    const b = FormData.getBoundary("multipart/form-data; boundary=abc; charset=utf-8") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("abc", b);
}

test "FormData.Field: default value zero-initialises" {
    const f: FormData.Field = .{};
    try std.testing.expectEqual(@as(usize, 0), f.value.len);
    try std.testing.expectEqual(false, f.is_file);
    try std.testing.expectEqual(@as(u8, 0), f.zero_count);
}
