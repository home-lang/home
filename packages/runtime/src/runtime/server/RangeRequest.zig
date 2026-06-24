// Copied verbatim bun/src/runtime/server/RangeRequest.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
//! Parses an HTTP `Range: bytes=...` request header against a known total
//! size. Only single-range `bytes=start-end` / `bytes=start-` / `bytes=-suffix`
//! forms are supported; multi-range and non-`bytes` units fall back to `.none`
//! (serve full body) rather than 416, matching common static-server behavior.
//!
//! Home divergence: upstream re-exports `fromRequest(req: uws.AnyRequest, ...)`
//! and `rawFromRequest`. Those pull in the `bun.uws` substrate which has not
//! yet been ported (Phase 12.5). The pure parser + resolver are what every
//! caller actually needs; the `uws`-touching helpers will re-attach when
//! `home_rt.uws` lands.

pub const Result = union(enum) {
    /// No Range header (or unsupported form) — serve 200 with the full body.
    none,
    /// Serve 206 with `Content-Range: bytes start-end/total`. `end` is inclusive.
    satisfiable: struct { start: u64, end: u64 },
    /// Serve 416 with `Content-Range: bytes */total`.
    unsatisfiable,
};

/// Parsed Range header before the total size is known. Safe to store on a
/// request context: it owns no slices into the uWS request buffer.
pub const Raw = union(enum) {
    none,
    suffix: u64, // bytes=-N
    bounded: struct { start: u64, end: ?u64 }, // bytes=N-[M]

    pub fn resolve(this: Raw, total: u64) Result {
        return switch (this) {
            .none => .none,
            .suffix => |n| {
                if (n == 0) return .unsatisfiable;
                // RFC 9110 §14.1.3: a positive suffix-length is satisfiable;
                // for an empty representation we serve the whole (0-byte) body.
                if (total == 0) return .none;
                return .{ .satisfiable = .{ .start = total -| n, .end = total - 1 } };
            },
            .bounded => |b| {
                if (b.start >= total) return .unsatisfiable;
                var end = b.end orelse (total - 1);
                if (end < b.start) return .none;
                if (end >= total) end = total - 1;
                return .{ .satisfiable = .{ .start = b.start, .end = end } };
            },
        };
    }
};

/// Match WebKit's parseRange (HTTPParsers.cpp): case-insensitive "bytes",
/// optional whitespace before "=". https://fetch.spec.whatwg.org/#simple-range-header-value
pub fn parseRaw(header: []const u8) Raw {
    var rest = header;
    if (rest.len < 5 or !eqlCaseInsensitiveASCII(rest[0..5], "bytes")) return .none;
    rest = trim(rest[5..], " \t");
    if (rest.len == 0 or rest[0] != '=') return .none;
    rest = rest[1..];

    // Multi-range — not supported, fall through to full body.
    if (home_rt.strings.indexOfChar(rest, ',') != null) return .none;

    const dash = home_rt.strings.indexOfChar(rest, '-') orelse return .none;
    const start_s = trim(rest[0..dash], " \t");
    const end_s = trim(rest[dash + 1 ..], " \t");

    if (start_s.len == 0) {
        const n = std.fmt.parseUnsigned(u64, end_s, 10) catch return .none;
        return .{ .suffix = n };
    }

    const start = std.fmt.parseUnsigned(u64, start_s, 10) catch return .none;
    const end: ?u64 = if (end_s.len == 0) null else std.fmt.parseUnsigned(u64, end_s, 10) catch return .none;
    return .{ .bounded = .{ .start = start, .end = end } };
}

pub fn parse(header: []const u8, total: u64) Result {
    return parseRaw(header).resolve(total);
}

// --- local pure-Zig helpers (no `home_rt.strings.eqlCaseInsensitiveASCII` /
// `.trim` yet; these match the upstream semantics for the byte range
// `parseRaw` exercises). ASCII-only by design — Range headers are ASCII.

inline fn eqlCaseInsensitiveASCII(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (b, 0..) |bc, i| {
        const ac = a[i];
        const ac_lower: u8 = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bc_lower: u8 = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (ac_lower != bc_lower) return false;
    }
    return true;
}

inline fn trim(s: []const u8, comptime chars: []const u8) []const u8 {
    return std.mem.trim(u8, s, chars);
}

/// Re-attached 2026-06-24 (uws is now available): the request-header wrappers.
pub fn fromRequest(req: home_rt.uws.AnyRequest, total: u64) Result {
    const h = req.header("range") orelse return .none;
    return parse(h, total);
}

pub fn rawFromRequest(req: home_rt.uws.AnyRequest) Raw {
    const h = req.header("range") orelse return .none;
    return parseRaw(h);
}

const std = @import("std");
const home_rt = @import("home");

test "RangeRequest.parseRaw: empty header is .none" {
    try std.testing.expectEqual(Raw.none, parseRaw(""));
}

test "RangeRequest.parseRaw: non-bytes unit is .none" {
    try std.testing.expectEqual(Raw.none, parseRaw("items=0-10"));
}

test "RangeRequest.parseRaw: case-insensitive bytes prefix" {
    try std.testing.expect(parseRaw("BYTES=0-9") == .bounded);
    try std.testing.expect(parseRaw("Bytes=0-9") == .bounded);
}

test "RangeRequest.parseRaw: suffix form" {
    const r = parseRaw("bytes=-500");
    try std.testing.expectEqual(@as(u64, 500), r.suffix);
}

test "RangeRequest.parseRaw: bounded with end" {
    const r = parseRaw("bytes=10-20");
    try std.testing.expectEqual(@as(u64, 10), r.bounded.start);
    try std.testing.expectEqual(@as(?u64, 20), r.bounded.end);
}

test "RangeRequest.parseRaw: bounded without end" {
    const r = parseRaw("bytes=42-");
    try std.testing.expectEqual(@as(u64, 42), r.bounded.start);
    try std.testing.expectEqual(@as(?u64, null), r.bounded.end);
}

test "RangeRequest.parseRaw: multi-range falls back to .none" {
    try std.testing.expectEqual(Raw.none, parseRaw("bytes=0-9,20-29"));
}

test "RangeRequest.parseRaw: garbage numbers fall back to .none" {
    try std.testing.expectEqual(Raw.none, parseRaw("bytes=abc-def"));
}

test "RangeRequest.Raw.resolve: bounded inside total is satisfiable" {
    const raw: Raw = .{ .bounded = .{ .start = 10, .end = 20 } };
    const got = raw.resolve(100);
    try std.testing.expectEqual(@as(u64, 10), got.satisfiable.start);
    try std.testing.expectEqual(@as(u64, 20), got.satisfiable.end);
}

test "RangeRequest.Raw.resolve: bounded past end clamps to total-1" {
    const raw: Raw = .{ .bounded = .{ .start = 10, .end = 1000 } };
    const got = raw.resolve(100);
    try std.testing.expectEqual(@as(u64, 99), got.satisfiable.end);
}

test "RangeRequest.Raw.resolve: bounded start >= total is unsatisfiable" {
    const raw: Raw = .{ .bounded = .{ .start = 100, .end = null } };
    try std.testing.expectEqual(Result.unsatisfiable, raw.resolve(100));
}

test "RangeRequest.Raw.resolve: suffix shorter than total returns tail" {
    const raw: Raw = .{ .suffix = 50 };
    const got = raw.resolve(200);
    try std.testing.expectEqual(@as(u64, 150), got.satisfiable.start);
    try std.testing.expectEqual(@as(u64, 199), got.satisfiable.end);
}

test "RangeRequest.Raw.resolve: zero suffix is unsatisfiable" {
    const raw: Raw = .{ .suffix = 0 };
    try std.testing.expectEqual(Result.unsatisfiable, raw.resolve(100));
}

test "RangeRequest.Raw.resolve: suffix on empty representation is .none" {
    const raw: Raw = .{ .suffix = 100 };
    try std.testing.expectEqual(Result.none, raw.resolve(0));
}

test "RangeRequest.parse: end-to-end satisfiable" {
    const got = parse("bytes=0-9", 100);
    try std.testing.expectEqual(@as(u64, 0), got.satisfiable.start);
    try std.testing.expectEqual(@as(u64, 9), got.satisfiable.end);
}

test "RangeRequest.parse: end-to-end unsatisfiable" {
    try std.testing.expectEqual(Result.unsatisfiable, parse("bytes=200-300", 100));
}
