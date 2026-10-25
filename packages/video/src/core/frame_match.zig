//! Allocation-free intersection of monotonically ordered, same-clock streams.
//! The caller owns one retained candidate per stream. No frames are retained or
//! released here. Sensor first-pixel times are compared without exposure shifts.
const std = @import("std");
pub const max_streams = 8;
pub const Decision = struct {
    earliest_ns: u64,
    latest_ns: u64,
    /// Candidates strictly earlier than latest - tolerance cannot participate
    /// in this or any later tuple, assuming each stream never goes backwards.
    replace_mask: u8,
    pub fn matched(self: Decision) bool {
        return self.replace_mask == 0;
    }
    pub fn skewNs(self: Decision) u64 {
        return self.latest_ns - self.earliest_ns;
    }
};
pub fn choose(timestamps: []const u64, tolerance_ns: u64) !Decision {
    if (timestamps.len < 2 or timestamps.len > max_streams) return error.InvalidStreamCount;
    var first = timestamps[0];
    var last = first;
    for (timestamps[1..]) |stamp| {
        first = @min(first, stamp);
        last = @max(last, stamp);
    }
    var replace: u8 = 0;
    if (last - first > tolerance_ns) {
        // This subtraction is safe because a strictly larger span exists.
        const threshold = last - tolerance_ns;
        for (timestamps, 0..) |stamp, i| if (stamp < threshold) {
            replace |= @as(u8, 1) << @intCast(i);
        };
    }
    return .{ .earliest_ns = first, .latest_ns = last, .replace_mask = replace };
}

test "inclusive skew and replacement mask preserve newer candidates and caller order" {
    const t = std.testing;
    try t.expect((try choose(&.{ 100, 110 }, 10)).matched());
    const next = try choose(&.{ 110, 99, 100, 101, 109, 0, 110, 100 }, 10);
    try t.expectEqual(@as(u8, 0b00100010), next.replace_mask);
    try t.expectEqual(@as(u64, 0), next.earliest_ns);
    try t.expectEqual(@as(u64, 110), next.latest_ns);
    try t.expectEqual(@as(u64, 110), next.skewNs());
    try t.expectEqual(@as(u8, 0b00000101), (try choose(&.{ 0, 9, 1, 10 }, 1)).replace_mask);
    try t.expect((try choose(&.{ 7, 7, 7 }, 0)).matched());
}
test "unsigned endpoints never wrap and invalid counts are rejected before reading" {
    const t = std.testing;
    const last = std.math.maxInt(u64);
    try t.expectEqual(@as(u8, 1), (try choose(&.{ 0, last }, last - 1)).replace_mask);
    try t.expect((try choose(&.{ 0, last }, last)).matched());
    try t.expectEqual(@as(u8, 0b00000010), (try choose(&.{ last, 0 }, 0)).replace_mask);
    try t.expectEqual(last, (try choose(&.{ last, 0 }, 0)).skewNs());
    try t.expectError(error.InvalidStreamCount, choose(&.{}, 0));
    try t.expectError(error.InvalidStreamCount, choose(&.{1}, 0));
    try t.expectError(error.InvalidStreamCount, choose(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 0));
}
test "discarded candidates cannot occur in any future in-tolerance tuple" {
    const t = std.testing;
    // Independent widened distance comparisons, not the threshold expression.
    for (0..16) |a| for (0..16) |b| for (0..16) |c| for (0..16) |tolerance| {
        const stamps = [_]u64{ a, b, c };
        const decision = try choose(&stamps, tolerance);
        var expected: u8 = 0;
        for (stamps, 0..) |stamp, i| for (stamps) |other| {
            const delta: i128 = @as(i128, other) - stamp;
            if (delta > tolerance) expected |= @as(u8, 1) << @intCast(i);
        };
        try t.expectEqual(expected, decision.replace_mask);
        if (!decision.matched()) {
            try t.expect(decision.replace_mask != 7);
            for (stamps, 0..) |stamp, i| if (decision.replace_mask & (@as(u8, 1) << @intCast(i)) != 0) {
                for (0..8) |future| try t.expect(@as(u128, decision.latest_ns) + future - stamp > tolerance);
            };
        }
    };
}
test "one-candidate streaming intersection finds exactly the tuples admitted by exhaustive search" {
    const t = std.testing;
    for (0..5) |offset| for (0..5) |tolerance| {
        const streams = [_][5]u64{ .{ 0, 2, 4, 6, 8 }, .{ offset, offset + 2, offset + 4, offset + 6, offset + 8 }, .{ 1, 3, 5, 7, 9 } };
        var exists = false;
        for (streams[0]) |a| for (streams[1]) |b| for (streams[2]) |c| {
            const hi = @max(a, @max(b, c));
            const lo = @min(a, @min(b, c));
            if (@as(i128, hi) - lo <= tolerance) exists = true;
        };
        var at = [_]usize{ 0, 0, 0 };
        var found = false;
        var steps: usize = 0;
        while (at[0] < 5 and at[1] < 5 and at[2] < 5) {
            steps += 1;
            const decision = try choose(&.{ streams[0][at[0]], streams[1][at[1]], streams[2][at[2]] }, tolerance);
            if (decision.matched()) {
                found = true;
                break;
            }
            for (0..3) |i| if (decision.replace_mask & (@as(u8, 1) << @intCast(i)) != 0) {
                at[i] += 1;
            };
        }
        try t.expectEqual(exists, found);
        try t.expect(steps <= 15);
    };
}
