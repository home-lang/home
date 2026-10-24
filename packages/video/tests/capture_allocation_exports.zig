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
