// ICMPv6 Implementation
// RFC 4443 - Internet Control Message Protocol (ICMPv6) for IPv6

const std = @import("std");
const ipv6 = @import("ipv6.zig");

/// ICMPv6 message types
pub const MessageType = enum(u8) {
    // Error messages (0-127)
    destination_unreachable = 1,
    packet_too_big = 2,
    time_exceeded = 3,
    parameter_problem = 4,

    // Informational messages (128-255)
    echo_request = 128,
    echo_reply = 129,
    router_solicitation = 133,
    router_advertisement = 134,
    neighbor_solicitation = 135,
    neighbor_advertisement = 136,
    redirect = 137,

    _,
};

/// ICMPv6 header
pub const Header = packed struct {
    type: u8,
    code: u8,
    checksum: u16,

    pub fn init(msg_type: MessageType, code: u8) Header {
        return .{
            .type = @intFromEnum(msg_type),
            .code = code,
            .checksum = 0,
        };
    }

    pub fn getType(self: Header) MessageType {
        return @enumFromInt(self.type);
    }
};

/// Echo Request/Reply message
pub const EchoMessage = struct {
    header: Header,
    identifier: u16,
    sequence: u16,
    data: []const u8,

    pub fn init(is_reply: bool, identifier: u16, sequence: u16, data: []const u8) EchoMessage {
        const msg_type = if (is_reply) MessageType.echo_reply else MessageType.echo_request;
        return .{
            .header = Header.init(msg_type, 0),
            .identifier = identifier,
            .sequence = sequence,
            .data = data,
        };
    }

    pub fn serialize(self: *EchoMessage, allocator: std.mem.Allocator) ![]u8 {
        const total_len = @sizeOf(Header) + 4 + self.data.len;
        var buffer = try allocator.alloc(u8, total_len);

        // Write header (will update checksum later)
        buffer[0] = self.header.type;
        buffer[1] = self.header.code;
        buffer[2] = 0; // Checksum high byte
        buffer[3] = 0; // Checksum low byte

        // Write identifier and sequence
        buffer[4] = @intCast(self.identifier >> 8);
        buffer[5] = @intCast(self.identifier & 0xFF);
        buffer[6] = @intCast(self.sequence >> 8);
        buffer[7] = @intCast(self.sequence & 0xFF);

        // Write data
        if (self.data.len > 0) {
            @memcpy(buffer[8..], self.data);
        }

        return buffer;
    }
};

/// Destination Unreachable codes
pub const UnreachableCode = enum(u8) {
    no_route = 0,
    admin_prohibited = 1,
    beyond_scope = 2,
    address_unreachable = 3,
    port_unreachable = 4,
    source_address_failed = 5,
    reject_route = 6,
};

/// Time Exceeded codes
pub const TimeExceededCode = enum(u8) {
    hop_limit = 0,
    fragment_reassembly = 1,
};

/// Parameter Problem codes
pub const ParameterProblemCode = enum(u8) {
    erroneous_header = 0,
    unrecognized_next_header = 1,
    unrecognized_option = 2,
};

/// Destination Unreachable message
pub const DestinationUnreachable = struct {
    header: Header,
    unused: u32,
    invoking_packet: []const u8,

    pub fn init(code: UnreachableCode, invoking_packet: []const u8) DestinationUnreachable {
        return .{
            .header = Header.init(.destination_unreachable, @intFromEnum(code)),
            .unused = 0,
            .invoking_packet = invoking_packet,
        };
    }
};

/// Packet Too Big message
pub const PacketTooBig = struct {
    header: Header,
    mtu: u32,
    invoking_packet: []const u8,

    pub fn init(mtu: u32, invoking_packet: []const u8) PacketTooBig {
        return .{
            .header = Header.init(.packet_too_big, 0),
            .mtu = mtu,
            .invoking_packet = invoking_packet,
        };
    }
};

/// Time Exceeded message
pub const TimeExceeded = struct {
    header: Header,
    unused: u32,
    invoking_packet: []const u8,

    pub fn init(code: TimeExceededCode, invoking_packet: []const u8) TimeExceeded {
        return .{
            .header = Header.init(.time_exceeded, @intFromEnum(code)),
            .unused = 0,
            .invoking_packet = invoking_packet,
        };
    }
};

/// Parameter Problem message
pub const ParameterProblem = struct {
    header: Header,
    pointer: u32,
    invoking_packet: []const u8,

    pub fn init(code: ParameterProblemCode, pointer: u32, invoking_packet: []const u8) ParameterProblem {
        return .{
            .header = Header.init(.parameter_problem, @intFromEnum(code)),
            .pointer = pointer,
            .invoking_packet = invoking_packet,
        };
    }
};

/// Compute ICMPv6 checksum
pub fn computeChecksum(
    source: ipv6.Address,
    destination: ipv6.Address,
    payload: []const u8,
) u16 {
    var sum: u32 = 0;

    // Add source address
    for (0..8) |i| {
        const word = (@as(u16, source.octets[i * 2]) << 8) | @as(u16, source.octets[i * 2 + 1]);
        sum +%= word;
    }

    // Add destination address
    for (0..8) |i| {
        const word = (@as(u16, destination.octets[i * 2]) << 8) | @as(u16, destination.octets[i * 2 + 1]);
        sum +%= word;
    }

    // Add ICMPv6 length (upper layer packet length)
    const length: u32 = @intCast(payload.len);
    sum +%= @intCast(length >> 16);
    sum +%= @intCast(length & 0xFFFF);

    // Add next header (ICMPv6 = 58)
    sum +%= 58;

    // Add payload in 16-bit words
    var i: usize = 0;
    while (i + 1 < payload.len) : (i += 2) {
        const word = (@as(u16, payload[i]) << 8) | @as(u16, payload[i + 1]);
        sum +%= word;
    }

    // Add final odd byte if present
    if (i < payload.len) {
        sum +%= @as(u16, payload[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) +% (sum >> 16);
    }

    return ~@as(u16, @intCast(sum));
}

/// Verify ICMPv6 checksum
pub fn verifyChecksum(
    source: ipv6.Address,
    destination: ipv6.Address,
    payload: []const u8,
) bool {
    if (payload.len < 4) return false;

    // Save original checksum
    const original_checksum = (@as(u16, payload[2]) << 8) | @as(u16, payload[3]);

    // Create copy with zero checksum
    var buffer = std.heap.page_allocator.alloc(u8, payload.len) catch return false;
    defer std.heap.page_allocator.free(buffer);

    @memcpy(buffer, payload);
    buffer[2] = 0;
    buffer[3] = 0;

    // Compute checksum
    const computed = computeChecksum(source, destination, buffer);

    return computed == original_checksum;
}

/// ICMPv6 statistics
pub const Statistics = struct {
    echo_requests_sent: std.atomic.Value(u64),
    echo_replies_received: std.atomic.Value(u64),
    destination_unreachable_received: std.atomic.Value(u64),
    packet_too_big_received: std.atomic.Value(u64),
    time_exceeded_received: std.atomic.Value(u64),
    parameter_problem_received: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),

    pub fn init() Statistics {
        return .{
            .echo_requests_sent = std.atomic.Value(u64).init(0),
            .echo_replies_received = std.atomic.Value(u64).init(0),
            .destination_unreachable_received = std.atomic.Value(u64).init(0),
            .packet_too_big_received = std.atomic.Value(u64).init(0),
            .time_exceeded_received = std.atomic.Value(u64).init(0),
            .parameter_problem_received = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
        };
    }

    pub fn incrementEchoRequestsSent(self: *Statistics) void {
        _ = self.echo_requests_sent.fetchAdd(1, .monotonic);
    }

    pub fn incrementEchoRepliesReceived(self: *Statistics) void {
        _ = self.echo_replies_received.fetchAdd(1, .monotonic);
    }

    pub fn incrementErrors(self: *Statistics) void {
        _ = self.errors.fetchAdd(1, .monotonic);
    }
};

test "ICMPv6 echo message" {
    const testing = std.testing;

    const data = "Hello, IPv6!";
    var echo = EchoMessage.init(false, 0x1234, 1, data);

    try testing.expectEqual(MessageType.echo_request, echo.header.getType());
    try testing.expectEqual(@as(u16, 0x1234), echo.identifier);
    try testing.expectEqual(@as(u16, 1), echo.sequence);

    const serialized = try echo.serialize(testing.allocator);
    defer testing.allocator.free(serialized);

    try testing.expectEqual(@as(u8, 128), serialized[0]); // Type
    try testing.expectEqual(@as(u8, 0), serialized[1]); // Code
}

test "ICMPv6 destination unreachable" {
    const testing = std.testing;

    const packet = [_]u8{0x60} ** 48; // Dummy IPv6 packet
    const msg = DestinationUnreachable.init(.no_route, &packet);

    try testing.expectEqual(MessageType.destination_unreachable, msg.header.getType());
    try testing.expectEqual(@as(u8, 0), msg.header.code);
}

test "ICMPv6 packet too big" {
    const testing = std.testing;

    const packet = [_]u8{0x60} ** 48;
    const msg = PacketTooBig.init(1280, &packet);

    try testing.expectEqual(MessageType.packet_too_big, msg.header.getType());
    try testing.expectEqual(@as(u32, 1280), msg.mtu);
}

test "ICMPv6 checksum" {
    const testing = std.testing;

    const src = try ipv6.Address.parse("2001:db8::1");
    const dst = try ipv6.Address.parse("2001:db8::2");

    const payload = [_]u8{ 128, 0, 0, 0, 0, 1, 0, 1 };

    const checksum = computeChecksum(src, dst, &payload);
    try testing.expect(checksum != 0);

    // Verify
    var payload_with_checksum = payload;
    payload_with_checksum[2] = @intCast(checksum >> 8);
    payload_with_checksum[3] = @intCast(checksum & 0xFF);

    try testing.expect(verifyChecksum(src, dst, &payload_with_checksum));
}

test "ICMPv6 statistics" {
    const testing = std.testing;

    var stats = Statistics.init();

    stats.incrementEchoRequestsSent();
    stats.incrementEchoRequestsSent();
    stats.incrementEchoRepliesReceived();

    try testing.expectEqual(@as(u64, 2), stats.echo_requests_sent.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), stats.echo_replies_received.load(.monotonic));
}
