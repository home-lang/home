// Forward-port shim: Home's pinned Zig (0.17-dev.263 Bun fork) removed the old
// `std.net` namespace; IP addressing now lives under `std.Io.net` with a
// different shape (`IpAddress` union, no `Address.initIp4`/`initIp6`). Bun's
// pinned source still uses `std.net.Address.initIp4/initIp6` + `Ip4Address.parse`
// / `Ip6Address.parse` and formats via `{f}` (which `bun.fmt.formatIp` then
// strips to a bare Node-style address). This restores that surface on top of the
// new `std.Io.net` types so the copied socket cone compiles unchanged.

const std = @import("std");
const ionet = std.Io.net;

pub const Ip4Address = ionet.Ip4Address;
pub const Ip6Address = ionet.Ip6Address;
pub const IpAddress = ionet.IpAddress;
pub const Stream = ionet.Stream;

/// Forward-port of the parts of the removed `std.net.Address` Bun's socket cone
/// uses. Backed by `std.Io.net.IpAddress`; its `{f}` formatter emits the old
/// `ip:port` / `[ip6]:port` convention (see `Ip4Address.format`/`Ip6Address.format`).
pub const Address = struct {
    inner: IpAddress,

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return .{ .inner = .{ .ip4 = .{ .bytes = bytes, .port = port } } };
    }

    /// Old `std.net.Address.initIp6(addr, port, flowinfo, scope_id)`. The new
    /// `Ip6Address` carries the zone as `interface` rather than a raw scope id;
    /// Bun's callers pass `scope_id = 0`, so it is dropped here.
    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        _ = scope_id;
        return .{ .inner = .{ .ip6 = .{ .bytes = bytes, .port = port, .flow = flowinfo } } };
    }

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.inner.format(w);
    }
};

test "Address.initIp4 formats ip:port (formatIp-strippable)" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{Address.initIp4(.{ 127, 0, 0, 1 }, 8080)});
    try std.testing.expectEqualStrings("127.0.0.1:8080", w.buffered());
}

test "Address.initIp6 formats [ip6]:port" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try w.print("{f}", .{Address.initIp6(bytes, 443, 0, 0)});
    try std.testing.expectEqualStrings("[::1]:443", w.buffered());
}
