//! Soft rotation thresholds: caller stages a keyframe-aligned split when due.
const std = @import("std");
pub const Policy = struct {
    duration_ns: u64 = 0,
    max_bytes: u64 = 0,
    pub fn due(s: Policy, frames: u64, elapsed_ns: u64, bytes: u64, pending: bool) bool {
        return frames > 0 and !pending and ((s.duration_ns != 0 and elapsed_ns >= s.duration_ns) or (s.max_bytes != 0 and bytes >= s.max_bytes));
    }
};
test "thresholds include equality, ignore empty and pending segments, and can disable" {
    const p = Policy{ .duration_ns = 100, .max_bytes = 200 };
    try std.testing.expect(!p.due(0, 100, 200, false));
    try std.testing.expect(!p.due(1, 100, 200, true));
    try std.testing.expect(!p.due(1, 99, 199, false));
    try std.testing.expect(p.due(1, 100, 0, false));
    try std.testing.expect(p.due(1, 0, 200, false));
    try std.testing.expect(!(Policy{}).due(1, 100, 200, false));
}
