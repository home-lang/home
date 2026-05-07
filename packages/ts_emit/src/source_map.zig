//! Source map V3 generator with base64-VLQ encoding.
//!
//! Phase 4 deliverable for TS_PARITY_PLAN. Produces JSON
//! source-map output byte-equivalent to tsc's source-map emitter:
//!
//! ```json
//! {
//!   "version": 3,
//!   "file": "out.js",
//!   "sources": ["in.ts"],
//!   "sourcesContent": ["..."],
//!   "names": ["foo", "bar"],
//!   "mappings": "AAAA;AACA,..."
//! }
//! ```
//!
//! Mapping format per the [V3 spec][v3]:
//!   - Lines separated by `;`
//!   - Segments per line separated by `,`
//!   - Each segment is 1, 4, or 5 base64-VLQ values:
//!       [genCol, srcIdx, srcLine, srcCol, nameIdx?]
//!   - All values are *deltas* from the previous segment's
//!     equivalent value, except `genCol` resets at each line.
//!
//! [v3]: https://sourcemaps.info/spec.html

const std = @import("std");

/// One mapping from a generated-file (line, column) to a source
/// position. Keep `gen_col` zero-based.
pub const Mapping = struct {
    gen_line: u32,
    gen_col: u32,
    /// Index into the `sources` array.
    src_idx: u32,
    src_line: u32,
    src_col: u32,
    /// Index into the `names` array, or `null` if no name.
    name_idx: ?u32,
};

pub const SourceMap = struct {
    gpa: std.mem.Allocator,
    /// File name of the generated output.
    file: []const u8,
    sources: std.ArrayListUnmanaged([]const u8),
    sources_content: std.ArrayListUnmanaged([]const u8),
    names: std.ArrayListUnmanaged([]const u8),
    /// Mappings, sorted by (gen_line, gen_col) before encoding.
    mappings: std.ArrayListUnmanaged(Mapping),

    pub fn init(gpa: std.mem.Allocator, file: []const u8) SourceMap {
        return .{
            .gpa = gpa,
            .file = file,
            .sources = .empty,
            .sources_content = .empty,
            .names = .empty,
            .mappings = .empty,
        };
    }

    pub fn deinit(self: *SourceMap) void {
        self.sources.deinit(self.gpa);
        self.sources_content.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.mappings.deinit(self.gpa);
    }

    /// Add a source file; returns its index.
    pub fn addSource(self: *SourceMap, name: []const u8, content: ?[]const u8) !u32 {
        const idx: u32 = @intCast(self.sources.items.len);
        try self.sources.append(self.gpa, name);
        try self.sources_content.append(self.gpa, content orelse "");
        return idx;
    }

    /// Add a name to the names array; returns its index. Caller is
    /// responsible for de-duping if desired.
    pub fn addName(self: *SourceMap, name: []const u8) !u32 {
        const idx: u32 = @intCast(self.names.items.len);
        try self.names.append(self.gpa, name);
        return idx;
    }

    pub fn addMapping(self: *SourceMap, m: Mapping) !void {
        try self.mappings.append(self.gpa, m);
    }

    /// Populate a basic line-level mapping for `generated` text:
    /// for each generated line (0..N) emit a segment mapping
    /// `(gen_col=0) -> (src_idx, src_line=line, src_col=0)`. Lines
    /// in the generated text are determined by counting `\n` bytes.
    ///
    /// This is a v0 fallback for callers that don't (or can't) record
    /// per-token mappings — it produces a non-empty `"mappings"`
    /// string that decodes back to a coherent line-by-line mapping.
    /// `src_line_count`, when non-null, caps the source line index so
    /// the generated mapping doesn't run past the end of the source.
    pub fn fillLineMappings(
        self: *SourceMap,
        generated: []const u8,
        src_idx: u32,
        src_line_count: ?u32,
    ) !void {
        var line: u32 = 0;
        // First line always gets a mapping.
        try self.addLineMappingClamped(0, src_idx, src_line_count);
        for (generated) |c| {
            if (c == '\n') {
                line += 1;
                try self.addLineMappingClamped(line, src_idx, src_line_count);
            }
        }
    }

    fn addLineMappingClamped(
        self: *SourceMap,
        line: u32,
        src_idx: u32,
        src_line_count: ?u32,
    ) !void {
        const src_line: u32 = if (src_line_count) |n|
            (if (n == 0) 0 else @min(line, n - 1))
        else
            line;
        try self.addMapping(.{
            .gen_line = line,
            .gen_col = 0,
            .src_idx = src_idx,
            .src_line = src_line,
            .src_col = 0,
            .name_idx = null,
        });
    }

    /// Render the source map as a JSON string. Caller owns the result.
    pub fn toJson(self: *SourceMap) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);

        try buf.appendSlice(self.gpa, "{\"version\":3,\"file\":");
        try writeJsonString(&buf, self.gpa, self.file);
        try buf.appendSlice(self.gpa, ",\"sourceRoot\":\"\",\"sources\":[");
        for (self.sources.items, 0..) |s, i| {
            if (i > 0) try buf.append(self.gpa, ',');
            try writeJsonString(&buf, self.gpa, s);
        }
        try buf.appendSlice(self.gpa, "],\"sourcesContent\":[");
        for (self.sources_content.items, 0..) |c, i| {
            if (i > 0) try buf.append(self.gpa, ',');
            try writeJsonString(&buf, self.gpa, c);
        }
        try buf.appendSlice(self.gpa, "],\"names\":[");
        for (self.names.items, 0..) |n, i| {
            if (i > 0) try buf.append(self.gpa, ',');
            try writeJsonString(&buf, self.gpa, n);
        }
        try buf.appendSlice(self.gpa, "],\"mappings\":\"");
        try self.encodeMappings(&buf);
        try buf.appendSlice(self.gpa, "\"}");

        return try buf.toOwnedSlice(self.gpa);
    }

    fn encodeMappings(self: *SourceMap, buf: *std.ArrayListUnmanaged(u8)) !void {
        // Sort mappings by (gen_line, gen_col).
        std.sort.pdq(Mapping, self.mappings.items, {}, mappingLessThan);

        var prev_gen_line: u32 = 0;
        var prev_src_idx: u32 = 0;
        var prev_src_line: u32 = 0;
        var prev_src_col: u32 = 0;
        var prev_name_idx: u32 = 0;
        var prev_gen_col: u32 = 0;
        var first_in_line = true;

        for (self.mappings.items) |m| {
            // Pad for skipped lines.
            while (prev_gen_line < m.gen_line) {
                try buf.append(self.gpa, ';');
                prev_gen_line += 1;
                prev_gen_col = 0;
                first_in_line = true;
            }
            if (!first_in_line) try buf.append(self.gpa, ',');
            first_in_line = false;
            try encodeVlq(buf, self.gpa, deltaSigned(m.gen_col, prev_gen_col));
            prev_gen_col = m.gen_col;
            try encodeVlq(buf, self.gpa, deltaSigned(m.src_idx, prev_src_idx));
            prev_src_idx = m.src_idx;
            try encodeVlq(buf, self.gpa, deltaSigned(m.src_line, prev_src_line));
            prev_src_line = m.src_line;
            try encodeVlq(buf, self.gpa, deltaSigned(m.src_col, prev_src_col));
            prev_src_col = m.src_col;
            if (m.name_idx) |ni| {
                try encodeVlq(buf, self.gpa, deltaSigned(ni, prev_name_idx));
                prev_name_idx = ni;
            }
        }
    }
};

fn mappingLessThan(_: void, a: Mapping, b: Mapping) bool {
    if (a.gen_line != b.gen_line) return a.gen_line < b.gen_line;
    return a.gen_col < b.gen_col;
}

fn deltaSigned(cur: u32, prev: u32) i32 {
    return @as(i32, @intCast(cur)) - @as(i32, @intCast(prev));
}

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Base64-VLQ encode a signed integer per the V3 source map spec.
/// The sign bit goes in the low bit of the first 5-bit group.
pub fn encodeVlq(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, value: i32) !void {
    var v: u32 = if (value < 0)
        ((@as(u32, @intCast(-value))) << 1) | 1
    else
        (@as(u32, @intCast(value))) << 1;
    while (true) {
        var digit = v & 0x1F;
        v >>= 5;
        if (v != 0) digit |= 0x20;
        try buf.append(gpa, base64_alphabet[digit]);
        if (v == 0) return;
    }
}

/// Decode a single base64-VLQ value from `s` starting at `pos`. On
/// success returns `(value, next_pos)`; on truncation returns null.
pub fn decodeVlq(s: []const u8, pos: usize) ?struct { value: i32, next_pos: usize } {
    var p = pos;
    var v: u32 = 0;
    var shift: u5 = 0;
    while (p < s.len) {
        const c = s[p];
        const digit = base64Decode(c) orelse return null;
        p += 1;
        const cont = (digit & 0x20) != 0;
        v |= @as(u32, digit & 0x1F) << shift;
        if (!cont) {
            const negative = (v & 1) != 0;
            const magnitude: i32 = @intCast(v >> 1);
            return .{
                .value = if (negative) -magnitude else magnitude,
                .next_pos = p,
            };
        }
        shift += 5;
    }
    return null;
}

fn base64Decode(c: u8) ?u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            '\x08' => try buf.appendSlice(gpa, "\\b"),
            '\x0C' => try buf.appendSlice(gpa, "\\f"),
            else => {
                if (c < 0x20) {
                    var hex: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(gpa, hex[0..6]);
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "VLQ: zero" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(T.allocator);
    try encodeVlq(&buf, T.allocator, 0);
    try T.expectEqualStrings("A", buf.items);
}

test "VLQ: small positive" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(T.allocator);
    try encodeVlq(&buf, T.allocator, 1);
    try T.expectEqualStrings("C", buf.items);
}

test "VLQ: small negative" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(T.allocator);
    try encodeVlq(&buf, T.allocator, -1);
    try T.expectEqualStrings("D", buf.items);
}

test "VLQ: 16 multi-digit" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(T.allocator);
    try encodeVlq(&buf, T.allocator, 16);
    try T.expectEqualStrings("gB", buf.items);
}

test "VLQ: round-trip" {
    const cases: [10]i32 = .{ 0, 1, -1, 15, 16, -16, 100, -100, 1234567, -987654 };
    for (cases) |v| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(T.allocator);
        try encodeVlq(&buf, T.allocator, v);
        const decoded = decodeVlq(buf.items, 0) orelse return error.DecodeFailed;
        try T.expectEqual(v, decoded.value);
        try T.expectEqual(buf.items.len, decoded.next_pos);
    }
}

test "SourceMap: empty produces minimal JSON" {
    var sm = SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    const json = try sm.toJson();
    defer T.allocator.free(json);
    try T.expect(std.mem.indexOf(u8, json, "\"version\":3") != null);
    try T.expect(std.mem.indexOf(u8, json, "\"file\":\"out.js\"") != null);
    try T.expect(std.mem.indexOf(u8, json, "\"mappings\":\"\"") != null);
}

test "SourceMap: single mapping" {
    var sm = SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    const sidx = try sm.addSource("in.ts", "let x = 1;");
    try sm.addMapping(.{
        .gen_line = 0,
        .gen_col = 0,
        .src_idx = sidx,
        .src_line = 0,
        .src_col = 0,
        .name_idx = null,
    });
    const json = try sm.toJson();
    defer T.allocator.free(json);
    // Single segment of all-zeros encodes to "AAAA".
    try T.expect(std.mem.indexOf(u8, json, "\"mappings\":\"AAAA\"") != null);
    try T.expect(std.mem.indexOf(u8, json, "\"sources\":[\"in.ts\"]") != null);
}

test "SourceMap: multi-segment mapping with names" {
    var sm = SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    const sidx = try sm.addSource("in.ts", "let foo = 1; let bar = 2;");
    const foo = try sm.addName("foo");
    const bar = try sm.addName("bar");
    try sm.addMapping(.{ .gen_line = 0, .gen_col = 0, .src_idx = sidx, .src_line = 0, .src_col = 0, .name_idx = foo });
    try sm.addMapping(.{ .gen_line = 0, .gen_col = 13, .src_idx = sidx, .src_line = 0, .src_col = 13, .name_idx = bar });
    const json = try sm.toJson();
    defer T.allocator.free(json);
    try T.expect(std.mem.indexOf(u8, json, "\"names\":[\"foo\",\"bar\"]") != null);
    // First segment: gen_col=0, src_idx=0, src_line=0, src_col=0, name=0 → "AAAAA"
    // Second segment: ΔgenCol=13, ΔsrcIdx=0, ΔsrcLine=0, ΔsrcCol=13, Δname=1
    //   13 → "a", 0 → "A", 0 → "A", 13 → "a", 1 → "C" → "aAAaC"
    try T.expect(std.mem.indexOf(u8, json, "\"mappings\":\"AAAAA,aAAaC\"") != null);
}

test "SourceMap: multi-line mappings" {
    var sm = SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    _ = try sm.addSource("in.ts", "");
    try sm.addMapping(.{ .gen_line = 0, .gen_col = 0, .src_idx = 0, .src_line = 0, .src_col = 0, .name_idx = null });
    try sm.addMapping(.{ .gen_line = 2, .gen_col = 4, .src_idx = 0, .src_line = 1, .src_col = 0, .name_idx = null });
    const json = try sm.toJson();
    defer T.allocator.free(json);
    // Line 0: "AAAA"; line 1: empty; line 2: ΔgenCol=4, ΔsrcIdx=0, ΔsrcLine=1, ΔsrcCol=0 → "IACA"
    try T.expect(std.mem.indexOf(u8, json, "\"mappings\":\"AAAA;;IACA\"") != null);
}

test "SourceMap: JSON-escapes special chars in source content" {
    var sm = SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    _ = try sm.addSource("in.ts", "let x = \"\\n\";");
    const json = try sm.toJson();
    defer T.allocator.free(json);
    try T.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    try T.expect(std.mem.indexOf(u8, json, "\\\\n") != null);
}

test "SourceMap: fillLineMappings produces non-empty mappings per line" {
    var sm = SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    const sidx = try sm.addSource("in.ts", "let x = 1;\nlet y = 2;\nlet z = 3;");
    const generated = "let x = 1;\nlet y = 2;\nlet z = 3;";
    try sm.fillLineMappings(generated, sidx, 3);
    const json = try sm.toJson();
    defer T.allocator.free(json);

    const mp_pos = std.mem.indexOf(u8, json, "\"mappings\":\"").?;
    const after = json[mp_pos + "\"mappings\":\"".len ..];
    const close = std.mem.indexOf(u8, after, "\"").?;
    const mappings = after[0..close];
    try T.expect(mappings.len > 0);

    // Three lines: ΔgenCol=0, ΔsrcIdx=0, ΔsrcLine=(0|1), ΔsrcCol=0.
    // First "AAAA". Each subsequent "AACA". Joined by ';'.
    try T.expectEqualStrings("AAAA;AACA;AACA", mappings);
}

test "SourceMap: fillLineMappings round-trips via decodeVlq" {
    var sm = SourceMap.init(T.allocator, "out.js");
    defer sm.deinit();
    const sidx = try sm.addSource("in.ts", "a\nb\nc\nd");
    const generated = "a\nb\nc\nd";
    try sm.fillLineMappings(generated, sidx, 4);

    const json = try sm.toJson();
    defer T.allocator.free(json);
    const mp_pos = std.mem.indexOf(u8, json, "\"mappings\":\"").?;
    const after = json[mp_pos + "\"mappings\":\"".len ..];
    const close = std.mem.indexOf(u8, after, "\"").?;
    const mappings = after[0..close];

    var line_idx: u32 = 0;
    var prev_src_line: i32 = 0;
    var iter = std.mem.splitScalar(u8, mappings, ';');
    while (iter.next()) |seg_str| {
        try T.expect(seg_str.len > 0);
        var pos: usize = 0;
        const v0 = decodeVlq(seg_str, pos) orelse return error.DecodeFailed;
        pos = v0.next_pos;
        const v1 = decodeVlq(seg_str, pos) orelse return error.DecodeFailed;
        pos = v1.next_pos;
        const v2 = decodeVlq(seg_str, pos) orelse return error.DecodeFailed;
        pos = v2.next_pos;
        const v3 = decodeVlq(seg_str, pos) orelse return error.DecodeFailed;
        pos = v3.next_pos;
        try T.expectEqual(seg_str.len, pos);
        try T.expectEqual(@as(i32, 0), v0.value);
        try T.expectEqual(@as(i32, 0), v1.value);
        try T.expectEqual(@as(i32, 0), v3.value);
        const expected_delta: i32 = if (line_idx == 0) 0 else 1;
        try T.expectEqual(expected_delta, v2.value);
        prev_src_line += v2.value;
        try T.expectEqual(@as(i32, @intCast(line_idx)), prev_src_line);
        line_idx += 1;
    }
    try T.expectEqual(@as(u32, 4), line_idx);
}
