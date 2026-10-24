const std = @import("std");
const core = @import("kms_discovery.zig");
const t = std.testing;
const Driver = struct {
    pub const Fd = i32;
    last_errno: i32 = 0,
    opened: usize = 0,
    closed: usize = 0,
    resource_calls: usize = 0,
    fail: ?core.Stage = null,
    race: bool = false,
    missing_encoder: bool = false,
    permission: bool = false,
    overflow: bool = false,
    fn check(self: *@This(), stage: core.Stage) !void {
        if (self.fail == stage) {
            self.last_errno = 5;
            return error.SystemQuery;
        }
    }
    pub fn open(self: *@This(), path: [:0]const u8) !Fd {
        if (self.permission and std.mem.endsWith(u8, path, "card1")) {
            self.last_errno = 13;
            return error.SystemQuery;
        }
        if (!std.mem.endsWith(u8, path, "card0")) {
            self.last_errno = 2;
            return error.FileNotFound;
        }
        try self.check(.open);
        self.opened += 1;
        return 0; // descriptor zero is valid.
    }
    pub fn close(self: *@This(), fd: Fd) void {
        std.debug.assert(fd == 0);
        self.closed += 1;
    }
    pub fn capabilities(_: *@This(), _: Fd) core.Capabilities {
        return .{ .atomic = true, .universal = true };
    }
    pub fn resources(self: *@This(), _: Fd, out: *core.Resources) !void {
        self.resource_calls += 1;
        try self.check(if (self.resource_calls % 2 == 0) .recheck else .resources);
        out.* = .{};
        out.crtc_count = 2;
        out.crtcs[0..2].* = .{ 10, 11 };
        out.connector_count = 2;
        out.connectors[0..2].* = .{ 20, 21 };
        out.encoder_count = 2;
        out.encoders[0..2].* = .{ 30, 31 };
        if (self.race and self.resource_calls % 2 == 0) out.connectors[1] = 22;
        if (self.overflow) out.crtc_count = 33;
    }
    pub fn encoder(self: *@This(), _: Fd, id: u32, out: *core.Encoder) !void {
        try self.check(.encoder);
        out.* = .{ .id = id, .crtc = if (id == 30) 10 else 0, .possible = if (id == 30) 1 else 2 };
    }
    pub fn crtc(self: *@This(), _: Fd, id: u32, out: *core.Crtc) !void {
        try self.check(.crtc);
        out.* = .{ .id = id, .active = id == 10, .mode = .{ .width = 1920, .height = 1080 } };
    }
    pub fn planes(self: *@This(), _: Fd, out: *core.PlaneIds) !void {
        try self.check(.planes);
        out.* = .{};
        out.count = 3;
        out.ids[0..3].* = .{ 40, 41, 42 };
    }
    pub fn plane(self: *@This(), _: Fd, id: u32, out: *core.Plane) !void {
        try self.check(.plane);
        out.* = .{ .id = id, .possible = if (id == 40) 1 else if (id == 41) 2 else 3 };
        try out.formats.include(if (id == 40) &.{ core.catalog.fourcc("XR24"), core.catalog.fourcc("NV12") } else if (id == 41) &.{core.catalog.fourcc("RG24")} else &.{ core.catalog.fourcc("NV12"), 0xdeadbeef });
    }
    pub fn connector(self: *@This(), _: Fd, id: u32, out: *core.Connector) !void {
        try self.check(.connector);
        out.* = .{ .id = id, .kind = 11, .number = if (id == 20) 1 else 2, .status = if (id == 20) 1 else 2, .encoder = if (id == 20) 30 else 0, .width_mm = 600, .height_mm = 340 };
        out.encoder_count = 1;
        out.encoders[0] = if (id == 20) 30 else if (self.missing_encoder) 999 else 31;
        out.mode_count = 2;
        out.modes[0] = .{ .width = 800, .height = 600 };
        out.modes[1] = .{ .width = 1280, .height = 720, .preferred = true };
    }
};
test "KMS connector capabilities use possible CRTC indexes and preserve unknown formats" {
    var driver: Driver = .{};
    var result: core.Result = .{};
    try result.scan(Driver, &driver, null);
    try t.expectEqual(@as(u32, 64), result.cards_tried);
    try t.expectEqual(@as(u32, 1), result.cards_opened);
    try t.expectEqual(driver.opened, driver.closed);
    try t.expectEqual(@as(usize, 2), result.display_count);
    try t.expectEqual(@as(usize, 0), result.issue_count);
    const first = &result.displays[0];
    try t.expectEqualStrings("HDMI-A-1", std.mem.sliceTo(&first.name, 0));
    try t.expectEqual(@as(u32, 1920), first.active.width);
    try t.expectEqual(@as(u32, 1280), first.preferred.width);
    try t.expectEqualSlices(u32, &.{10}, first.crtcs[0..first.crtc_count]);
    try t.expectEqualSlices(u32, &.{ core.catalog.fourcc("XR24"), core.catalog.fourcc("NV12"), 0xdeadbeef }, first.formats.slice());
    const second = &result.displays[1];
    try t.expectEqual(@as(u32, 0), second.active.width);
    try t.expectEqual(@as(u32, 0), second.preferred.width);
    try t.expectEqualSlices(u32, &.{11}, second.crtcs[0..second.crtc_count]);
    try t.expectEqualSlices(u32, &.{ core.catalog.fourcc("RG24"), core.catalog.fourcc("NV12"), 0xdeadbeef }, second.formats.slice());
}
test "KMS every query error retires the card FD and publishes no partial card" {
    for (std.meta.tags(core.Stage)) |stage| {
        var driver = Driver{ .fail = stage };
        var result: core.Result = .{};
        try result.scan(Driver, &driver, "/dev/dri/card0");
        try t.expectEqual(driver.opened, driver.closed);
        try t.expectEqual(@as(usize, 0), result.display_count);
        try t.expectEqual(@as(usize, 1), result.issue_count);
        try t.expectEqual(stage, result.issues[0].stage);
        try t.expectEqual(@as(i32, 5), result.issues[0].errno_value);
    }
}
test "KMS changed IDs and late missing encoders discard all card records without retries" {
    for (0..3) |i| {
        var driver = Driver{ .race = i == 0, .missing_encoder = i == 1, .overflow = i == 2 };
        var result: core.Result = .{};
        try result.scan(Driver, &driver, "/dev/dri/card0");
        try t.expectEqual(@as(usize, 0), result.display_count);
        try t.expectEqual(driver.opened, driver.closed);
        try t.expectEqual(if (i == 2) core.Reason.limit else core.Reason.race, result.issues[0].reason);
    }
}
test "KMS inaccessible and exact absent cards are visible while automatic absent nodes are normal" {
    var driver = Driver{ .permission = true };
    var result: core.Result = .{};
    try result.scan(Driver, &driver, null);
    try t.expectEqual(@as(usize, 2), result.display_count);
    try t.expectEqual(@as(usize, 1), result.issue_count);
    try t.expectEqual(@as(i32, 13), result.issues[0].errno_value);
    try result.scan(Driver, &driver, "/dev/dri/card8");
    try t.expectEqual(@as(usize, 0), result.display_count);
    try t.expectEqual(@as(usize, 1), result.issue_count);
    for ([_][]const u8{ "", "bad\x00path", &@as([64]u8, @splat('a')) }) |path| try t.expectError(error.InvalidPath, result.scan(Driver, &driver, path));
}
