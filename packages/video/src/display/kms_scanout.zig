//! Portable direct-scanout layout and retirement rules. No allocation/device IO.
const std = @import("std");
pub const catalog = @import("kms_catalog.zig");
pub const Plane = struct { fd: i32, offset: u64, length: u64, used: u64 };
pub const Layout = struct {
    width: u32,
    height: u32,
    fourcc: u32,
    count: usize,
    fds: [4]i32 = @splat(-1),
    offsets: [4]u32 = @splat(0),
    pitches: [4]u32 = @splat(0),
    pub fn init(name: []const u8, width: u32, height: u32, stride: u32, physical: []const Plane) !Layout {
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or physical.len == 0 or physical.len > 4) return error.InvalidLayout;
        const code = catalog.fourccForProcessed(name) orelse return error.Unsupported;
        const planar = code == catalog.fourcc("YU12") or code == catalog.fourcc("YV12");
        const semi = code == catalog.fourcc("NV12") or code == catalog.fourcc("NV21");
        const bytes: u32 = if (planar or semi) 1 else if (code == catalog.fourcc("RG24") or code == catalog.fourcc("BG24")) 3 else if (code == catalog.fourcc("XR24") or code == catalog.fourcc("XB24")) 4 else 2;
        if ((planar or semi) and ((width | height | stride) & 1 != 0)) return error.InvalidLayout;
        if (bytes == 2 and width & 1 != 0) return error.InvalidLayout;
        const row = std.math.mul(u32, width, if (planar or semi) 1 else bytes) catch return error.InvalidLayout;
        if (stride < row) return error.InvalidLayout;
        const count: usize = if (planar) 3 else if (semi) 2 else 1;
        if (physical.len != 1 and physical.len != count) return error.InvalidLayout;
        var result = Layout{ .width = width, .height = height, .fourcc = code, .count = count };
        var next: u64 = 0;
        for (0..count) |i| {
            const source = physical[if (physical.len == 1) 0 else i];
            const pitch = if (planar and i != 0) stride / 2 else stride;
            const active = if (planar and i != 0) width / 2 else if (semi and i != 0) width else row;
            const rows = if ((planar or semi) and i != 0) height / 2 else height;
            const offset = if (physical.len == 1) next else 0;
            const span = @as(u64, rows - 1) * pitch + active;
            if (source.fd < 0 or source.used > source.length or source.length > 256 * 1024 * 1024 or offset > source.used or span > source.used - offset) return error.InvalidLayout;
            const absolute = std.math.add(u64, source.offset, offset) catch return error.InvalidLayout;
            if (absolute > std.math.maxInt(u32)) return error.InvalidLayout;
            result.fds[i] = source.fd;
            result.offsets[i] = @intCast(absolute);
            result.pitches[i] = pitch;
            next = std.math.add(u64, offset, @as(u64, rows) * pitch) catch return error.InvalidLayout;
        }
        return result;
    }
};
/// Tokens identify externally owned frame leases. A failed/unconfirmed submit
/// retains BOTH possible scanout owners until a confirmed detach event.
pub const Gate = struct {
    current: u64 = 0,
    candidate: u64 = 0,
    uncertain: bool = false,
    pub fn stage(self: *Gate, token: u64) !void {
        if (token == 0 or token == self.current or self.candidate != 0 or self.uncertain) return error.State;
        self.candidate = token;
    }
    pub fn rejected(self: *Gate) !u64 {
        if (self.candidate == 0 or self.uncertain) return error.State;
        const token = self.candidate;
        self.candidate = 0;
        return token;
    }
    pub fn submitted(self: *Gate) void {
        self.uncertain = true;
    }
    pub fn confirmed(self: *Gate) !u64 {
        if (self.candidate == 0 or !self.uncertain) return error.State;
        const previous = self.current;
        self.current = self.candidate;
        self.candidate = 0;
        self.uncertain = false;
        return previous;
    }
    pub fn detached(self: *Gate) [2]u64 {
        const result = [2]u64{ self.current, self.candidate };
        self.* = .{};
        return result;
    }
};
/// PRIME import deduplicates GEM handles in the kernel without adding a new
/// userspace handle reference. Keep an explicit reference table until GEM_CLOSE
/// succeeds; a failed close must not permit numeric handle reuse confusion.
pub const Handles = struct {
    pub const Entry = struct { handle: u32 = 0, refs: u32 = 0 };
    entries: [16]Entry = @splat(.{}),
    pub fn acquire(self: *Handles, handle: u32) !void {
        if (handle == 0) return error.InvalidHandle;
        for (&self.entries) |*entry| if (entry.handle == handle) {
            entry.refs = try std.math.add(u32, entry.refs, 1);
            return;
        };
        for (&self.entries) |*entry| if (entry.handle == 0) {
            entry.* = .{ .handle = handle, .refs = 1 };
            return;
        };
        return error.HandleLimit;
    }
    pub fn release(self: *Handles, handle: u32) !void {
        for (&self.entries) |*entry| if (entry.handle == handle) {
            if (entry.refs == 0) return error.State;
            entry.refs -= 1;
            return;
        };
        return error.InvalidHandle;
    }
    pub fn closed(self: *Handles, handle: u32) !void {
        for (&self.entries) |*entry| if (entry.handle == handle) {
            if (entry.refs != 0) return error.State;
            entry.* = .{};
            return;
        };
        return error.InvalidHandle;
    }
};
/// DRM rotations are counter-clockwise with source-axis reflection first.
/// Home's numeric orientations deliberately follow its own camera/image contract.
pub fn rotation(orientation: u32) !u64 {
    if (orientation < 1 or orientation > 8) return error.InvalidTransform;
    return ([_]u64{ 1, 17, 4, 33, 18, 2, 34, 8 })[orientation - 1];
}
test "scanout leases retain both candidates on missing completion and reject new feed" {
    const t = std.testing;
    var gate: Gate = .{};
    try gate.stage(11);
    gate.submitted();
    try t.expectEqual(@as(u64, 0), try gate.confirmed());
    try gate.stage(22);
    try t.expectEqual(@as(u64, 22), try gate.rejected());
    try t.expectEqual(@as(u64, 11), gate.current);
    try gate.stage(33);
    gate.submitted();
    try t.expectError(error.State, gate.stage(44));
    try t.expectError(error.State, gate.rejected());
    try t.expectEqual([2]u64{ 11, 33 }, gate.detached());
    try gate.stage(44);
    gate.submitted();
    try t.expectEqual(@as(u64, 0), try gate.confirmed());
}
test "shared GEM handles close only after the last reference and retain failed close identity" {
    const t = std.testing;
    var handles: Handles = .{};
    try handles.acquire(7);
    try handles.acquire(7);
    try handles.release(7);
    try t.expectError(error.State, handles.closed(7));
    try handles.release(7);
    try t.expectEqual(@as(u32, 7), handles.entries[0].handle);
    try handles.acquire(7);
    try handles.release(7);
    try handles.closed(7);
    try t.expectEqual(@as(u32, 0), handles.entries[0].handle);
    try t.expectError(error.InvalidHandle, handles.acquire(0));
}
test "linear scanout layouts preserve independent physical offsets and reject truncated late chroma" {
    const t = std.testing;
    const packed_layout = try Layout.init("BGR888", 3, 2, 12, &.{.{ .fd = 0, .offset = 7, .length = 21, .used = 21 }});
    try t.expectEqual(catalog.fourcc("BG24"), packed_layout.fourcc);
    try t.expectEqual(@as(u32, 7), packed_layout.offsets[0]);
    const planar = try Layout.init("YUV420", 4, 2, 6, &.{.{ .fd = 3, .offset = 9, .length = 18, .used = 18 }});
    try t.expectEqualSlices(u32, &.{ 9, 21, 24 }, planar.offsets[0..3]);
    try t.expectEqualSlices(u32, &.{ 6, 3, 3 }, planar.pitches[0..3]);
    const split = try Layout.init("NV12", 4, 2, 6, &.{ .{ .fd = 4, .offset = 12, .length = 10, .used = 10 }, .{ .fd = 5, .offset = 31, .length = 4, .used = 4 } });
    try t.expectEqualSlices(u32, &.{ 12, 31 }, split.offsets[0..2]);
    try t.expectEqualSlices(i32, &.{ 4, 5 }, split.fds[0..2]);
    try t.expectError(error.InvalidLayout, Layout.init("YUV420", 4, 2, 6, &.{.{ .fd = 3, .offset = 0, .length = 15, .used = 15 }}));
    try t.expectError(error.InvalidLayout, Layout.init("NV12", 3, 2, 6, &.{.{ .fd = 3, .offset = 0, .length = 18, .used = 18 }}));
    try t.expectError(error.Unsupported, Layout.init("BGR161616", 2, 2, 12, &.{.{ .fd = 3, .offset = 0, .length = 24, .used = 24 }}));
}

/// One checked, device-owned 32-bit CPU scanout allocation. At most two slots.
pub const CpuLayout = struct {
    width: u32,
    height: u32,
    pitch: u32,
    size: usize,
    pub fn init(width: u32, height: u32, pitch: u32, size: u64) !CpuLayout {
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or size == 0 or size > 256 * 1024 * 1024) return error.InvalidLayout;
        const row = std.math.mul(u32, width, 4) catch return error.InvalidLayout;
        if (pitch < row or @as(u64, pitch) * height > size) return error.InvalidLayout;
        return .{ .width = width, .height = height, .pitch = pitch, .size = @intCast(size) };
    }
};
test "CPU scanout validates full padded allocation extent before device mapping" {
    const t = std.testing;
    const v = try CpuLayout.init(3, 2, 16, 4096);
    try t.expectEqual(@as(usize, 4096), v.size);
    for ([_][4]u64{ .{ 0, 2, 16, 4096 }, .{ 3, 0, 16, 4096 }, .{ 3, 2, 11, 4096 }, .{ 3, 2, 16, 31 }, .{ 3, 2, 16, 0 }, .{ 3, 2, 16, 256 * 1024 * 1024 + 1 } }) |bad| try t.expectError(error.InvalidLayout, CpuLayout.init(@intCast(bad[0]), @intCast(bad[1]), @intCast(bad[2]), bad[3]));
}

/// Do not infer relative stacking from object IDs or normalized inactive planes.
/// Missing/unsatisfiable zpos is unsupported rather than an invisible overlay.
pub fn overlayZ(bottom: ?u64, current: ?u64, range: ?struct { min: u64, max: u64 }) !u64 {
    const base = bottom orelse return error.Unsupported;
    const top = current orelse return error.Unsupported;
    if (range) |r| {
        if (r.min > r.max) return error.InvalidLayout;
        const next = std.math.add(u64, base, 1) catch return error.Unsupported;
        const wanted = @max(r.min, next);
        if (wanted > r.max) return error.Unsupported;
        return if (top >= wanted and top <= r.max) top else wanted;
    }
    if (top <= base) return error.Unsupported;
    return top;
}
test "overlay stacking proves strict order for mutable and immutable zpos" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 4), try overlayZ(3, 1, .{ .min = 0, .max = 7 }));
    try t.expectEqual(@as(u64, 6), try overlayZ(3, 6, .{ .min = 0, .max = 7 }));
    try t.expectEqual(@as(u64, 4), try overlayZ(3, 4, null));
    try t.expectError(error.Unsupported, overlayZ(null, 4, null));
    try t.expectError(error.Unsupported, overlayZ(3, null, null));
    try t.expectError(error.Unsupported, overlayZ(3, 3, null));
    try t.expectError(error.Unsupported, overlayZ(3, 2, .{ .min = 0, .max = 3 }));
    try t.expectError(error.Unsupported, overlayZ(std.math.maxInt(u64), 1, .{ .min = 0, .max = std.math.maxInt(u64) }));
}
