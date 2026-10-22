//! Allocation-free, caller-serialized frame selection. A rejected observation
//! retains no frame; its owner still delivers/recycles the request normally.
const std = @import("std");
pub const Gate = struct {
    remaining: u32 = 0,
    after_ns: ?u64 = null,
    subtract_exposure: bool = true,
    last_event: ?u64 = null,
    accepted: bool = false,
    require_ready: bool = false,

    /// event is a monotonically increasing completion identity, not a wrapping
    /// sensor sequence. Timestamp and threshold must use the same clock domain.
    /// Missing timing fails without changing state. Equal thresholds qualify;
    /// conservative exposure subtraction saturates at zero, never wraps.
    pub fn observe(self: *Gate, event: u64, sensor_ns: ?u64, exposure_us: ?u32) !bool {
        return self.observeReady(event, sensor_ns, exposure_us, null);
    }
    /// Readiness belongs to this exact observation, not a previous/global state.
    /// Missing or false readiness waits when required. Distinct drops/timestamp
    /// checks still apply; a pending observation cannot qualify on a duplicate.
    pub fn observeReady(self: *Gate, event: u64, sensor_ns: ?u64, exposure_us: ?u32, ready: ?bool) !bool {
        if (self.accepted) return true;
        if (self.last_event) |last| if (event <= last) return false;
        var effective: u64 = 0;
        if (self.after_ns != null) {
            effective = sensor_ns orelse return error.MissingTimestamp;
            if (self.subtract_exposure) effective -|= @as(u64, exposure_us orelse return error.MissingExposure) * 1000;
        }
        self.last_event = event;
        if (self.remaining != 0) {
            self.remaining -= 1;
            return false;
        }
        if (self.after_ns) |threshold| if (effective < threshold) return false;
        if (self.require_ready and ready != true) return false;
        self.accepted = true;
        return true;
    }
};

test "readiness must come from a new qualifying observation and combines with exact drops and timing" {
    var gate: Gate = .{ .require_ready = true, .remaining = 1, .after_ns = 100 };
    try std.testing.expect(!try gate.observeReady(1, 101, 0, true));
    try std.testing.expect(!try gate.observeReady(2, 99, 0, true));
    try std.testing.expect(!try gate.observeReady(3, 100, 0, null));
    const pending = gate;
    try std.testing.expect(!try gate.observeReady(3, 100, 0, true));
    try std.testing.expectEqualDeep(pending, gate);
    try std.testing.expect(!try gate.observeReady(4, 100, 0, false));
    try std.testing.expect(try gate.observeReady(5, 100, 0, true));
    const accepted = gate;
    try std.testing.expect(try gate.observeReady(6, null, null, null));
    try std.testing.expectEqualDeep(accepted, gate);
    var default: Gate = .{};
    try std.testing.expect(try default.observe(0, null, null));
    var required: Gate = .{ .require_ready = true };
    try std.testing.expect(!try required.observe(0, null, null));
    try std.testing.expect(try required.observeReady(1, null, null, true));
}
test "missing required timing does not consume an observation even when readiness is true" {
    var gate: Gate = .{ .require_ready = true, .remaining = 1, .after_ns = 100 };
    const before = gate;
    try std.testing.expectError(error.MissingTimestamp, gate.observeReady(1, null, 0, true));
    try std.testing.expectEqualDeep(before, gate);
    try std.testing.expectError(error.MissingExposure, gate.observeReady(1, 100, null, true));
    try std.testing.expectEqualDeep(before, gate);
    try std.testing.expect(!try gate.observeReady(1, 100, 0, true));
    try std.testing.expect(try gate.observeReady(2, 100, 0, true));
}

test "frame barriers drop distinct observations, then accept the inclusive timing boundary" {
    var gate: Gate = .{ .remaining = 2, .after_ns = 10_000 };
    try std.testing.expect(!try gate.observe(1, 20_000, 5));
    const before = gate;
    try std.testing.expect(!try gate.observe(1, 30_000, 5));
    try std.testing.expect(!try gate.observe(0, 30_000, 5));
    try std.testing.expectEqualDeep(before, gate);
    try std.testing.expect(!try gate.observe(2, 30_000, 5));
    try std.testing.expect(!try gate.observe(3, 14_999, 5));
    try std.testing.expect(try gate.observe(4, 15_000, 5));
    const terminal = gate;
    try std.testing.expect(try gate.observe(0, null, null));
    try std.testing.expectEqualDeep(terminal, gate);
}
test "missing timing preserves admission state and raw sensor mode requires no exposure" {
    var gate: Gate = .{ .remaining = 1, .after_ns = 0 };
    const before = gate;
    try std.testing.expectError(error.MissingTimestamp, gate.observe(1, null, 1));
    try std.testing.expectEqualDeep(before, gate);
    try std.testing.expectError(error.MissingExposure, gate.observe(1, 1000, null));
    try std.testing.expectEqualDeep(before, gate);
    gate.subtract_exposure = false;
    try std.testing.expect(!try gate.observe(1, 0, null));
    try std.testing.expect(try gate.observe(2, 0, null));
    var drops: Gate = .{ .remaining = 1 };
    try std.testing.expect(!try drops.observe(0, null, null));
    try std.testing.expect(try drops.observe(1, null, null));
}
test "frame barriers preserve exact maximum counters and saturate exposure subtraction" {
    var gate: Gate = .{ .remaining = std.math.maxInt(u32) };
    try std.testing.expect(!try gate.observe(std.math.maxInt(u64), null, null));
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, gate.remaining);
    try std.testing.expect(!try gate.observe(std.math.maxInt(u64), null, null));
    var boundary: Gate = .{ .after_ns = std.math.maxInt(u64) };
    try std.testing.expect(!try boundary.observe(1, std.math.maxInt(u64), 1));
    try std.testing.expect(try boundary.observe(2, std.math.maxInt(u64), 0));
    var early: Gate = .{ .after_ns = 1 };
    try std.testing.expect(!try early.observe(1, 2, std.math.maxInt(u32)));
    try std.testing.expect(try early.observe(2, 1001, 1));
}
