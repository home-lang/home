// Copied from bun/src/http_types/URLPath.zig at upstream
// SHA e643d7b085dfd29f675ade275197daedc2cdfc9c. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → local pure Zig helpers.
// HOME_RT_STUB_PERCENT_ENCODING: Bun pulls `PercentEncoding` from
// `src/url/url.zig`, which is a large, JSC-aware module. To keep this
// leaf self-contained we inline the minimum copy of
// `PercentEncoding.decodeFaultTolerant` (plus the two tiny ASCII-hex
// helpers it uses) here. When the full URL module re-lands we will
// swap this back to `home_rt.url.PercentEncoding`.
// Zig 0.17 fixup: replaced `std.io.fixedBufferStream`-based writer with
// `std.Io.Writer.fixed` and a `decodeFaultTolerantSlice` wrapper so
// `parse` does not depend on the old `std.io` API.

const URLPath = @This();

extname: string = "",
path: string = "",
pathname: string = "",
first_segment: string = "",
query_string: string = "",
needs_redirect: bool = false,
/// Treat URLs as non-sourcemap URLS
/// Then at the very end, we check.
is_source_map: bool = false,

pub fn isRoot(this: *const URLPath, asset_prefix: string) bool {
    const without = this.pathWithoutAssetPrefix(asset_prefix);
    if (without.len == 1 and without[0] == '.') return true;
    return strings.eqlComptime(without, "index");
}

// TODO: use a real URL parser
// this treats a URL like /_next/ identically to /
pub fn pathWithoutAssetPrefix(this: *const URLPath, asset_prefix: string) string {
    if (asset_prefix.len == 0) return this.path;
    const leading_slash_offset: usize = if (asset_prefix[0] == '/') 1 else 0;
    const base = this.path;
    const origin = asset_prefix[leading_slash_offset..];

    const out = if (base.len >= origin.len and strings.eql(base[0..origin.len], origin)) base[origin.len..] else base;
    if (this.is_source_map and strings.endsWithComptime(out, ".map")) {
        return out[0 .. out.len - 4];
    }

    return out;
}

// optimization: very few long strings will be URL-encoded
// we're allocating virtual memory here, so if we never use it, it won't be allocated
// and even when they're, they're probably rarely going to be > 1024 chars long
// so we can have a big and little one and almost always use the little one
threadlocal var temp_path_buf: [1024]u8 = undefined;
threadlocal var big_temp_path_buf: [16384]u8 = undefined;

pub fn parse(possibly_encoded_pathname_: string) !URLPath {
    var decoded_pathname = possibly_encoded_pathname_;
    var needs_redirect = false;

    if (strings.containsChar(decoded_pathname, '%')) {
        // https://github.com/ziglang/zig/issues/14148
        var possibly_encoded_pathname: []u8 = switch (decoded_pathname.len) {
            0...1024 => &temp_path_buf,
            else => &big_temp_path_buf,
        };
        possibly_encoded_pathname = possibly_encoded_pathname[0..@min(
            possibly_encoded_pathname_.len,
            possibly_encoded_pathname.len,
        )];

        copy(u8, possibly_encoded_pathname, possibly_encoded_pathname_[0..possibly_encoded_pathname.len]);
        const clone = possibly_encoded_pathname[0..possibly_encoded_pathname.len];

        decoded_pathname = possibly_encoded_pathname[0..try PercentEncoding.decodeFaultTolerantSlice(possibly_encoded_pathname, clone, &needs_redirect, true)];
    }

    // i32 (not i16): these index into the pathname, which is caller-controlled
    // (e.g. a Bun.serve request path). An i16 index overflows at 32767 bytes,
    // so a long path would trip the @intCast below and crash the parse.
    var question_mark_i: i32 = -1;
    var period_i: i32 = -1;

    var first_segment_end: i32 = std.math.maxInt(i32);
    var last_slash: i32 = -1;

    var i: i32 = @as(i32, @intCast(decoded_pathname.len)) - 1;

    while (i >= 0) : (i -= 1) {
        const c = decoded_pathname[@as(usize, @intCast(i))];

        switch (c) {
            '?' => {
                question_mark_i = @max(question_mark_i, i);
                if (question_mark_i < period_i) {
                    period_i = -1;
                }

                if (last_slash > question_mark_i) {
                    last_slash = -1;
                }
            },
            '.' => {
                period_i = @max(period_i, i);
            },
            '/' => {
                last_slash = @max(last_slash, i);

                if (i > 0) {
                    first_segment_end = @min(first_segment_end, i);
                }
            },
            else => {},
        }
    }

    if (last_slash > period_i) {
        period_i = -1;
    }

    // .js.map
    //    ^
    const extname = brk: {
        if (question_mark_i > -1 and period_i > -1) {
            period_i += 1;
            break :brk decoded_pathname[@as(usize, @intCast(period_i))..@as(usize, @intCast(question_mark_i))];
        } else if (period_i > -1) {
            period_i += 1;
            break :brk decoded_pathname[@as(usize, @intCast(period_i))..];
        } else {
            break :brk &([_]u8{});
        }
    };

    var path = if (question_mark_i < 0) decoded_pathname[1..] else decoded_pathname[1..@as(usize, @intCast(question_mark_i))];

    const first_segment = decoded_pathname[1..@min(@as(usize, @intCast(first_segment_end)), decoded_pathname.len)];
    const is_source_map = strings.eqlComptime(extname, "map");
    var backup_extname: string = extname;
    if (is_source_map and path.len > ".map".len) {
        if (std.mem.lastIndexOfScalar(u8, path[0 .. path.len - ".map".len], '.')) |j| {
            backup_extname = path[j + 1 ..];
            backup_extname = backup_extname[0 .. backup_extname.len - ".map".len];
            path = path[0 .. j + backup_extname.len + 1];
        }
    }

    return URLPath{
        .extname = if (!is_source_map) extname else backup_extname,
        .is_source_map = is_source_map,
        .pathname = decoded_pathname,
        .first_segment = first_segment,
        .path = if (decoded_pathname.len == 1) "." else path,
        .query_string = if (question_mark_i > -1) decoded_pathname[@as(usize, @intCast(question_mark_i))..@as(usize, @intCast(decoded_pathname.len))] else "",
        .needs_redirect = needs_redirect,
    };
}

// ---- Inlined PercentEncoding leaf (HOME_RT_STUB_PERCENT_ENCODING) -------

fn isASCIIHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn toASCIIHexValue(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    unreachable;
}

const PercentEncoding = struct {
    /// Slice-in / slice-out variant of Bun's `decodeFaultTolerant`. Writes
    /// the decoded bytes into `dest` (which may overlap `input` from the
    /// same buffer — bytes are written behind the read cursor). Returns
    /// the number of bytes written. The `fault_tolerant` flag preserves
    /// the upstream `%PUBLIC_URL%` escape hatch used by CRA templates.
    pub fn decodeFaultTolerantSlice(
        dest: []u8,
        input: string,
        needs_redirect: ?*bool,
        comptime fault_tolerant: bool,
    ) !u32 {
        var i: usize = 0;
        var written: u32 = 0;
        while (i < input.len) {
            switch (input[i]) {
                '%' => {
                    if (comptime fault_tolerant) {
                        if (!(i + 3 <= input.len and isASCIIHexDigit(input[i + 1]) and isASCIIHexDigit(input[i + 2]))) {
                            if (i + "PUBLIC_URL%".len < input.len and strings.eqlComptime(input[i + 1 ..][0.."PUBLIC_URL%".len], "PUBLIC_URL%")) {
                                i += "PUBLIC_URL%".len + 1;
                                if (needs_redirect) |nr| nr.* = true;
                                continue;
                            }
                            return error.DecodingError;
                        }
                    } else {
                        if (!(i + 3 <= input.len and isASCIIHexDigit(input[i + 1]) and isASCIIHexDigit(input[i + 2])))
                            return error.DecodingError;
                    }

                    dest[written] = (toASCIIHexValue(input[i + 1]) << 4) | toASCIIHexValue(input[i + 2]);
                    i += 3;
                    written += 1;
                    continue;
                },
                else => {
                    const start = i;
                    i += 1;
                    while (i < input.len and input[i] != '%') : (i += 1) {}
                    @memmove(dest[written .. written + (i - start)], input[start..i]);
                    written += @as(u32, @truncate(i - start));
                },
            }
        }

        return written;
    }
};

// ---- bun.copy shim ------------------------------------------------------
// Mirrors `bun.copy` (memmove over byte-sliced views). Inlined to avoid
// pulling the whole `bun.zig` core leaf for one helper.
fn copy(comptime T: type, dest: []T, src: []const T) void {
    const input: []const u8 = std.mem.sliceAsBytes(src);
    const output: []u8 = std.mem.sliceAsBytes(dest);
    @memmove(output[0..input.len], input);
}

const string = []const u8;

const std = @import("std");
const strings = struct {
    pub inline fn eqlComptime(a: []const u8, comptime b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub inline fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub inline fn endsWithComptime(a: []const u8, comptime b: []const u8) bool {
        return std.mem.endsWith(u8, a, b);
    }

    pub inline fn containsChar(a: []const u8, c: u8) bool {
        return std.mem.indexOfScalar(u8, a, c) != null;
    }
};

// ---- Tests -------------------------------------------------------------

test "pathWithoutAssetPrefix strips matching prefix" {
    const p = URLPath{ .path = "_next/static/foo.js" };
    try std.testing.expectEqualStrings("static/foo.js", p.pathWithoutAssetPrefix("/_next/"));
    try std.testing.expectEqualStrings("_next/static/foo.js", p.pathWithoutAssetPrefix(""));
}

test "pathWithoutAssetPrefix strips .map suffix when source map and asset prefix set" {
    // The empty-asset-prefix code path short-circuits on the raw `path`, so
    // the `.map` strip only triggers when an asset prefix is supplied.
    const p = URLPath{ .path = "_next/foo.js.map", .is_source_map = true };
    try std.testing.expectEqualStrings("foo.js", p.pathWithoutAssetPrefix("/_next/"));
}

test "isRoot matches '.' and 'index'" {
    const root_dot = URLPath{ .path = "." };
    try std.testing.expect(root_dot.isRoot(""));

    const index = URLPath{ .path = "index" };
    try std.testing.expect(index.isRoot(""));

    const other = URLPath{ .path = "about" };
    try std.testing.expect(!other.isRoot(""));
}

test "parse extracts extname, query, first_segment from simple path" {
    const url = try parse("/static/app.js?v=1");
    try std.testing.expectEqualStrings("js", url.extname);
    try std.testing.expectEqualStrings("?v=1", url.query_string);
    try std.testing.expectEqualStrings("static", url.first_segment);
    try std.testing.expectEqualStrings("static/app.js", url.path);
    try std.testing.expect(!url.is_source_map);
}

test "parse marks source maps and reports the underlying extname" {
    const url = try parse("/foo.js.map");
    try std.testing.expect(url.is_source_map);
    try std.testing.expectEqualStrings("js", url.extname);
}

test "parse decodes percent-encoded bytes" {
    const url = try parse("/hello%20world.txt");
    try std.testing.expectEqualStrings("txt", url.extname);
    try std.testing.expectEqualStrings("hello world.txt", url.path);
    try std.testing.expect(!url.needs_redirect);
}

test "parse tolerates %PUBLIC_URL% and sets needs_redirect" {
    const url = try parse("/%PUBLIC_URL%/logo.png");
    try std.testing.expect(url.needs_redirect);
    try std.testing.expectEqualStrings("png", url.extname);
}

test "parse rejects malformed percent escapes" {
    try std.testing.expectError(error.DecodingError, parse("/foo%ZZ"));
}
