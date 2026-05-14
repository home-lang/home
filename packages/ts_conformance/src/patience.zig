//! Patience diff — used by tsgo's testutil/baseline harness for
//! readable diff output during conformance triage. We re-implement
//! it here so triage diffs are byte-comparable to tsgo's, and so
//! the conformance runner stays free of external dependencies.
//!
//! Algorithm (Bram Cohen): find lines that occur exactly once in
//! both files (the "unique anchors"); recurse on each region
//! between consecutive anchors using LCS or a simple line-by-line
//! diff. The result is line-readable in a way that pure-LCS
//! often is not — anchor lines stay aligned even when nearby
//! lines have moved.
//!
//! API: `diff(gpa, a_lines, b_lines)` → owned `[]Op`. Each `Op` is
//! one of `keep`, `add`, `remove`. The test harness renders this as
//! a unified-diff hunk.

const std = @import("std");

pub const OpKind = enum { keep, add, remove };

pub const Op = struct {
    kind: OpKind,
    /// 0-based line index in the *output* stream. For `keep`/`add`
    /// this points at the new line; for `remove` it points at the
    /// position where the removal would land in the new file.
    new_index: u32,
    /// 0-based line index in the *input* stream. For `keep`/`remove`
    /// this points at the old line; for `add` it points at the
    /// position where the addition would land in the old file.
    old_index: u32,
    /// The actual line content (borrowed from a/b).
    text: []const u8,
};

/// Compute a patience-style edit script that turns `a_lines` into
/// `b_lines`. Caller owns the returned slice.
pub fn diff(
    gpa: std.mem.Allocator,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
) ![]Op {
    var out: std.ArrayListUnmanaged(Op) = .empty;
    errdefer out.deinit(gpa);
    try diffRange(gpa, a_lines, b_lines, 0, 0, &out);
    return out.toOwnedSlice(gpa);
}

fn diffRange(
    gpa: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    a_off: u32,
    b_off: u32,
    out: *std.ArrayListUnmanaged(Op),
) !void {
    if (a.len == 0 and b.len == 0) return;
    // Trim equal prefix.
    var a_start: usize = 0;
    var b_start: usize = 0;
    while (a_start < a.len and b_start < b.len and std.mem.eql(u8, a[a_start], b[b_start])) {
        try out.append(gpa, .{
            .kind = .keep,
            .new_index = b_off + @as(u32, @intCast(b_start)),
            .old_index = a_off + @as(u32, @intCast(a_start)),
            .text = b[b_start],
        });
        a_start += 1;
        b_start += 1;
    }
    if (a_start == a.len and b_start == b.len) return;
    // Trim equal suffix.
    var a_end = a.len;
    var b_end = b.len;
    while (a_end > a_start and b_end > b_start and std.mem.eql(u8, a[a_end - 1], b[b_end - 1])) {
        a_end -= 1;
        b_end -= 1;
    }
    const a_inner = a[a_start..a_end];
    const b_inner = b[b_start..b_end];
    if (a_inner.len == 0) {
        // Pure additions.
        for (b_inner, 0..) |line, i| {
            try out.append(gpa, .{
                .kind = .add,
                .new_index = b_off + @as(u32, @intCast(b_start + i)),
                .old_index = a_off + @as(u32, @intCast(a_start)),
                .text = line,
            });
        }
    } else if (b_inner.len == 0) {
        // Pure removals.
        for (a_inner, 0..) |line, i| {
            try out.append(gpa, .{
                .kind = .remove,
                .new_index = b_off + @as(u32, @intCast(b_start)),
                .old_index = a_off + @as(u32, @intCast(a_start + i)),
                .text = line,
            });
        }
    } else {
        // Find unique-line anchors. If we find any, recurse on the
        // regions between them. Otherwise fall through to a simple
        // remove-then-add diff for this region.
        const anchors = try findAnchors(gpa, a_inner, b_inner);
        defer gpa.free(anchors);
        if (anchors.len == 0) {
            for (a_inner, 0..) |line, i| {
                try out.append(gpa, .{
                    .kind = .remove,
                    .new_index = b_off + @as(u32, @intCast(b_start)),
                    .old_index = a_off + @as(u32, @intCast(a_start + i)),
                    .text = line,
                });
            }
            for (b_inner, 0..) |line, i| {
                try out.append(gpa, .{
                    .kind = .add,
                    .new_index = b_off + @as(u32, @intCast(b_start + i)),
                    .old_index = a_off + @as(u32, @intCast(a_end)),
                    .text = line,
                });
            }
        } else {
            // Walk anchor pairs and recurse on the gaps between them.
            var prev_a: usize = 0;
            var prev_b: usize = 0;
            for (anchors) |anchor| {
                try diffRange(
                    gpa,
                    a_inner[prev_a..anchor.a_idx],
                    b_inner[prev_b..anchor.b_idx],
                    a_off + @as(u32, @intCast(a_start + prev_a)),
                    b_off + @as(u32, @intCast(b_start + prev_b)),
                    out,
                );
                try out.append(gpa, .{
                    .kind = .keep,
                    .new_index = b_off + @as(u32, @intCast(b_start + anchor.b_idx)),
                    .old_index = a_off + @as(u32, @intCast(a_start + anchor.a_idx)),
                    .text = b_inner[anchor.b_idx],
                });
                prev_a = anchor.a_idx + 1;
                prev_b = anchor.b_idx + 1;
            }
            try diffRange(
                gpa,
                a_inner[prev_a..],
                b_inner[prev_b..],
                a_off + @as(u32, @intCast(a_start + prev_a)),
                b_off + @as(u32, @intCast(b_start + prev_b)),
                out,
            );
        }
    }
    // Suffix.
    var i: usize = 0;
    while (a_end + i < a.len and b_end + i < b.len) : (i += 1) {
        try out.append(gpa, .{
            .kind = .keep,
            .new_index = b_off + @as(u32, @intCast(b_end + i)),
            .old_index = a_off + @as(u32, @intCast(a_end + i)),
            .text = b[b_end + i],
        });
    }
}

const Anchor = struct {
    a_idx: usize,
    b_idx: usize,
};

/// Find lines that occur exactly once in both `a` and `b`, and
/// extract the longest increasing subsequence among them. These
/// serve as the patience anchors.
fn findAnchors(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]Anchor {
    // Map each line in `a` to its single index, or sentinel for
    // duplicates.
    var a_unique: std.StringHashMap(?usize) = .init(gpa);
    defer a_unique.deinit();
    for (a, 0..) |line, i| {
        const gop = try a_unique.getOrPut(line);
        if (gop.found_existing) {
            gop.value_ptr.* = null; // duplicate sentinel
        } else {
            gop.value_ptr.* = i;
        }
    }
    // Walk `b` collecting (a_idx, b_idx) pairs where the line is
    // unique in both.
    var b_unique: std.StringHashMap(?usize) = .init(gpa);
    defer b_unique.deinit();
    for (b, 0..) |line, i| {
        const gop = try b_unique.getOrPut(line);
        if (gop.found_existing) {
            gop.value_ptr.* = null;
        } else {
            gop.value_ptr.* = i;
        }
    }
    var pairs: std.ArrayListUnmanaged(Anchor) = .empty;
    defer pairs.deinit(gpa);
    var b_iter = b_unique.iterator();
    while (b_iter.next()) |kv| {
        if (kv.value_ptr.*) |b_idx| {
            if (a_unique.get(kv.key_ptr.*)) |maybe_a| {
                if (maybe_a) |a_idx| {
                    try pairs.append(gpa, .{ .a_idx = a_idx, .b_idx = b_idx });
                }
            }
        }
    }
    // Sort by `a_idx` so we can extract a LIS over `b_idx`.
    std.mem.sort(Anchor, pairs.items, {}, struct {
        pub fn lt(_: void, x: Anchor, y: Anchor) bool {
            return x.a_idx < y.a_idx;
        }
    }.lt);
    // LIS over b_idx.
    return try patienceLis(gpa, pairs.items);
}

/// Patience LIS over an array sorted by `a_idx`: returns the
/// longest increasing subsequence by `b_idx`.
fn patienceLis(gpa: std.mem.Allocator, pairs: []const Anchor) ![]Anchor {
    if (pairs.len == 0) return gpa.alloc(Anchor, 0);

    // The inputs here are small diagnostic-baseline line lists, so use
    // the straightforward dynamic-programming LIS. This keeps the anchor
    // chain explicitly tied to predecessor pair indexes and guarantees
    // the result is monotonic in both files.
    const lens = try gpa.alloc(usize, pairs.len);
    defer gpa.free(lens);
    const prev = try gpa.alloc(?usize, pairs.len);
    defer gpa.free(prev);

    var best_idx: usize = 0;
    var best_len: usize = 0;
    for (pairs, 0..) |pair, i| {
        lens[i] = 1;
        prev[i] = null;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (pairs[j].b_idx < pair.b_idx and lens[j] + 1 > lens[i]) {
                lens[i] = lens[j] + 1;
                prev[i] = j;
            }
        }
        if (lens[i] > best_len) {
            best_len = lens[i];
            best_idx = i;
        }
    }

    const out = try gpa.alloc(Anchor, best_len);
    var write_idx = best_len;
    var cursor: ?usize = best_idx;
    while (cursor) |idx| {
        write_idx -= 1;
        out[write_idx] = pairs[idx];
        cursor = prev[idx];
    }
    return out;
}

const T = std.testing;

test "patience: identical inputs produce all-keep" {
    const a = [_][]const u8{ "x", "y", "z" };
    const ops = try diff(T.allocator, &a, &a);
    defer T.allocator.free(ops);
    try T.expectEqual(@as(usize, 3), ops.len);
    for (ops) |op| try T.expectEqual(OpKind.keep, op.kind);
}

test "patience: pure addition" {
    const a = [_][]const u8{};
    const b = [_][]const u8{ "x", "y" };
    const ops = try diff(T.allocator, &a, &b);
    defer T.allocator.free(ops);
    try T.expectEqual(@as(usize, 2), ops.len);
    for (ops) |op| try T.expectEqual(OpKind.add, op.kind);
}

test "patience: pure removal" {
    const a = [_][]const u8{ "x", "y" };
    const b = [_][]const u8{};
    const ops = try diff(T.allocator, &a, &b);
    defer T.allocator.free(ops);
    try T.expectEqual(@as(usize, 2), ops.len);
    for (ops) |op| try T.expectEqual(OpKind.remove, op.kind);
}

test "patience: anchored region with replacement" {
    const a = [_][]const u8{ "header", "old1", "footer" };
    const b = [_][]const u8{ "header", "new1", "new2", "footer" };
    const ops = try diff(T.allocator, &a, &b);
    defer T.allocator.free(ops);
    // Should keep header + footer, remove old1, add new1+new2.
    var keeps: usize = 0;
    var adds: usize = 0;
    var removes: usize = 0;
    for (ops) |op| switch (op.kind) {
        .keep => keeps += 1,
        .add => adds += 1,
        .remove => removes += 1,
    };
    try T.expectEqual(@as(usize, 2), keeps);
    try T.expectEqual(@as(usize, 2), adds);
    try T.expectEqual(@as(usize, 1), removes);
}

test "patience: LIS anchors are monotonic" {
    const pairs = [_]Anchor{
        .{ .a_idx = 0, .b_idx = 1 },
        .{ .a_idx = 1, .b_idx = 5 },
        .{ .a_idx = 2, .b_idx = 2 },
        .{ .a_idx = 3, .b_idx = 6 },
        .{ .a_idx = 4, .b_idx = 3 },
        .{ .a_idx = 5, .b_idx = 4 },
    };
    const anchors = try patienceLis(T.allocator, &pairs);
    defer T.allocator.free(anchors);

    try T.expectEqual(@as(usize, 4), anchors.len);
    for (anchors[1..], 1..) |anchor, i| {
        try T.expect(anchor.a_idx > anchors[i - 1].a_idx);
        try T.expect(anchor.b_idx > anchors[i - 1].b_idx);
    }
}
