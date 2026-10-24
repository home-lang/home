const std = @import("std");
const video = @import("video");
test "public send cursor does not split datagram acceptance and retains TCP suffixes" {
    var udp = try video.SocketWriteCursor.init(5, 3, .datagram);
    try std.testing.expectError(error.InvalidProgress, udp.accept(1));
    try udp.accept(3);
    try std.testing.expectEqual(@as(u32, 2), try udp.next());
    var tcp = try video.SocketWriteCursor.init(5, 3, .stream);
    try tcp.accept(1);
    try std.testing.expectEqual(@as(u64, 1), tcp.offset);
}
