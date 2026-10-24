//! Direct Linux atomic plane scanout. Source leases live in the caller; Gate
//! tokens identify the two resource slots that MUST stay owned until retirement.
const std = @import("std");
pub const policy = @import("kms_scanout.zig");
const discovery = @import("kms_discovery_host.zig");
pub const available = discovery.available;
pub const Geometry = struct { x: i32 = 0, y: i32 = 0, width: u32, height: u32, rotation: u64 = 1, encoding: ?enum { bt601, bt709, bt2020 } = null, full_range: bool = false };
pub const Options = struct { connector: u32 = 0, plane: u32 = 0, fourcc: u32, timeout_ms: u32 = 1000 };
pub const Device = if (available) Linux else struct {};
const Linux = if (available) struct {
    const Driver = discovery.Driver;
    const c = Driver.c;
    const Slot = struct { fb: u32 = 0, handles: [4]u32 = @splat(0), count: usize = 0, width: u32 = 0, height: u32 = 0 };
    const Properties = struct {
        fb: u32 = 0,
        crtc: u32 = 0,
        src_x: u32 = 0,
        src_y: u32 = 0,
        src_w: u32 = 0,
        src_h: u32 = 0,
        dst_x: u32 = 0,
        dst_y: u32 = 0,
        dst_w: u32 = 0,
        dst_h: u32 = 0,
        rotation: u32 = 0,
        rotation_bits: u64 = 1,
        fixed_rotation: u64 = 1,
        encoding: u32 = 0,
        range: u32 = 0,
        encodings: [3]?u64 = @splat(null),
        ranges: [2]?u64 = @splat(null),
        kind: ?u64 = null,
        alpha: u32 = 0,
        opaque_alpha: u64 = 0,
        restore_ids: [16]u32 = @splat(0),
        restore_values: [16]u64 = @splat(0),
        restore_count: usize = 0,
        unused: bool = true,
        fn complete(p: Properties) bool {
            return p.fb != 0 and p.crtc != 0 and p.src_x != 0 and p.src_y != 0 and p.src_w != 0 and p.src_h != 0 and p.dst_x != 0 and p.dst_y != 0 and p.dst_w != 0 and p.dst_h != 0;
        }
    };
    driver: Driver = .{},
    fd: c_int = -1,
    crtc: u32 = 0,
    plane: u32 = 0,
    connector: u32 = 0,
    screen_width: u32 = 0,
    screen_height: u32 = 0,
    fourcc: u32 = 0,
    timeout_ms: u32 = 1000,
    properties: Properties = .{},
    slots: [2]Slot = @splat(.{}),
    handles: policy.Handles = .{},
    gate: policy.Gate = .{},
    cookie: u64 = 0,
    detach_cookie: ?u64 = null,
    needs_detach: bool = false,
    poisoned: bool = false,
    closed: bool = false,

    /// Exact card path; caller can use the bounded catalog to choose one. Never
    /// takes an occupied plane or changes CRTC/connector modes. One master FD.
    pub fn open(self: *@This(), path: [:0]const u8, options: Options) !void {
        if (options.timeout_ms == 0 or options.timeout_ms > 60000 or options.fourcc == 0) return error.InvalidOptions;
        self.* = .{ .fourcc = options.fourcc, .timeout_ms = options.timeout_ms };
        self.fd = c.open(path.ptr, c.O_RDWR | c.O_CLOEXEC | c.O_NONBLOCK);
        if (self.fd < 0) {
            self.driver.last_errno = c.__errno_location().*;
            return error.SystemQuery;
        }
        errdefer {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (!self.driver.capabilities(self.fd).atomic) return error.Unsupported;
        var no_argument: u32 = 0;
        try self.driver.query(self.fd, c.DRM_IOCTL_SET_MASTER, &no_argument);
        var resources: discovery.core.Resources = .{};
        try self.driver.resources(self.fd, &resources);
        const allowed = try discovery.core.catalog.crtcMask(resources.crtc_count);
        for (resources.connectors[0..resources.connector_count]) |id| {
            if (options.connector != 0 and id != options.connector) continue;
            var conn: discovery.core.Connector = .{};
            try self.driver.connector(self.fd, id, &conn);
            if (conn.status != 1 or conn.encoder == 0) continue;
            var encoder: discovery.core.Encoder = .{};
            try self.driver.encoder(self.fd, conn.encoder, &encoder);
            const index = std.mem.indexOfScalar(u32, resources.crtcs[0..resources.crtc_count], encoder.crtc) orelse continue;
            if (encoder.possible & ~allowed != 0 or encoder.possible & (@as(u32, 1) << @as(u5, @intCast(index))) == 0) return error.InvalidTopology;
            var crtc: discovery.core.Crtc = .{};
            try self.driver.crtc(self.fd, encoder.crtc, &crtc);
            if (!crtc.active or crtc.mode.width == 0 or crtc.mode.height == 0) continue;
            var planes: discovery.core.PlaneIds = .{};
            try self.driver.planes(self.fd, &planes);
            try discovery.core.catalog.validIds(planes.ids[0..planes.count]);
            for (planes.ids[0..planes.count]) |plane_id| {
                if (options.plane != 0 and plane_id != options.plane) continue;
                var formats: [256]u32 = undefined;
                var plane = std.mem.zeroes(c.struct_drm_mode_get_plane);
                plane.plane_id = plane_id;
                plane.format_type_ptr = @intFromPtr(&formats);
                plane.count_format_types = formats.len;
                try self.driver.query(self.fd, c.DRM_IOCTL_MODE_GETPLANE, &plane);
                if (plane.count_format_types > formats.len) return error.TopologyLimit;
                if (plane.fb_id != 0 or plane.crtc_id != 0 or plane.possible_crtcs & (@as(u32, 1) << @as(u5, @intCast(index))) == 0 or std.mem.indexOfScalar(u32, formats[0..plane.count_format_types], options.fourcc) == null) continue;
                const props = try self.readProperties(plane_id);
                if (!props.complete() or props.kind == null or props.kind == 2 or !props.unused) continue;
                self.connector = id;
                self.crtc = crtc.id;
                self.plane = plane_id;
                self.screen_width = crtc.mode.width;
                self.screen_height = crtc.mode.height;
                self.properties = props;
                return;
            }
        }
        return error.Unsupported;
    }
    fn readProperties(self: *@This(), plane: u32) !Properties {
        var ids: [64]u32 = undefined;
        var values: [64]u64 = undefined;
        var request = std.mem.zeroes(c.struct_drm_mode_obj_get_properties);
        request.obj_id = plane;
        request.obj_type = c.DRM_MODE_OBJECT_PLANE;
        request.props_ptr = @intFromPtr(&ids);
        request.prop_values_ptr = @intFromPtr(&values);
        request.count_props = ids.len;
        try self.driver.query(self.fd, c.DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &request);
        if (request.count_props > ids.len) return error.TopologyLimit;
        var result: Properties = .{};
        for (ids[0..request.count_props], 0..) |id, i| {
            var enums: [64]c.struct_drm_mode_property_enum = undefined;
            var ranges: [64]u64 = undefined;
            var property = std.mem.zeroes(c.struct_drm_mode_get_property);
            property.prop_id = id;
            property.count_values = ranges.len;
            property.values_ptr = @intFromPtr(&ranges);
            property.count_enum_blobs = enums.len;
            property.enum_blob_ptr = @intFromPtr(&enums);
            try self.driver.query(self.fd, c.DRM_IOCTL_MODE_GETPROPERTY, &property);
            if (property.count_values > ranges.len or property.count_enum_blobs > enums.len) return error.TopologyLimit;
            const name = boundedName(&property.name) orelse return error.InvalidTopology;
            const mutable = property.flags & c.DRM_MODE_PROP_IMMUTABLE == 0;
            if ((std.mem.eql(u8, name, "FB_ID") or std.mem.eql(u8, name, "CRTC_ID")) and values[i] != 0) result.unused = false;
            if (std.mem.eql(u8, name, "type")) result.kind = values[i];
            var restore = false;
            const fields = .{ .{ "FB_ID", "fb" }, .{ "CRTC_ID", "crtc" }, .{ "SRC_X", "src_x" }, .{ "SRC_Y", "src_y" }, .{ "SRC_W", "src_w" }, .{ "SRC_H", "src_h" }, .{ "CRTC_X", "dst_x" }, .{ "CRTC_Y", "dst_y" }, .{ "CRTC_W", "dst_w" }, .{ "CRTC_H", "dst_h" } };
            inline for (fields) |field| if (std.mem.eql(u8, name, field[0]) and mutable) {
                @field(result, field[1]) = id;
                restore = true;
            };
            if (std.mem.eql(u8, name, "rotation")) {
                result.fixed_rotation = values[i];
                result.rotation_bits = 0;
                if (mutable) {
                    result.rotation = id;
                    restore = true;
                }
                for (enums[0..property.count_enum_blobs]) |entry| {
                    if (entry.value >= 64) return error.InvalidTopology;
                    result.rotation_bits |= @as(u64, 1) << @as(u6, @intCast(entry.value));
                }
            }
            if (std.mem.eql(u8, name, "COLOR_ENCODING") and mutable) {
                result.encoding = id;
                restore = true;
                for (enums[0..property.count_enum_blobs]) |entry| {
                    const text = boundedName(&entry.name) orelse return error.InvalidTopology;
                    for ([_][]const u8{ "ITU-R BT.601 YCbCr", "ITU-R BT.709 YCbCr", "ITU-R BT.2020 YCbCr" }, 0..) |wanted, slot| if (std.mem.eql(u8, wanted, text)) {
                        result.encodings[slot] = entry.value;
                    };
                }
            }
            if (std.mem.eql(u8, name, "COLOR_RANGE") and mutable) {
                result.range = id;
                restore = true;
                for (enums[0..property.count_enum_blobs]) |entry| {
                    const text = boundedName(&entry.name) orelse return error.InvalidTopology;
                    for ([_][]const u8{ "YCbCr limited range", "YCbCr full range" }, 0..) |wanted, slot| if (std.mem.eql(u8, wanted, text)) {
                        result.ranges[slot] = entry.value;
                    };
                }
            }
            if (std.mem.eql(u8, name, "alpha")) {
                if (property.count_values != 2 or property.flags & c.DRM_MODE_PROP_RANGE == 0 or ranges[0] > ranges[1]) return error.InvalidTopology;
                if (!mutable and values[i] != ranges[1]) return error.Unsupported;
                if (mutable) {
                    result.alpha = id;
                    result.opaque_alpha = ranges[1];
                    restore = true;
                }
            }
            if (restore) {
                if (result.restore_count == result.restore_ids.len) return error.TopologyLimit;
                result.restore_ids[result.restore_count] = id;
                result.restore_values[result.restore_count] = values[i];
                result.restore_count += 1;
            }
        }
        return result;
    }
    fn boundedName(bytes: anytype) ?[]const u8 {
        const raw: []const u8 = std.mem.asBytes(bytes);
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse return null;
        return raw[0..end];
    }
    pub fn checkGeometry(self: *@This(), geometry: Geometry) !void {
        if (geometry.width == 0 or geometry.height == 0 or geometry.width > 16384 or geometry.height > 16384) return error.InvalidGeometry;
        if (self.properties.rotation == 0) {
            if (geometry.rotation != self.properties.fixed_rotation) return error.Unsupported;
        } else if (geometry.rotation & ~self.properties.rotation_bits != 0) return error.Unsupported;
        if (geometry.encoding) |encoding| {
            if (self.properties.encoding == 0 or self.properties.range == 0 or self.properties.encodings[@intFromEnum(encoding)] == null or self.properties.ranges[@intFromBool(geometry.full_range)] == null) return error.Unsupported;
        }
    }
    pub fn freeSlot(self: *@This()) !usize {
        if (self.fd < 0 or self.closed or self.poisoned or self.gate.uncertain or self.cookie >= std.math.maxInt(u64) - 1) return error.State;
        for (self.slots, 0..) |slot, i| if (slot.fb == 0 and slot.count == 0 and self.gate.current != i + 1 and self.gate.candidate != i + 1) return i;
        return error.State;
    }
    pub fn prepare(self: *@This(), index: usize, layout: policy.Layout) !void {
        if (self.fd < 0 or self.closed or self.poisoned) return error.State;
        if (layout.count == 0 or layout.count > 4 or layout.width == 0 or layout.height == 0 or layout.width > 16384 or layout.height > 16384) return error.InvalidLayout;
        for (0..layout.count) |i| if (layout.fds[i] < 0 or layout.pitches[i] == 0) return error.InvalidLayout;
        if (index >= 2 or self.slots[index].fb != 0 or self.slots[index].count != 0 or layout.fourcc != self.fourcc) return error.State;
        const slot = &self.slots[index];
        errdefer self.poisoned = true;
        slot.width = layout.width;
        slot.height = layout.height;
        var handles: [4]u32 = @splat(0);
        for (0..layout.count) |i| {
            var imported = std.mem.zeroes(c.struct_drm_prime_handle);
            imported.fd = layout.fds[i];
            try self.driver.query(self.fd, c.DRM_IOCTL_PRIME_FD_TO_HANDLE, &imported);
            if (imported.handle == 0) return error.InvalidHandle;
            handles[i] = imported.handle;
            if (std.mem.indexOfScalar(u32, slot.handles[0..slot.count], imported.handle) == null) {
                try self.handles.acquire(imported.handle);
                slot.handles[slot.count] = imported.handle;
                slot.count += 1;
            }
        }
        var frame = std.mem.zeroes(c.struct_drm_mode_fb_cmd2);
        frame.width = layout.width;
        frame.height = layout.height;
        frame.pixel_format = layout.fourcc;
        frame.handles = handles;
        frame.pitches = layout.pitches;
        frame.offsets = layout.offsets;
        try self.driver.query(self.fd, c.DRM_IOCTL_MODE_ADDFB2, &frame);
        if (frame.fb_id == 0) return error.InvalidHandle;
        slot.fb = frame.fb_id;
    }
    fn atomic(self: *@This(), slot: ?usize, geometry: Geometry, flags: u32, cookie: u64) !void {
        var ids: [16]u32 = undefined;
        var values: [16]u64 = undefined;
        var count: usize = 0;
        const p = self.properties;
        ids[count] = p.fb;
        values[count] = if (slot) |index| self.slots[index].fb else 0;
        count += 1;
        ids[count] = p.crtc;
        values[count] = if (slot != null) self.crtc else 0;
        count += 1;
        if (slot) |index| {
            const source = self.slots[index];
            const fields = [_]u32{ p.src_x, p.src_y, p.src_w, p.src_h, p.dst_x, p.dst_y, p.dst_w, p.dst_h };
            const data = [_]u64{ 0, 0, @as(u64, source.width) << 16, @as(u64, source.height) << 16, @bitCast(@as(i64, geometry.x)), @bitCast(@as(i64, geometry.y)), geometry.width, geometry.height };
            for (fields, data) |id, value| {
                ids[count] = id;
                values[count] = value;
                count += 1;
            }
            if (p.rotation != 0) {
                ids[count] = p.rotation;
                values[count] = geometry.rotation;
                count += 1;
            }
            if (p.alpha != 0) {
                ids[count] = p.alpha;
                values[count] = p.opaque_alpha;
                count += 1;
            }
            if (geometry.encoding) |encoding| {
                ids[count] = p.encoding;
                values[count] = p.encodings[@intFromEnum(encoding)].?;
                count += 1;
                ids[count] = p.range;
                values[count] = p.ranges[@intFromBool(geometry.full_range)].?;
                count += 1;
            }
        } else {
            count = p.restore_count;
            @memcpy(ids[0..count], p.restore_ids[0..count]);
            @memcpy(values[0..count], p.restore_values[0..count]);
        }
        var object = self.plane;
        var length: u32 = @intCast(count);
        var request = std.mem.zeroes(c.struct_drm_mode_atomic);
        request.flags = flags;
        request.count_objs = 1;
        request.objs_ptr = @intFromPtr(&object);
        request.count_props_ptr = @intFromPtr(&length);
        request.props_ptr = @intFromPtr(&ids);
        request.prop_values_ptr = @intFromPtr(&values);
        request.user_data = cookie;
        try self.driver.query(self.fd, c.DRM_IOCTL_MODE_ATOMIC, &request);
    }
    fn nextCookie(self: *@This()) !u64 {
        if (self.cookie == std.math.maxInt(u64)) return error.State;
        self.cookie += 1;
        return self.cookie;
    }
    fn wait(self: *@This(), cookie: u64) !void {
        var timer = try std.time.Timer.start();
        var events: usize = 0;
        const maximum = @as(u64, self.timeout_ms) * std.time.ns_per_ms;
        while (timer.read() < maximum and events < 64) {
            const elapsed = timer.read();
            if (elapsed >= maximum) break;
            const milliseconds: c_int = @intCast(@max(1, (maximum - elapsed + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
            var descriptor = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&descriptor, 1, milliseconds);
            if (ready < 0) {
                self.driver.last_errno = c.__errno_location().*;
                return error.SystemQuery;
            }
            if (ready == 0) break;
            if (descriptor.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.InvalidEvent;
            var bytes: [4096]u8 = undefined;
            const length = c.read(self.fd, &bytes, bytes.len);
            if (length < 0) {
                const err = c.__errno_location().*;
                if (err == c.EAGAIN) continue;
                self.driver.last_errno = err;
                return error.SystemQuery;
            }
            if (length == 0) return error.InvalidEvent;
            const data = bytes[0..@intCast(length)];
            var offset: usize = 0;
            while (offset < data.len) {
                if (data.len - offset < 8) return error.InvalidEvent;
                const kind = std.mem.readInt(u32, data[offset..][0..4], .little);
                const size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
                if (size < 8 or size > data.len - offset) return error.InvalidEvent;
                events += 1;
                if (events > 64) return error.InvalidEvent;
                if (kind == c.DRM_EVENT_FLIP_COMPLETE) {
                    if (size < 32) return error.InvalidEvent;
                    const token = std.mem.readInt(u64, data[offset + 8 ..][0..8], .little);
                    const crtc = std.mem.readInt(u32, data[offset + 28 ..][0..4], .little);
                    if (token == cookie) {
                        if (crtc != 0 and crtc != self.crtc) return error.InvalidEvent;
                        return;
                    }
                }
                offset += size;
            }
        }
        self.driver.last_errno = c.ETIMEDOUT;
        return error.Timeout;
    }
    pub fn present(self: *@This(), index: usize, geometry: Geometry) !void {
        try self.checkGeometry(geometry);
        if (self.closed or self.poisoned or index >= 2 or self.slots[index].fb == 0) return error.State;
        try self.gate.stage(index + 1);
        var submitted = false;
        errdefer if (!submitted) {
            _ = self.gate.rejected() catch unreachable;
        };
        const cookie = try self.nextCookie();
        try self.atomic(index, geometry, c.DRM_MODE_ATOMIC_TEST_ONLY, 0);
        self.gate.submitted();
        self.needs_detach = true;
        submitted = true;
        errdefer self.poisoned = true;
        try self.atomic(index, geometry, c.DRM_MODE_ATOMIC_NONBLOCK | c.DRM_MODE_PAGE_FLIP_EVENT, cookie);
        try self.wait(cookie);
        _ = try self.gate.confirmed();
    }
    pub fn changeGeometry(self: *@This(), geometry: Geometry) !void {
        try self.checkGeometry(geometry);
        if (self.closed or self.poisoned or self.gate.uncertain or self.cookie >= std.math.maxInt(u64) - 1) return error.State;
        if (self.gate.current == 0) return;
        const cookie = try self.nextCookie();
        const index: usize = @intCast(self.gate.current - 1);
        try self.atomic(index, geometry, c.DRM_MODE_ATOMIC_TEST_ONLY, 0);
        self.gate.submitted();
        errdefer self.poisoned = true;
        try self.atomic(index, geometry, c.DRM_MODE_ATOMIC_NONBLOCK | c.DRM_MODE_PAGE_FLIP_EVENT, cookie);
        try self.wait(cookie);
        self.gate.uncertain = false;
    }
    pub fn detach(self: *@This()) !void {
        if (!self.needs_detach) return;
        const cookie = self.detach_cookie orelse try self.nextCookie();
        self.detach_cookie = cookie;
        errdefer self.poisoned = true;
        const empty = Geometry{ .width = 1, .height = 1 };
        try self.atomic(null, empty, c.DRM_MODE_ATOMIC_TEST_ONLY, 0);
        try self.atomic(null, empty, c.DRM_MODE_ATOMIC_NONBLOCK | c.DRM_MODE_PAGE_FLIP_EVENT, cookie);
        try self.wait(cookie);
        _ = self.gate.detached();
        self.needs_detach = false;
        self.detach_cookie = null;
    }
    pub fn retire(self: *@This(), index: usize) !void {
        if (index >= 2) return error.State;
        if (self.gate.current == index + 1 or self.gate.candidate == index + 1) return error.State;
        const slot = &self.slots[index];
        errdefer self.poisoned = true;
        if (slot.fb != 0) {
            var id = slot.fb;
            try self.driver.query(self.fd, c.DRM_IOCTL_MODE_RMFB, &id);
            slot.fb = 0;
        }
        for (slot.handles[0..slot.count]) |handle| try self.handles.release(handle);
        slot.* = .{};
        try self.closeUnusedHandles();
    }
    fn closeUnusedHandles(self: *@This()) !void {
        for (self.handles.entries) |entry| if (entry.handle != 0 and entry.refs == 0) {
            var request = c.struct_drm_gem_close{ .handle = entry.handle, .pad = 0 };
            try self.driver.query(self.fd, c.DRM_IOCTL_GEM_CLOSE, &request);
            try self.handles.closed(entry.handle);
        };
    }
    /// Call only after confirmed detach and source retirement. Even on cleanup
    /// IO error the private FD is consumed; caller must report that error and
    /// retain a retry/acknowledgement owner rather than exposing a dangling handle.
    pub fn finishClose(self: *@This()) !void {
        if (self.closed) return;
        if (self.needs_detach or self.gate.current != 0 or self.gate.candidate != 0) return error.State;
        var failure: ?anyerror = null;
        for (0..2) |i| self.retire(i) catch |err| {
            failure = failure orelse err;
        };
        self.closeUnusedHandles() catch |err| {
            failure = failure orelse err;
        };
        if (c.close(self.fd) < 0) {
            self.driver.last_errno = c.__errno_location().*;
            failure = failure orelse error.SystemQuery;
        }
        self.fd = -1;
        self.closed = true;
        if (failure) |err| return err;
    }
} else struct {};

test "Linux scanout rejects absent and non-KMS nodes and analyzes all owned operations" {
    if (comptime available) {
        var device: Device = .{};
        try std.testing.expectError(error.SystemQuery, device.open("/dev/zig-camera-kms-absent", .{ .fourcc = 0x34324742 }));
        try std.testing.expectError(error.Unsupported, device.open("/dev/null", .{ .fourcc = 0x34324742 }));
        try std.testing.expectEqual(@as(c_int, -1), device.fd);
        const layout = try policy.Layout.init("BGR888", 1, 1, 3, &.{.{ .fd = 0, .offset = 0, .length = 3, .used = 3 }});
        try std.testing.expectError(error.State, device.prepare(0, layout));
        try std.testing.expectError(error.State, device.present(0, .{ .width = 1, .height = 1 }));
        try device.changeGeometry(.{ .width = 1, .height = 1 });
        try device.detach();
        try device.retire(0);
        device.closed = true;
        try device.finishClose();
    }
}
