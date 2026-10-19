//! Shared video PTS epoch across separately rebased segments. Serialized owner.
const std = @import("std");
pub const Clock = struct {
    first: ?u64 = null,
    last: ?u64 = null,
    /// Source nanoseconds become integer microseconds relative to the first
    /// accepted frame. Reject regressions and sub-microsecond collisions before
    /// mutation. A sink failure must poison its owner, not retry this clock.
    pub fn accept(self: *Clock, source_ns: u64) !u64 {
        const first = self.first orelse source_ns;
        if (source_ns < first) return error.InvalidTimestamp;
        const timestamp = (source_ns - first) / 1000;
        if (self.last) |last| if (source_ns <= last or timestamp <= (last - first) / 1000) return error.InvalidTimestamp;
        self.first = first;
        self.last = source_ns;
        return timestamp;
    }
};
test "shared PTS preserves source gaps across clip boundaries with exact integer epochs" {
    var clock: Clock = .{};
    try std.testing.expectEqual(@as(u64, 0), try clock.accept(9_000_000_123));
    try std.testing.expectEqual(@as(u64, 40_000), try clock.accept(9_040_000_123));
    try std.testing.expectEqual(@as(u64, 200_000), try clock.accept(9_200_000_123));
    const before = clock;
    try std.testing.expectError(error.InvalidTimestamp, clock.accept(9_200_000_999));
    try std.testing.expectEqualDeep(before, clock);
    try std.testing.expectError(error.InvalidTimestamp, clock.accept(0));
    try std.testing.expectEqualDeep(before, clock);
}
test "zero and maximum source clocks do not wrap or lose precision" {
    var clock: Clock = .{};
    try std.testing.expectEqual(@as(u64, 0), try clock.accept(0));
    try std.testing.expectEqual(std.math.maxInt(u64) / 1000, try clock.accept(std.math.maxInt(u64)));
    var late: Clock = .{};
    try std.testing.expectEqual(@as(u64, 0), try late.accept(std.math.maxInt(u64) - 1000));
    try std.testing.expectEqual(@as(u64, 1), try late.accept(std.math.maxInt(u64)));
    try std.testing.expectError(error.InvalidTimestamp, late.accept(std.math.maxInt(u64)));
}
