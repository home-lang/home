//! Hosted Linux KMS queries. No modeset, master acquisition, framebuffer or mmap.
//! Uses public kernel UAPI headers, not libdrm or Home OS register/device code.
const std = @import("std");
pub const core = @import("kms_discovery.zig");
pub const available = @import("builtin").os.tag == .linux;
pub fn scan(result: *core.Result, card: ?[]const u8) !void {
    if (comptime available) {
        var driver: Linux = .{};
        return result.scan(Linux, &driver, card);
    }
    return error.Unsupported;
}
pub const Driver = Linux;
const Linux = if (available) struct {
    pub const c = @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
        @cInclude("errno.h");
        @cInclude("poll.h");
        @cInclude("drm/drm.h");
        @cInclude("drm/drm_mode.h");
    });
    pub const Fd = c_int;
    last_errno: i32 = 0,
    fn failed(self: *@This()) error{ SystemQuery, FileNotFound } {
        self.last_errno = c.__errno_location().*;
        return if (self.last_errno == c.ENOENT) error.FileNotFound else error.SystemQuery;
    }
    pub fn open(self: *@This(), path: [:0]const u8) !Fd {
        const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return self.failed();
        return fd;
    }
    pub fn close(_: *@This(), fd: Fd) void {
        _ = c.close(fd);
    }
    pub fn query(self: *@This(), fd: Fd, request: c_ulong, data: anytype) !void {
        // Interrupted discovery is reported, not retried indefinitely.
        const Request = @typeInfo(@TypeOf(c.ioctl)).@"fn".params[1].type.?;
        const command: Request = if (@sizeOf(Request) == 4) @bitCast(@as(u32, @intCast(request))) else @intCast(request);
        if (c.ioctl(fd, command, data) < 0) return self.failed();
    }
    fn capability(self: *@This(), fd: Fd, key: u64) bool {
        var value = c.struct_drm_set_client_cap{ .capability = key, .value = 1 };
        self.query(fd, c.DRM_IOCTL_SET_CLIENT_CAP, &value) catch return false;
        return true;
    }
    pub fn capabilities(self: *@This(), fd: Fd) core.Capabilities {
        // These alter only this temporary client's query visibility. ATOMIC
        // implies universal planes, but probe universal explicitly for old drivers.
        const atomic = self.capability(fd, c.DRM_CLIENT_CAP_ATOMIC);
        const universal = self.capability(fd, c.DRM_CLIENT_CAP_UNIVERSAL_PLANES) or atomic;
        return .{ .atomic = atomic, .universal = universal };
    }
    pub fn resources(self: *@This(), fd: Fd, out: *core.Resources) !void {
        var value = std.mem.zeroes(c.struct_drm_mode_card_res);
        value.crtc_id_ptr = @intFromPtr(&out.crtcs);
        value.count_crtcs = out.crtcs.len;
        value.connector_id_ptr = @intFromPtr(&out.connectors);
        value.count_connectors = out.connectors.len;
        value.encoder_id_ptr = @intFromPtr(&out.encoders);
        value.count_encoders = out.encoders.len;
        try self.query(fd, c.DRM_IOCTL_MODE_GETRESOURCES, &value);
        out.crtc_count = value.count_crtcs;
        out.connector_count = value.count_connectors;
        out.encoder_count = value.count_encoders;
        try out.validate();
    }
    pub fn encoder(self: *@This(), fd: Fd, id: u32, out: *core.Encoder) !void {
        var value = std.mem.zeroes(c.struct_drm_mode_get_encoder);
        value.encoder_id = id;
        try self.query(fd, c.DRM_IOCTL_MODE_GETENCODER, &value);
        out.* = .{ .id = value.encoder_id, .crtc = value.crtc_id, .possible = value.possible_crtcs };
    }
    pub fn crtc(self: *@This(), fd: Fd, id: u32, out: *core.Crtc) !void {
        var value = std.mem.zeroes(c.struct_drm_mode_crtc);
        value.crtc_id = id;
        try self.query(fd, c.DRM_IOCTL_MODE_GETCRTC, &value);
        out.* = .{ .id = value.crtc_id, .active = value.mode_valid != 0, .mode = .{ .width = value.mode.hdisplay, .height = value.mode.vdisplay } };
    }
    pub fn planes(self: *@This(), fd: Fd, out: *core.PlaneIds) !void {
        var value = std.mem.zeroes(c.struct_drm_mode_get_plane_res);
        value.plane_id_ptr = @intFromPtr(&out.ids);
        value.count_planes = out.ids.len;
        try self.query(fd, c.DRM_IOCTL_MODE_GETPLANERESOURCES, &value);
        out.count = value.count_planes;
        if (out.count > core.max_planes) return error.TopologyLimit;
    }
    pub fn plane(self: *@This(), fd: Fd, id: u32, out: *core.Plane) !void {
        var value = std.mem.zeroes(c.struct_drm_mode_get_plane);
        value.plane_id = id;
        value.format_type_ptr = @intFromPtr(&out.formats.values);
        value.count_format_types = out.formats.values.len;
        try self.query(fd, c.DRM_IOCTL_MODE_GETPLANE, &value);
        if (value.count_format_types > core.catalog.max_formats) return error.TopologyLimit;
        out.id = value.plane_id;
        out.possible = value.possible_crtcs;
        out.formats.count = value.count_format_types;
    }
    pub fn connector(self: *@This(), fd: Fd, id: u32, out: *core.Connector) !void {
        var modes: [core.max_modes]c.struct_drm_mode_modeinfo = undefined;
        var value = std.mem.zeroes(c.struct_drm_mode_get_connector);
        value.connector_id = id;
        value.encoders_ptr = @intFromPtr(&out.encoders);
        value.count_encoders = out.encoders.len;
        // A nonzero capacity retrieves cached modes; do not trigger an invasive
        // count=0 connector probe from a read-only display listing.
        value.modes_ptr = @intFromPtr(&modes);
        value.count_modes = modes.len;
        try self.query(fd, c.DRM_IOCTL_MODE_GETCONNECTOR, &value);
        if (value.count_encoders > core.max_encoders or value.count_modes > core.max_modes) return error.TopologyLimit;
        out.id = value.connector_id;
        out.kind = value.connector_type;
        out.number = value.connector_type_id;
        out.status = value.connection;
        out.encoder = value.encoder_id;
        out.width_mm = value.mm_width;
        out.height_mm = value.mm_height;
        out.encoder_count = value.count_encoders;
        out.mode_count = value.count_modes;
        for (modes[0..out.mode_count], 0..) |mode, i| out.modes[i] = .{ .width = mode.hdisplay, .height = mode.vdisplay, .preferred = mode.type & c.DRM_MODE_TYPE_PREFERRED != 0 };
    }
} else struct {};
// Ensure Linux builds analyze every real query path, even without a DRM node.
test "host KMS discovery closes absent and non-DRM descriptors" {
    if (comptime available) {
        var result: core.Result = .{};
        try scan(&result, "/dev/zig-camera-kms-absent");
        try std.testing.expectEqual(@as(usize, 0), result.display_count);
        try std.testing.expectEqual(@as(usize, 1), result.issue_count);
        try std.testing.expectEqual(core.Stage.open, result.issues[0].stage);
        try scan(&result, "/dev/null");
        try std.testing.expectEqual(@as(usize, 0), result.display_count);
        try std.testing.expectEqual(@as(u32, 1), result.cards_opened);
        try std.testing.expectEqual(core.Stage.resources, result.issues[0].stage);
        try std.testing.expectEqual(@as(i32, 25), result.issues[0].errno_value); // ENOTTY on Linux.
    } else {
        var result: core.Result = .{};
        try std.testing.expectError(error.Unsupported, scan(&result, null));
    }
}
