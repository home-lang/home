const std = @import("std");
const video = @import("video");

test "portable video root exposes persistent capture allocation ownership" {
    const capture = video.capture_allocation;
    const layout = try capture.Layout.init("sensor", &.{try capture.Stream.init(8, 4, 32, 128, 2, "BGR888", 0)});
    var cache = try capture.Cache(2).init(1024, 2);
    const prepared = try cache.checkout(&layout);
    try cache.publish(prepared.claim);
    try cache.release(prepared.claim);
    const reused = try cache.checkout(&layout);
    try std.testing.expect(!reused.fresh);
    try cache.release(reused.claim);
    try cache.finishRetirement(try cache.retireIdle(reused.slot));
    try std.testing.expect(cache.empty());
}

test "portable video root exposes explicit owned synthetic capture backing" {
    const backing = video.capture_backing;
    var owner = try backing.Owner(1, backing.Ram).init(.{ .allocator = std.testing.allocator }, 1024, 1);
    defer owner.close() catch unreachable;
    const layout = try backing.policy.Layout.init("test", &.{try backing.policy.Stream.init(8, 4, 32, 128, 2, "BGR888", 0)});
    const loan = try owner.checkout(&layout);
    try std.testing.expectEqual(@as(c_int, -1), (try owner.view(loan.claim, 0, 0, false)).fd);
    try owner.release(loan.claim);
}
