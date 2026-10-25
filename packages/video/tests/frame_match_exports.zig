const std = @import("std");
const video = @import("video");
test "public video root exports bounded same-clock frame intersection" {
    const decision = try video.frame_match.choose(&.{ 101, 102, 103 }, 2);
    try std.testing.expect(decision.matched());
    try std.testing.expectEqual(@as(u64, 2), decision.skewNs());
    try std.testing.expectEqual(@as(u8, 1), (try video.frame_match.choose(&.{ 0, 10 }, 9)).replace_mask);
}
