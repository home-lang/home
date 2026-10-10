//! Per-handler coalescing for native filesystem notifications. Distinct paths
//! and event types must survive a single OS notification batch.
pub fn ChangeEvent(comptime Hash: type, comptime Timestamp: type, comptime EventType: type) type {
    return struct {
        hash: Hash = 0,
        event_type: EventType = .change,
        timestamp: Timestamp = 0,

        pub fn emit(this: *@This(), hash: Hash, timestamp: Timestamp, event_type: EventType) bool {
            const elapsed = timestamp -| this.timestamp;
            if (this.timestamp == 0 or elapsed > 1 or this.event_type != event_type or this.hash != hash) {
                this.timestamp = timestamp;
                this.event_type = event_type;
                this.hash = hash;
                return true;
            }
            return false;
        }
    };
}

test "watch coalescing retains distinct paths and event types in the same batch" {
    const std = @import("std");
    const Kind = enum { change, rename };
    inline for (.{ i64, u64 }) |Timestamp| {
        var state: ChangeEvent(u64, Timestamp, Kind) = .{};
        try std.testing.expect(state.emit(1, 100, .change));
        try std.testing.expect(!state.emit(1, 100, .change));
        try std.testing.expect(state.emit(2, 100, .change));
        try std.testing.expect(state.emit(2, 100, .rename));
        try std.testing.expect(!state.emit(2, 100, .rename));
        try std.testing.expect(!state.emit(2, 101, .rename));
        try std.testing.expect(state.emit(2, 102, .rename));
        try std.testing.expectEqual(@as(Timestamp, 102), state.timestamp);
        try std.testing.expect(!state.emit(2, 99, .rename));
        try std.testing.expect(state.emit(3, 99, .rename));
        try std.testing.expectEqual(@as(u64, 3), state.hash);
    }
}
