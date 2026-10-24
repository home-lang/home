const std = @import("std");
const video = @import("video");
test "public forward-only MP4 owns no allocator and needs no seek callback" {
    const Out = struct {
        bytes: usize = 0,
        fn write(ctx: *anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.bytes += data.len;
        }
    };
    var out: Out = .{};
    var arena: [4096]u8 = undefined;
    const headers = [_]u8{ 0, 0, 0, 4, 0x67, 100, 0, 40, 0, 0, 0, 2, 0x68, 0x80 };
    var writer = try video.mp4_stream.Writer.initAvForward(.{ .context = &out, .write = Out.write }, 128, 96, .h264, &headers, .{ .sample_rate = 48000, .channels = 2, .bitrate = 128000, .delay = 2048, .config = .{ 0x11, 0x90 } }, &arena);
    try writer.frame(&.{ 0, 0, 0, 2, 0x65, 0x80 }, 0, 40000, true);
    try std.testing.expectEqual(@as(usize, 0), out.bytes);
    try writer.startAudio(40000);
    for (0..3) |_| try writer.audio(&.{ 0x21, 0x10 });
    try writer.finish(40000, 1000);
    try std.testing.expect(out.bytes > 0);
}
