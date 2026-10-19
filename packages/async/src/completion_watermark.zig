//! Fixed-boundary FIFO completion, independent of producer/worker lifetimes.
//! Allocation-free; the caller serializes access and owns wakeups/storage.
const std = @import("std");
pub const Result = union(enum) { pending, success, failure: i32 };
pub const Watermark = struct {
    issued: u64 = 0,
    completed: u64 = 0,
    failure: ?i32 = null,
    pub fn reserve(self: *Watermark) !u64 {
        if (self.failure != null) return error.Closed;
        if (self.issued == std.math.maxInt(u64)) return error.SequenceOverflow;
        self.issued += 1;
        return self.issued;
    }
    pub fn complete(self: *Watermark) !void {
        if (self.failure != null) return error.Closed;
        if (self.completed == self.issued) return error.NothingPending;
        self.completed += 1;
    }
    pub fn fail(self: *Watermark, code: i32) void {
        if (self.failure == null) self.failure = code;
    }
    pub fn poll(self: Watermark, target: u64) !Result {
        if (target > self.issued) return error.InvalidTarget;
        // A later failure cannot poison an already completed prefix.
        if (target <= self.completed) return .success;
        if (self.failure) |code| return .{ .failure = code };
        return .pending;
    }
};
test "fixed prefix completes despite later admissions and failures" {
    var w: Watermark = .{};
    try std.testing.expectEqual(Result.success, try w.poll(0));
    const first = try w.reserve();
    try std.testing.expectEqual(Result.pending, try w.poll(first));
    const second = try w.reserve();
    try w.complete();
    try std.testing.expectEqual(Result.success, try w.poll(first));
    try std.testing.expectEqual(Result.pending, try w.poll(second));
    w.fail(-6);
    w.fail(-4);
    try std.testing.expectEqual(Result.success, try w.poll(first));
    try std.testing.expectEqual(@as(i32, -6), (try w.poll(second)).failure);
    try std.testing.expectError(error.Closed, w.reserve());
    try std.testing.expectError(error.Closed, w.complete());
}
test "invalid acknowledgements and overflow leave the watermark unchanged" {
    var w: Watermark = .{};
    try std.testing.expectError(error.NothingPending, w.complete());
    try std.testing.expectError(error.InvalidTarget, w.poll(1));
    w.issued = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceOverflow, w.reserve());
    try std.testing.expectEqual(std.math.maxInt(u64), w.issued);
}
