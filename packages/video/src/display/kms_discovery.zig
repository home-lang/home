//! Bounded KMS topology collection with injectable read-only driver queries.
//! A failed/changed card contributes an issue, never a partial display catalog.
const std = @import("std");
pub const catalog = @import("kms_catalog.zig");
pub const max_cards = 64;
pub const max_displays = 256;
pub const max_connectors = 64;
pub const max_encoders = 128;
pub const max_planes = 128;
pub const max_modes = 128;
pub const Resources = struct {
    crtcs: [32]u32 = undefined,
    crtc_count: usize = 0,
    connectors: [max_connectors]u32 = undefined,
    connector_count: usize = 0,
    encoders: [max_encoders]u32 = undefined,
    encoder_count: usize = 0,
    pub fn validate(self: *const Resources) !void {
        if (self.crtc_count > 32 or self.connector_count > max_connectors or self.encoder_count > max_encoders) return error.TopologyLimit;
        try catalog.validIds(self.crtcs[0..self.crtc_count]);
        try catalog.validIds(self.connectors[0..self.connector_count]);
        try catalog.validIds(self.encoders[0..self.encoder_count]);
    }
    pub fn same(a: *const Resources, b: *const Resources) bool {
        return std.mem.eql(u32, a.crtcs[0..a.crtc_count], b.crtcs[0..b.crtc_count]) and std.mem.eql(u32, a.connectors[0..a.connector_count], b.connectors[0..b.connector_count]) and std.mem.eql(u32, a.encoders[0..a.encoder_count], b.encoders[0..b.encoder_count]);
    }
};
pub const Capabilities = struct { atomic: bool = false, universal: bool = false };
pub const Encoder = struct { id: u32 = 0, crtc: u32 = 0, possible: u32 = 0 };
pub const Mode = struct { width: u32 = 0, height: u32 = 0, preferred: bool = false };
pub const Crtc = struct { id: u32 = 0, active: bool = false, mode: Mode = .{} };
pub const PlaneIds = struct { ids: [max_planes]u32 = undefined, count: usize = 0 };
pub const Plane = struct { id: u32 = 0, possible: u32 = 0, formats: catalog.FormatSet = .{} };
pub const Connector = struct {
    id: u32 = 0,
    kind: u32 = 0,
    number: u32 = 0,
    status: u32 = 3,
    encoder: u32 = 0,
    width_mm: u32 = 0,
    height_mm: u32 = 0,
    encoders: [max_encoders]u32 = undefined,
    encoder_count: usize = 0,
    modes: [max_modes]Mode = undefined,
    mode_count: usize = 0,
};
pub const Display = struct {
    card: [64]u8 = @splat(0),
    name: [32]u8 = @splat(0),
    connector: u32 = 0,
    kind: u32 = 0,
    number: u32 = 0,
    status: u32 = 3,
    current_crtc: u32 = 0,
    active: Mode = .{},
    preferred: Mode = .{},
    width_mm: u32 = 0,
    height_mm: u32 = 0,
    capabilities: Capabilities = .{},
    crtcs: [32]u32 = undefined,
    crtc_count: usize = 0,
    formats: catalog.FormatSet = .{},
};
pub const Stage = enum(u32) { open = 1, resources, encoder, crtc, planes, plane, connector, recheck };
pub const Reason = enum(u32) { system = 1, limit, race, invalid };
pub const Issue = struct { card: [64]u8 = @splat(0), stage: Stage, reason: Reason, errno_value: i32 };
pub const Result = struct {
    displays: [max_displays]Display = undefined,
    display_count: usize = 0,
    issues: [max_cards]Issue = undefined,
    issue_count: usize = 0,
    cards_tried: u32 = 0,
    cards_opened: u32 = 0,
    fn issue(self: *Result, path: []const u8, stage: Stage, err: anyerror, number: i32) void {
        var value = Issue{ .stage = stage, .reason = switch (err) {
            error.TopologyLimit => .limit,
            error.TopologyChanged => .race,
            error.InvalidTopology => .invalid,
            else => .system,
        }, .errno_value = if (err == error.SystemQuery or err == error.FileNotFound) number else 0 };
        @memcpy(value.card[0..path.len], path);
        std.debug.assert(self.issue_count < max_cards);
        self.issues[self.issue_count] = value;
        self.issue_count += 1;
    }
    /// Exact card paths must fit a 64-byte NUL-terminated result field. Auto
    /// scanning tries card0..card63; absent nodes are normal, other failures visible.
    pub fn scan(self: *Result, comptime Driver: type, driver: *Driver, exact: ?[]const u8) !void {
        if (exact) |path| if (path.len == 0 or path.len >= 64 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        self.display_count = 0;
        self.issue_count = 0;
        self.cards_tried = 0;
        self.cards_opened = 0;
        const count: usize = if (exact != null) 1 else max_cards;
        for (0..count) |i| {
            var buffer: [64]u8 = @splat(0);
            const path = exact orelse try std.fmt.bufPrint(buffer[0..63], "/dev/dri/card{d}", .{i});
            if (exact != null) @memcpy(buffer[0..path.len], path);
            buffer[path.len] = 0;
            self.cards_tried += 1;
            const fd = driver.open(buffer[0..path.len :0]) catch |err| {
                if (exact != null or err != error.FileNotFound) self.issue(path, .open, err, driver.last_errno);
                continue;
            };
            defer driver.close(fd);
            self.cards_opened += 1;
            var stage: Stage = .resources;
            const start = self.display_count;
            self.card(Driver, driver, fd, path, &stage) catch |err| {
                self.display_count = start;
                self.issue(path, stage, err, driver.last_errno);
            };
        }
    }
    fn card(self: *Result, comptime Driver: type, driver: *Driver, fd: Driver.Fd, path: []const u8, stage: *Stage) !void {
        const capabilities = driver.capabilities(fd);
        var resources: Resources = .{};
        try driver.resources(fd, &resources);
        try resources.validate();
        const mask = try catalog.crtcMask(resources.crtc_count);
        var encoders: [max_encoders]Encoder = undefined;
        stage.* = .encoder;
        for (resources.encoders[0..resources.encoder_count], 0..) |id, i| {
            try driver.encoder(fd, id, &encoders[i]);
            if (encoders[i].id != id) return error.TopologyChanged;
            if (encoders[i].possible & ~mask != 0) return error.InvalidTopology;
            if (encoders[i].crtc != 0 and std.mem.indexOfScalar(u32, resources.crtcs[0..resources.crtc_count], encoders[i].crtc) == null) return error.TopologyChanged;
        }
        stage.* = .crtc;
        var crtcs: [32]Crtc = undefined;
        for (resources.crtcs[0..resources.crtc_count], 0..) |id, i| {
            try driver.crtc(fd, id, &crtcs[i]);
            if (crtcs[i].id != id) return error.TopologyChanged;
            if (crtcs[i].active and (crtcs[i].mode.width == 0 or crtcs[i].mode.height == 0)) return error.InvalidTopology;
        }
        stage.* = .planes;
        var plane_ids: PlaneIds = .{};
        try driver.planes(fd, &plane_ids);
        if (plane_ids.count > max_planes) return error.TopologyLimit;
        try catalog.validIds(plane_ids.ids[0..plane_ids.count]);
        var planes: [max_planes]Plane = undefined;
        stage.* = .plane;
        for (plane_ids.ids[0..plane_ids.count], 0..) |id, i| {
            planes[i] = .{};
            try driver.plane(fd, id, &planes[i]);
            if (planes[i].id != id) return error.TopologyChanged;
            if (planes[i].formats.count > catalog.max_formats) return error.TopologyLimit;
            if (planes[i].possible & ~mask != 0) return error.InvalidTopology;
        }
        stage.* = .connector;
        for (resources.connectors[0..resources.connector_count]) |id| {
            if (self.display_count == max_displays) return error.TopologyLimit;
            var connector: Connector = .{};
            try driver.connector(fd, id, &connector);
            if (connector.id != id) return error.TopologyChanged;
            if (connector.encoder_count > max_encoders or connector.mode_count > max_modes) return error.TopologyLimit;
            if (connector.status < 1 or connector.status > 3) return error.InvalidTopology;
            try catalog.validIds(connector.encoders[0..connector.encoder_count]);
            var possible: u32 = 0;
            var current: u32 = 0;
            for (connector.encoders[0..connector.encoder_count]) |encoder_id| {
                const index = std.mem.indexOfScalar(u32, resources.encoders[0..resources.encoder_count], encoder_id) orelse return error.TopologyChanged;
                const encoder = encoders[index];
                possible |= encoder.possible;
                if (encoder_id == connector.encoder) current = encoder.crtc;
            }
            if (connector.encoder != 0 and std.mem.indexOfScalar(u32, connector.encoders[0..connector.encoder_count], connector.encoder) == null) return error.TopologyChanged;
            var display = Display{ .connector = id, .kind = connector.kind, .number = connector.number, .status = connector.status, .current_crtc = current, .width_mm = connector.width_mm, .height_mm = connector.height_mm, .capabilities = capabilities };
            @memcpy(display.card[0..path.len], path);
            _ = try catalog.connectorName(display.name[0..31], connector.kind, connector.number);
            for (resources.crtcs[0..resources.crtc_count], 0..) |crtc_id, i| {
                if (possible & (@as(u32, 1) << @as(u5, @intCast(i))) != 0) {
                    display.crtcs[display.crtc_count] = crtc_id;
                    display.crtc_count += 1;
                }
                if (connector.status == 1 and crtc_id == current and crtcs[i].active) display.active = crtcs[i].mode;
            }
            if (connector.status == 1) for (connector.modes[0..connector.mode_count], 0..) |mode, i| {
                if (mode.width == 0 or mode.height == 0) return error.InvalidTopology;
                if (i == 0 or mode.preferred) display.preferred = mode;
                if (mode.preferred) break;
            };
            for (planes[0..plane_ids.count]) |*plane| if (plane.possible & possible != 0) try display.formats.include(plane.formats.slice());
            self.displays[self.display_count] = display;
            self.display_count += 1;
        }
        // No userspace multi-ioctl snapshot can be atomic. Detect changing ID
        // lists without retry loops or publishing an obviously mixed generation.
        stage.* = .recheck;
        var after: Resources = .{};
        try driver.resources(fd, &after);
        try after.validate();
        var planes_after: PlaneIds = .{};
        try driver.planes(fd, &planes_after);
        if (planes_after.count > max_planes) return error.TopologyLimit;
        try catalog.validIds(planes_after.ids[0..planes_after.count]);
        if (!resources.same(&after) or !std.mem.eql(u32, plane_ids.ids[0..plane_ids.count], planes_after.ids[0..planes_after.count])) return error.TopologyChanged;
    }
};
