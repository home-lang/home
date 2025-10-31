// DHCPv6 Implementation
// RFC 8415 - Dynamic Host Configuration Protocol for IPv6 (DHCPv6)

const std = @import("std");
const ipv6 = @import("ipv6.zig");

/// DHCPv6 message types
pub const MessageType = enum(u8) {
    solicit = 1,
    advertise = 2,
    request = 3,
    confirm = 4,
    renew = 5,
    rebind = 6,
    reply = 7,
    release = 8,
    decline = 9,
    reconfigure = 10,
    information_request = 11,
    relay_forw = 12,
    relay_repl = 13,
    _,
};

/// DHCPv6 option codes
pub const OptionCode = enum(u16) {
    client_id = 1,
    server_id = 2,
    ia_na = 3, // Identity Association for Non-temporary Addresses
    ia_ta = 4, // Identity Association for Temporary Addresses
    ia_addr = 5,
    oro = 6, // Option Request Option
    preference = 7,
    elapsed_time = 8,
    relay_msg = 9,
    auth = 11,
    unicast = 12,
    status_code = 13,
    rapid_commit = 14,
    user_class = 15,
    vendor_class = 16,
    vendor_opts = 17,
    interface_id = 18,
    reconf_msg = 19,
    reconf_accept = 20,
    dns_servers = 23,
    domain_list = 24,
    ia_pd = 25, // Identity Association for Prefix Delegation
    ia_prefix = 26,
    _,
};

/// DHCPv6 message header
pub const MessageHeader = extern struct {
    msg_type: u8,
    transaction_id: [3]u8,

    pub fn init(msg_type: MessageType, transaction_id: [3]u8) MessageHeader {
        return .{
            .msg_type = @intFromEnum(msg_type),
            .transaction_id = transaction_id,
        };
    }

    pub fn getType(self: MessageHeader) MessageType {
        return @enumFromInt(self.msg_type);
    }
};

/// DHCPv6 option header
pub const OptionHeader = packed struct {
    code: u16,
    length: u16,

    pub fn init(code: OptionCode, length: u16) OptionHeader {
        return .{
            .code = @intFromEnum(code),
            .length = length,
        };
    }
};

/// DUID (DHCP Unique Identifier) types
pub const DuidType = enum(u16) {
    link_layer_time = 1, // DUID-LLT
    enterprise = 2, // DUID-EN
    link_layer = 3, // DUID-LL
    uuid = 4, // DUID-UUID
    _,
};

/// DUID (DHCP Unique Identifier)
pub const Duid = struct {
    duid_type: DuidType,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, duid_type: DuidType, data: []const u8) !Duid {
        const data_copy = try allocator.alloc(u8, data.len);
        @memcpy(data_copy, data);
        return .{
            .duid_type = duid_type,
            .data = data_copy,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Duid) void {
        self.allocator.free(self.data);
    }

    /// Create DUID-LL from MAC address
    pub fn fromLinkLayer(allocator: std.mem.Allocator, hardware_type: u16, mac: []const u8) !Duid {
        var data = try allocator.alloc(u8, 2 + mac.len);
        data[0] = @intCast(hardware_type >> 8);
        data[1] = @intCast(hardware_type & 0xFF);
        @memcpy(data[2..], mac);

        return .{
            .duid_type = .link_layer,
            .data = data,
            .allocator = allocator,
        };
    }
};

/// Identity Association for Non-temporary Addresses (IA_NA)
pub const IA_NA = struct {
    iaid: u32, // Identity Association Identifier
    t1: u32, // Renewal time
    t2: u32, // Rebinding time
    options: std.ArrayList(IA_Address),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, iaid: u32, t1: u32, t2: u32) IA_NA {
        return .{
            .iaid = iaid,
            .t1 = t1,
            .t2 = t2,
            .options = std.ArrayList(IA_Address){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IA_NA) void {
        self.options.deinit(self.allocator);
    }

    pub fn addAddress(self: *IA_NA, address: IA_Address) !void {
        try self.options.append(self.allocator, address);
    }
};

/// IA Address option
pub const IA_Address = struct {
    address: ipv6.Address,
    preferred_lifetime: u32,
    valid_lifetime: u32,

    pub fn init(address: ipv6.Address, preferred: u32, valid: u32) IA_Address {
        return .{
            .address = address,
            .preferred_lifetime = preferred,
            .valid_lifetime = valid,
        };
    }
};

/// Identity Association for Prefix Delegation (IA_PD)
pub const IA_PD = struct {
    iaid: u32,
    t1: u32,
    t2: u32,
    prefixes: std.ArrayList(IA_Prefix),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, iaid: u32, t1: u32, t2: u32) IA_PD {
        return .{
            .iaid = iaid,
            .t1 = t1,
            .t2 = t2,
            .prefixes = std.ArrayList(IA_Prefix){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IA_PD) void {
        self.prefixes.deinit(self.allocator);
    }

    pub fn addPrefix(self: *IA_PD, prefix: IA_Prefix) !void {
        try self.prefixes.append(self.allocator, prefix);
    }
};

/// IA Prefix option
pub const IA_Prefix = struct {
    prefix: ipv6.Prefix,
    preferred_lifetime: u32,
    valid_lifetime: u32,

    pub fn init(prefix: ipv6.Prefix, preferred: u32, valid: u32) IA_Prefix {
        return .{
            .prefix = prefix,
            .preferred_lifetime = preferred,
            .valid_lifetime = valid,
        };
    }
};

/// Status code
pub const StatusCode = enum(u16) {
    success = 0,
    unspec_fail = 1,
    no_addrs_avail = 2,
    no_binding = 3,
    not_on_link = 4,
    use_multicast = 5,
    no_prefix_avail = 6,
    _,
};

/// DHCPv6 client state
pub const ClientState = enum {
    init,
    solicit,
    request,
    confirm,
    renew,
    rebind,
    bound,
    release,
};

/// DHCPv6 client
pub const Client = struct {
    state: ClientState,
    client_duid: Duid,
    server_duid: ?Duid,
    transaction_id: [3]u8,
    ia_na: ?IA_NA,
    ia_pd: ?IA_PD,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, client_duid: Duid) Client {
        return .{
            .state = .init,
            .client_duid = client_duid,
            .server_duid = null,
            .transaction_id = [_]u8{0} ** 3,
            .ia_na = null,
            .ia_pd = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client) void {
        self.client_duid.deinit();
        if (self.server_duid) |*duid| {
            duid.deinit();
        }
        if (self.ia_na) |*ia| {
            ia.deinit();
        }
        if (self.ia_pd) |*ia| {
            ia.deinit();
        }
    }

    /// Generate new transaction ID
    pub fn newTransactionId(self: *Client) void {
        const seed: u64 = @intCast(std.time.milliTimestamp());
        var rng = std.Random.DefaultPrng.init(seed);
        const random = rng.random();
        random.bytes(&self.transaction_id);
    }

    /// Start address acquisition
    pub fn solicit(self: *Client) void {
        self.state = .solicit;
        self.newTransactionId();
    }

    /// Request specific address
    pub fn request(self: *Client) void {
        self.state = .request;
        self.newTransactionId();
    }

    /// Renew lease
    pub fn renew(self: *Client) void {
        self.state = .renew;
        self.newTransactionId();
    }

    /// Release address
    pub fn release(self: *Client) void {
        self.state = .release;
        self.newTransactionId();
    }
};

/// DHCPv6 server
pub const Server = struct {
    server_duid: Duid,
    address_pool: std.ArrayList(ipv6.Address),
    prefix_pool: std.ArrayList(ipv6.Prefix),
    leases: std.AutoHashMap(u32, Lease),
    allocator: std.mem.Allocator,

    pub const Lease = struct {
        client_duid: Duid,
        address: ipv6.Address,
        valid_lifetime: u32,
        preferred_lifetime: u32,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator, server_duid: Duid) Server {
        return .{
            .server_duid = server_duid,
            .address_pool = std.ArrayList(ipv6.Address){},
            .prefix_pool = std.ArrayList(ipv6.Prefix){},
            .leases = std.AutoHashMap(u32, Lease).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.server_duid.deinit();
        self.address_pool.deinit(self.allocator);
        self.prefix_pool.deinit(self.allocator);

        var it = self.leases.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.client_duid.deinit();
        }
        self.leases.deinit();
    }

    pub fn addAddressToPool(self: *Server, address: ipv6.Address) !void {
        try self.address_pool.append(self.allocator, address);
    }

    pub fn addPrefixToPool(self: *Server, prefix: ipv6.Prefix) !void {
        try self.prefix_pool.append(self.allocator, prefix);
    }
};

/// DHCPv6 multicast addresses
pub const MulticastAddresses = struct {
    pub const all_dhcp_relay_agents_and_servers = ipv6.Address{
        .octets = [_]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2 },
    };

    pub const all_dhcp_servers = ipv6.Address{
        .octets = [_]u8{ 0xff, 0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 3 },
    };
};

/// DHCPv6 ports
pub const Ports = struct {
    pub const CLIENT: u16 = 546;
    pub const SERVER: u16 = 547;
};

test "DHCPv6 message header" {
    const testing = std.testing;

    const transaction_id = [_]u8{ 0x12, 0x34, 0x56 };
    const header = MessageHeader.init(.solicit, transaction_id);

    try testing.expectEqual(MessageType.solicit, header.getType());
    try testing.expect(std.mem.eql(u8, &transaction_id, &header.transaction_id));
}

test "DUID from link layer" {
    const testing = std.testing;

    const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    var duid = try Duid.fromLinkLayer(testing.allocator, 1, &mac); // Hardware type 1 = Ethernet
    defer duid.deinit();

    try testing.expectEqual(DuidType.link_layer, duid.duid_type);
    try testing.expectEqual(@as(usize, 8), duid.data.len); // 2 + 6
}

test "IA_NA with addresses" {
    const testing = std.testing;

    var ia_na = IA_NA.init(testing.allocator, 1, 3600, 7200);
    defer ia_na.deinit();

    const addr = try ipv6.Address.parse("2001:db8::1");
    const ia_addr = IA_Address.init(addr, 3600, 7200);
    try ia_na.addAddress(ia_addr);

    try testing.expectEqual(@as(u32, 1), ia_na.iaid);
    try testing.expectEqual(@as(usize, 1), ia_na.options.items.len);
}

test "DHCPv6 client state machine" {
    const testing = std.testing;

    const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const duid = try Duid.fromLinkLayer(testing.allocator, 1, &mac);

    var client = Client.init(testing.allocator, duid);
    defer client.deinit();

    try testing.expectEqual(ClientState.init, client.state);

    client.solicit();
    try testing.expectEqual(ClientState.solicit, client.state);

    client.request();
    try testing.expectEqual(ClientState.request, client.state);
}

test "DHCPv6 server" {
    const testing = std.testing;

    const mac = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const duid = try Duid.fromLinkLayer(testing.allocator, 1, &mac);

    var server = Server.init(testing.allocator, duid);
    defer server.deinit();

    const addr = try ipv6.Address.parse("2001:db8::100");
    try server.addAddressToPool(addr);

    try testing.expectEqual(@as(usize, 1), server.address_pool.items.len);
}

test "IA_PD prefix delegation" {
    const testing = std.testing;

    var ia_pd = IA_PD.init(testing.allocator, 2, 3600, 7200);
    defer ia_pd.deinit();

    const prefix = try ipv6.Prefix.init(try ipv6.Address.parse("2001:db8:1::"), 48);
    const ia_prefix = IA_Prefix.init(prefix, 3600, 7200);
    try ia_pd.addPrefix(ia_prefix);

    try testing.expectEqual(@as(u32, 2), ia_pd.iaid);
    try testing.expectEqual(@as(usize, 1), ia_pd.prefixes.items.len);
}
