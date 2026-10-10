const std = @import("std");

pub const maximum_window: i64 = 0x7fffffff;

pub const Window = struct {
    limit: u64,
    consumed: u64,

    pub fn available(this: Window) u64 {
        return this.limit -| this.consumed;
    }

    pub fn adjust(this: Window, delta: i64) ?Window {
        const limit = std.math.cast(i64, this.limit) orelse return null;
        const consumed = std.math.cast(i64, this.consumed) orelse return null;
        const current = std.math.sub(i64, limit, consumed) catch return null;
        const value = std.math.add(i64, current, delta) catch return null;
        if (value > maximum_window or value < -maximum_window) return null;
        return if (value >= 0)
            .{ .limit = @intCast(value), .consumed = 0 }
        else
            .{ .limit = 0, .consumed = @intCast(-value) };
    }
};

pub fn acknowledgeSettings(outstanding: *u32) bool {
    if (outstanding.* == 0) return false;
    outstanding.* -= 1;
    return true;
}

test "flow credit remains reusable across cumulative transfers" {
    var window = Window{ .limit = 65535, .consumed = 0 };
    for (0..100000) |_| {
        window.consumed += 32768;
        window = window.adjust(32768).?;
        try std.testing.expectEqual(@as(u64, 65535), window.available());
        try std.testing.expectEqual(@as(u64, 0), window.consumed);
    }
}

test "stream settings reductions retain debt until valid credit restores it" {
    var window = Window{ .limit = 65535, .consumed = 60000 };
    window = window.adjust(16384 - 65535).?;
    try std.testing.expectEqual(@as(u64, 0), window.available());
    try std.testing.expectEqual(@as(u64, 43616), window.consumed);
    window = window.adjust(30000).?;
    try std.testing.expectEqual(@as(u64, 13616), window.consumed);
    window = window.adjust(20000).?;
    try std.testing.expectEqual(@as(u64, 6384), window.available());
}

test "flow bounds reject arithmetic overflow without changing current state" {
    const full = Window{ .limit = maximum_window, .consumed = 0 };
    try std.testing.expect(full.adjust(1) == null);
    try std.testing.expectEqual(@as(u64, maximum_window), full.available());
    try std.testing.expect((Window{ .limit = std.math.maxInt(u64), .consumed = 0 }).adjust(1) == null);
    try std.testing.expect((Window{ .limit = 1, .consumed = 0 }).adjust(std.math.maxInt(i64)) == null);
}

test "settings acknowledgements consume only actual outstanding work" {
    var outstanding: u32 = 2;
    try std.testing.expect(acknowledgeSettings(&outstanding));
    try std.testing.expectEqual(@as(u32, 1), outstanding);
    try std.testing.expect(acknowledgeSettings(&outstanding));
    try std.testing.expectEqual(@as(u32, 0), outstanding);
    try std.testing.expect(!acknowledgeSettings(&outstanding));
    try std.testing.expectEqual(@as(u32, 0), outstanding);
}
