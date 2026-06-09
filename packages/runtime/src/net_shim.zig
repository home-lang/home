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
    any: extern struct {
        family: std.posix.sa_family_t,
    },
    in: extern struct {
        family: std.posix.sa_family_t,
        port: u16,
        addr: u32,
        sa: extern struct {
            addr: u32,
        },
    },
    in6: extern struct {
        family: std.posix.sa_family_t,
        port: u16,
        flowinfo: u32,
        addr: [16]u8,
        scope_id: u32,
        // Mirror of the `in` field's nested `sa` (sockaddr_in6) so callers
        // (e.g. node:os networkInterfaces) can read `in6.sa.addr`/`.scope_id`.
        sa: extern struct {
            addr: [16]u8,
            scope_id: u32,
        },

        pub fn getPort(this: @This()) u16 {
            return std.mem.bigToNative(u16, this.port);
        }
    },

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return .{
            .inner = .{ .ip4 = .{ .bytes = bytes, .port = port } },
            .any = .{ .family = std.posix.AF.INET },
            .in = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.readInt(u32, &bytes, .big),
                .sa = .{ .addr = std.mem.readInt(u32, &bytes, .big) },
            },
            .in6 = std.mem.zeroes(@FieldType(Address, "in6")),
        };
    }

    /// Old `std.net.Address.initIp6(addr, port, flowinfo, scope_id)`. The new
    /// `Ip6Address` carries the zone as `interface` rather than a raw scope id;
    /// Bun's callers pass `scope_id = 0`, so it is dropped here.
    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        return .{
            .inner = .{ .ip6 = .{ .bytes = bytes, .port = port, .flow = flowinfo } },
            .any = .{ .family = std.posix.AF.INET6 },
            .in = std.mem.zeroes(@FieldType(Address, "in")),
            .in6 = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, port),
                .flowinfo = flowinfo,
                .addr = bytes,
                .scope_id = scope_id,
                .sa = .{ .addr = bytes, .scope_id = scope_id },
            },
        };
    }

    pub fn initPosix(addr: *const std.posix.sockaddr) Address {
        return switch (addr.family) {
            std.posix.AF.INET => brk: {
                const in_addr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(addr));
                const bytes = std.mem.toBytes(std.mem.bigToNative(u32, in_addr.addr));
                break :brk initIp4(bytes, std.mem.bigToNative(u16, in_addr.port));
            },
            std.posix.AF.INET6 => brk: {
                const in6_addr: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(addr));
                break :brk initIp6(in6_addr.addr, std.mem.bigToNative(u16, in6_addr.port), in6_addr.flowinfo, in6_addr.scope_id);
            },
            else => .{
                .inner = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
                .any = .{ .family = addr.family },
                .in = std.mem.zeroes(@FieldType(Address, "in")),
                .in6 = std.mem.zeroes(@FieldType(Address, "in6")),
            },
        };
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
