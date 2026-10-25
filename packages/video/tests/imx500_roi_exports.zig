const std = @import("std");
const video = @import("video");
test "public Video exports sentinel ROI and generic observed controls" {
    const raw = try video.imx500_roi.encode(.{ .x = 0, .y = 0, .width = 4056, .height = 3040 }, .{ .minimum = 0, .maximum = 4032, .step = 1 });
    try std.testing.expectEqualDeep([4]u32{ 0, 0, 0, 0 }, raw);
    const Io = struct {
        value: [4]u32 = .{ 0, 0, 0, 0 },
        pub fn validate(_: *@This()) !void {}
        pub fn read(self: *@This()) ![4]u32 {
            return self.value;
        }
        pub fn write(self: *@This(), value: [4]u32) !void {
            self.value = value;
        }
    };
    var io = Io{};
    const out = video.observed_control.apply([4]u32, &io, .{ 1, 2, 3, 4 }, false);
    try std.testing.expect(out.failure == null and out.changed().?);
}
