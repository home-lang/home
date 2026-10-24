const std = @import("std");
const video = @import("video");
test "public video sensor helpers preserve exclusivity exact association and observed controls" {
    var gate = video.manager_gate.Gate{};
    _ = try gate.enterExclusive();
    try std.testing.expectError(error.Busy, gate.enterShared());
    try gate.leaveExclusive();
    try std.testing.expect(video.sensor_node.matches("/base/soc/imx708@1a", "../drivers/imx708", "../../../firmware/devicetree/base/soc/imx708@1a", "imx708"));
    const Io = struct {
        value: bool = false,
        pub fn validate(_: *@This()) !void {}
        pub fn read(self: *@This()) !bool {
            return self.value;
        }
        pub fn write(self: *@This(), value: bool) !void {
            self.value = value;
        }
    };
    var io = Io{};
    const result = video.boolean_control.apply(&io, true);
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(@as(?bool, true), result.changed());
}
