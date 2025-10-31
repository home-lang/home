// IPv6 Networking Implementation
// RFC 8200 - Internet Protocol, Version 6 (IPv6) Specification

const std = @import("std");

/// IPv6 address (128 bits)
pub const Address = struct {
    octets: [16]u8,

    /// Special addresses
    pub const unspecified = Address{ .octets = [_]u8{0} ** 16 };
    pub const loopback = Address{ .octets = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
    pub const all_nodes = Address{ .octets = [_]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
    pub const all_routers = Address{ .octets = [_]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 } };

    /// Create address from octets
    pub fn init(octets: [16]u8) Address {
        return .{ .octets = octets };
    }

    /// Create from 8 16-bit segments
    pub fn fromSegments(segments: [8]u16) Address {
        var addr: Address = undefined;
        for (segments, 0..) |seg, i| {
            addr.octets[i * 2] = @intCast(seg >> 8);
            addr.octets[i * 2 + 1] = @intCast(seg & 0xFF);
        }
        return addr;
    }

    /// Get 16-bit segments
    pub fn toSegments(self: Address) [8]u16 {
        var segments: [8]u16 = undefined;
        for (&segments, 0..) |*seg, i| {
            seg.* = (@as(u16, self.octets[i * 2]) << 8) | @as(u16, self.octets[i * 2 + 1]);
        }
        return segments;
    }

    /// Parse from string (RFC 5952 format)
    pub fn parse(str: []const u8) !Address {
        var addr: Address = undefined;
        @memset(&addr.octets, 0);

        // Handle :: compression
        const double_colon_pos = std.mem.indexOf(u8, str, "::");

        if (double_colon_pos) |pos| {
            // Parse before ::
            var before_parts = std.mem.splitScalar(u8, str[0..pos], ':');
            var idx: usize = 0;

            while (before_parts.next()) |part| {
                if (part.len == 0) continue;
                const value = try std.fmt.parseInt(u16, part, 16);
                addr.octets[idx] = @intCast(value >> 8);
                addr.octets[idx + 1] = @intCast(value & 0xFF);
                idx += 2;
            }

            // Parse after ::
            if (pos + 2 < str.len) {
                var after_parts = std.mem.splitScalar(u8, str[pos + 2 ..], ':');
                var after_values = std.ArrayList(u16){};
                defer after_values.deinit(std.heap.page_allocator);

                while (after_parts.next()) |part| {
                    if (part.len == 0) continue;
                    const value = try std.fmt.parseInt(u16, part, 16);
                    try after_values.append(std.heap.page_allocator, value);
                }

                // Fill from the end
                var end_idx: usize = 16;
                var i: usize = after_values.items.len;
                while (i > 0) {
                    i -= 1;
                    const value = after_values.items[i];
                    end_idx -= 2;
                    addr.octets[end_idx] = @intCast(value >> 8);
                    addr.octets[end_idx + 1] = @intCast(value & 0xFF);
                }
            }
        } else {
            // No compression, parse all 8 segments
            var parts = std.mem.splitScalar(u8, str, ':');
            var idx: usize = 0;

            while (parts.next()) |part| {
                if (idx >= 16) return error.InvalidAddress;
                const value = try std.fmt.parseInt(u16, part, 16);
                addr.octets[idx] = @intCast(value >> 8);
                addr.octets[idx + 1] = @intCast(value & 0xFF);
                idx += 2;
            }

            if (idx != 16) return error.InvalidAddress;
        }

        return addr;
    }

    /// Format address to string (RFC 5952)
    pub fn format(
        self: Address,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        const segments = self.toSegments();

        // Find longest run of zeros for :: compression
        var best_start: ?usize = null;
        var best_len: usize = 0;
        var current_start: ?usize = null;
        var current_len: usize = 0;

        for (segments, 0..) |seg, i| {
            if (seg == 0) {
                if (current_start == null) {
                    current_start = i;
                    current_len = 1;
                } else {
                    current_len += 1;
                }
            } else {
                if (current_len > best_len and current_len > 1) {
                    best_start = current_start;
                    best_len = current_len;
                }
                current_start = null;
                current_len = 0;
            }
        }

        // Check final run
        if (current_len > best_len and current_len > 1) {
            best_start = current_start;
            best_len = current_len;
        }

        // Write formatted address
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            if (best_start) |start| {
                if (i == start) {
                    try writer.writeAll("::");
                    i += best_len - 1;
                    continue;
                } else if (i > start and i < start + best_len) {
                    continue;
                }
            }

            if (i > 0 and (best_start == null or i != best_start.? + best_len)) {
                try writer.writeByte(':');
            }

            try writer.print("{x}", .{segments[i]});
        }
    }

    /// Check if address is unspecified (::)
    pub fn isUnspecified(self: Address) bool {
        return std.mem.eql(u8, &self.octets, &unspecified.octets);
    }

    /// Check if address is loopback (::1)
    pub fn isLoopback(self: Address) bool {
        return std.mem.eql(u8, &self.octets, &loopback.octets);
    }

    /// Check if address is multicast (ff00::/8)
    pub fn isMulticast(self: Address) bool {
        return self.octets[0] == 0xff;
    }

    /// Check if address is link-local (fe80::/10)
    pub fn isLinkLocal(self: Address) bool {
        return self.octets[0] == 0xfe and (self.octets[1] & 0xc0) == 0x80;
    }

    /// Check if address is unique local (fc00::/7)
    pub fn isUniqueLocal(self: Address) bool {
        return (self.octets[0] & 0xfe) == 0xfc;
    }

    /// Check if address is global unicast
    pub fn isGlobalUnicast(self: Address) bool {
        return !self.isUnspecified() and
            !self.isLoopback() and
            !self.isMulticast() and
            !self.isLinkLocal() and
            !self.isUniqueLocal();
    }

    /// Get multicast scope
    pub fn getMulticastScope(self: Address) ?MulticastScope {
        if (!self.isMulticast()) return null;
        const scope_value = self.octets[1] & 0x0F;
        return std.meta.intToEnum(MulticastScope, scope_value) catch null;
    }

    /// Create solicited-node multicast address
    pub fn solicitedNode(self: Address) Address {
        var addr = Address{ .octets = [_]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, 0, 0, 0 } };
        addr.octets[13] = self.octets[13];
        addr.octets[14] = self.octets[14];
        addr.octets[15] = self.octets[15];
        return addr;
    }

    /// Compare addresses
    pub fn eql(self: Address, other: Address) bool {
        return std.mem.eql(u8, &self.octets, &other.octets);
    }
};

/// Multicast scope
pub const MulticastScope = enum(u4) {
    interface_local = 1,
    link_local = 2,
    admin_local = 4,
    site_local = 5,
    organization_local = 8,
    global = 14,
};

/// IPv6 prefix
pub const Prefix = struct {
    address: Address,
    length: u8, // 0-128

    pub fn init(address: Address, length: u8) !Prefix {
        if (length > 128) return error.InvalidPrefixLength;
        return .{
            .address = address,
            .length = length,
        };
    }

    /// Check if address is in prefix
    pub fn contains(self: Prefix, addr: Address) bool {
        const full_bytes = self.length / 8;
        const remaining_bits = self.length % 8;

        // Check full bytes
        if (!std.mem.eql(u8, self.address.octets[0..full_bytes], addr.octets[0..full_bytes])) {
            return false;
        }

        // Check remaining bits
        if (remaining_bits > 0) {
            const shift_amount: u3 = @intCast(8 - remaining_bits);
            const mask: u8 = @as(u8, 0xFF) << shift_amount;
            if ((self.address.octets[full_bytes] & mask) != (addr.octets[full_bytes] & mask)) {
                return false;
            }
        }

        return true;
    }

    /// Get network address (zero host bits)
    pub fn getNetwork(self: Prefix) Address {
        var addr = self.address;
        const full_bytes = self.length / 8;
        const remaining_bits = self.length % 8;

        // Zero out host bits
        if (remaining_bits > 0) {
            const shift_amount: u3 = @intCast(8 - remaining_bits);
            const mask: u8 = @as(u8, 0xFF) << shift_amount;
            addr.octets[full_bytes] &= mask;
        }

        // Zero remaining bytes
        if (full_bytes + 1 < 16) {
            @memset(addr.octets[full_bytes + 1 ..], 0);
        }

        return addr;
    }

    /// Format prefix
    pub fn format(
        self: Prefix,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}/{d}", .{ self.address, self.length });
    }
};

/// IPv6 header (RFC 8200)
pub const Header = struct {
    version_class_label: u32, // version(4), traffic class(8), flow label(20)
    payload_length: u16,
    next_header: u8,
    hop_limit: u8,
    source: Address,
    destination: Address,

    pub fn init(source: Address, destination: Address, next_header: u8, payload_length: u16) Header {
        return .{
            .version_class_label = 0x60000000, // Version 6
            .payload_length = payload_length,
            .next_header = next_header,
            .hop_limit = 64,
            .source = source,
            .destination = destination,
        };
    }

    pub fn getVersion(self: Header) u4 {
        return @intCast((self.version_class_label >> 28) & 0x0F);
    }

    pub fn getTrafficClass(self: Header) u8 {
        return @intCast((self.version_class_label >> 20) & 0xFF);
    }

    pub fn getFlowLabel(self: Header) u20 {
        return @intCast(self.version_class_label & 0xFFFFF);
    }

    pub fn setTrafficClass(self: *Header, tc: u8) void {
        self.version_class_label = (self.version_class_label & 0xF00FFFFF) | (@as(u32, tc) << 20);
    }

    pub fn setFlowLabel(self: *Header, label: u20) void {
        self.version_class_label = (self.version_class_label & 0xFFF00000) | @as(u32, label);
    }
};

/// Next header / protocol numbers
pub const Protocol = enum(u8) {
    hopbyhop = 0,
    icmpv6 = 58,
    tcp = 6,
    udp = 17,
    no_next_header = 59,
    routing = 43,
    fragment = 44,
    destination_options = 60,
    _,
};

test "IPv6 address parsing" {
    const testing = std.testing;

    // Full address
    const addr1 = try Address.parse("2001:0db8:85a3:0000:0000:8a2e:0370:7334");
    try testing.expect(addr1.octets[0] == 0x20);
    try testing.expect(addr1.octets[1] == 0x01);

    // Compressed
    const addr2 = try Address.parse("2001:db8::1");
    try testing.expect(addr2.octets[0] == 0x20);
    try testing.expect(addr2.octets[1] == 0x01);
    try testing.expect(addr2.octets[15] == 0x01);

    // Loopback
    const addr3 = try Address.parse("::1");
    try testing.expect(addr3.isLoopback());

    // Unspecified
    const addr4 = try Address.parse("::");
    try testing.expect(addr4.isUnspecified());
}

test "IPv6 address properties" {
    const testing = std.testing;

    try testing.expect(Address.loopback.isLoopback());
    try testing.expect(Address.unspecified.isUnspecified());

    const multicast = try Address.parse("ff02::1");
    try testing.expect(multicast.isMulticast());
    try testing.expectEqual(MulticastScope.link_local, multicast.getMulticastScope().?);

    const link_local = try Address.parse("fe80::1");
    try testing.expect(link_local.isLinkLocal());

    const unique_local = try Address.parse("fc00::1");
    try testing.expect(unique_local.isUniqueLocal());

    const global = try Address.parse("2001:db8::1");
    try testing.expect(global.isGlobalUnicast());
}

test "IPv6 prefix" {
    const testing = std.testing;

    const addr = try Address.parse("2001:db8::");
    const prefix = try Prefix.init(addr, 32);

    const addr1 = try Address.parse("2001:db8::1");
    const addr2 = try Address.parse("2001:db9::1");

    try testing.expect(prefix.contains(addr1));
    try testing.expect(!prefix.contains(addr2));
}

test "solicited-node multicast" {
    const testing = std.testing;

    const addr = try Address.parse("2001:db8::1234:5678");
    const solicited = addr.solicitedNode();

    try testing.expect(solicited.isMulticast());
    try testing.expectEqual(@as(u8, 0xff), solicited.octets[0]);
    try testing.expectEqual(@as(u8, 0x02), solicited.octets[1]);
    try testing.expectEqual(@as(u8, 0x34), solicited.octets[13]);
    try testing.expectEqual(@as(u8, 0x56), solicited.octets[14]);
    try testing.expectEqual(@as(u8, 0x78), solicited.octets[15]);
}

test "IPv6 header" {
    const testing = std.testing;

    const src = try Address.parse("2001:db8::1");
    const dst = try Address.parse("2001:db8::2");

    var header = Header.init(src, dst, @intFromEnum(Protocol.tcp), 1024);

    try testing.expectEqual(@as(u4, 6), header.getVersion());
    try testing.expectEqual(@as(u16, 1024), header.payload_length);
    try testing.expectEqual(@as(u8, 6), header.next_header);

    header.setTrafficClass(0xA5);
    try testing.expectEqual(@as(u8, 0xA5), header.getTrafficClass());
}
