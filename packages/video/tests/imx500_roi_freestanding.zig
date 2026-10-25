const roi = @import("roi");
const observed = @import("observed");
export fn home_imx500_roi_encode(request: *const [4]u32, limits: *const [3]u32, out: *[4]u32) u32 {
    const raw = roi.encode(.{ .x = @bitCast(request[0]), .y = @bitCast(request[1]), .width = request[2], .height = request[3] }, .{ .minimum = limits[0], .maximum = limits[1], .step = limits[2] }) catch return 1;
    out.* = raw;
    return 0;
}
export fn home_observed_payload(current: *const [4]u32, requested: *const [4]u32, force: bool, out: *[4]u32) u32 {
    const Io = struct {
        value: [4]u32,
        pub fn validate(_: *@This()) !void {}
        pub fn read(self: *@This()) ![4]u32 {
            return self.value;
        }
        pub fn write(self: *@This(), value: [4]u32) !void {
            self.value = value;
        }
    };
    var io = Io{ .value = current.* };
    const result = observed.apply([4]u32, &io, requested.*, force);
    if (result.failure != null) return 1;
    out.* = result.current.?;
    return if (result.write_attempted) 2 else 0;
}
