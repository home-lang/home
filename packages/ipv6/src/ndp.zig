// Neighbor Discovery Protocol (NDP)
// RFC 4861 - Neighbor Discovery for IP version 6 (IPv6)

const std = @import("std");
const ipv6 = @import("ipv6.zig");
const icmpv6 = @import("icmpv6.zig");

/// NDP option types
pub const OptionType = enum(u8) {
    source_link_layer = 1,
    target_link_layer = 2,
    prefix_information = 3,
    redirected_header = 4,
    mtu = 5,
    _,
};

/// NDP option header
pub const OptionHeader = packed struct {
    option_type: u8,
    length: u8, // In units of 8 octets

    pub fn init(opt_type: OptionType, length: u8) OptionHeader {
        return .{
            .option_type = @intFromEnum(opt_type),
            .length = length,
        };
    }
};

/// Link-layer address option
pub const LinkLayerOption = struct {
    header: OptionHeader,
    address: [6]u8, // MAC address

    pub fn init(is_source: bool, mac: [6]u8) LinkLayerOption {
        const opt_type = if (is_source) OptionType.source_link_layer else OptionType.target_link_layer;
        return .{
            .header = OptionHeader.init(opt_type, 1), // 8 bytes total
            .address = mac,
        };
    }
};

/// Prefix information option
pub const PrefixInformationOption = struct {
    header: OptionHeader,
    prefix_length: u8,
    flags: u8, // L and A flags
    valid_lifetime: u32,
    preferred_lifetime: u32,
    reserved: u32,
    prefix: ipv6.Address,

    pub const Flags = packed struct {
        reserved: u6 = 0,
        autoconfig: bool, // A flag
        on_link: bool, // L flag

        pub fn toU8(self: Flags) u8 {
            return @bitCast(self);
        }
    };

    pub fn init(
        prefix: ipv6.Address,
        prefix_length: u8,
        flags: Flags,
        valid_lifetime: u32,
        preferred_lifetime: u32,
    ) PrefixInformationOption {
        return .{
            .header = OptionHeader.init(.prefix_information, 4), // 32 bytes
            .prefix_length = prefix_length,
            .flags = flags.toU8(),
            .valid_lifetime = valid_lifetime,
            .preferred_lifetime = preferred_lifetime,
            .reserved = 0,
            .prefix = prefix,
        };
    }
};

/// MTU option
pub const MtuOption = struct {
    header: OptionHeader,
    reserved: u16,
    mtu: u32,

    pub fn init(mtu: u32) MtuOption {
        return .{
            .header = OptionHeader.init(.mtu, 1), // 8 bytes
            .reserved = 0,
            .mtu = mtu,
        };
    }
};

/// Router Solicitation message
pub const RouterSolicitation = struct {
    header: icmpv6.Header,
    reserved: u32,
    options: std.ArrayList(LinkLayerOption),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RouterSolicitation {
        return .{
            .header = icmpv6.Header.init(.router_solicitation, 0),
            .reserved = 0,
            .options = std.ArrayList(LinkLayerOption){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RouterSolicitation) void {
        self.options.deinit(self.allocator);
    }

    pub fn addSourceLinkLayer(self: *RouterSolicitation, mac: [6]u8) !void {
        try self.options.append(self.allocator, LinkLayerOption.init(true, mac));
    }
};

/// Router Advertisement message
pub const RouterAdvertisement = struct {
    header: icmpv6.Header,
    cur_hop_limit: u8,
    flags: u8, // M, O, H, Prf, P, R
    router_lifetime: u16,
    reachable_time: u32,
    retrans_timer: u32,
    options: std.ArrayList(OptionHeader),
    allocator: std.mem.Allocator,

    pub const Flags = packed struct {
        reserved: u3 = 0,
        home_agent: bool, // H flag
        other_config: bool, // O flag
        managed_config: bool, // M flag
        prf: u2, // Router preference

        pub fn toU8(self: Flags) u8 {
            return @bitCast(self);
        }
    };

    pub fn init(allocator: std.mem.Allocator, flags: Flags, lifetime: u16) RouterAdvertisement {
        return .{
            .header = icmpv6.Header.init(.router_advertisement, 0),
            .cur_hop_limit = 64,
            .flags = flags.toU8(),
            .router_lifetime = lifetime,
            .reachable_time = 0,
            .retrans_timer = 0,
            .options = std.ArrayList(OptionHeader){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RouterAdvertisement) void {
        self.options.deinit(self.allocator);
    }
};

/// Neighbor Solicitation message
pub const NeighborSolicitation = struct {
    header: icmpv6.Header,
    reserved: u32,
    target: ipv6.Address,
    options: std.ArrayList(LinkLayerOption),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, target: ipv6.Address) NeighborSolicitation {
        return .{
            .header = icmpv6.Header.init(.neighbor_solicitation, 0),
            .reserved = 0,
            .target = target,
            .options = std.ArrayList(LinkLayerOption){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NeighborSolicitation) void {
        self.options.deinit(self.allocator);
    }

    pub fn addSourceLinkLayer(self: *NeighborSolicitation, mac: [6]u8) !void {
        try self.options.append(self.allocator, LinkLayerOption.init(true, mac));
    }
};

/// Neighbor Advertisement message
pub const NeighborAdvertisement = struct {
    header: icmpv6.Header,
    flags: u32, // R, S, O flags + reserved
    target: ipv6.Address,
    options: std.ArrayList(LinkLayerOption),
    allocator: std.mem.Allocator,

    pub const Flags = packed struct {
        reserved: u29 = 0,
        override: bool, // O flag
        solicited: bool, // S flag
        router: bool, // R flag

        pub fn toU32(self: Flags) u32 {
            return @bitCast(self);
        }
    };

    pub fn init(allocator: std.mem.Allocator, target: ipv6.Address, flags: Flags) NeighborAdvertisement {
        return .{
            .header = icmpv6.Header.init(.neighbor_advertisement, 0),
            .flags = flags.toU32(),
            .target = target,
            .options = std.ArrayList(LinkLayerOption){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NeighborAdvertisement) void {
        self.options.deinit(self.allocator);
    }

    pub fn addTargetLinkLayer(self: *NeighborAdvertisement, mac: [6]u8) !void {
        try self.options.append(self.allocator, LinkLayerOption.init(false, mac));
    }
};

/// Neighbor cache entry state
pub const NeighborState = enum {
    incomplete, // Address resolution in progress
    reachable, // Reachability confirmed
    stale, // No recent confirmation
    delay, // Waiting for upper-layer confirmation
    probe, // Sending probes
};

/// Neighbor cache entry
pub const NeighborEntry = struct {
    address: ipv6.Address,
    link_layer: [6]u8,
    state: NeighborState,
    is_router: bool,
    last_update: i64,
    probes_sent: u32,

    pub fn init(address: ipv6.Address, link_layer: [6]u8) NeighborEntry {
        return .{
            .address = address,
            .link_layer = link_layer,
            .state = .reachable,
            .is_router = false,
            .last_update = std.time.timestamp(),
            .probes_sent = 0,
        };
    }

    pub fn markStale(self: *NeighborEntry) void {
        self.state = .stale;
        self.last_update = std.time.timestamp();
    }

    pub fn markReachable(self: *NeighborEntry) void {
        self.state = .reachable;
        self.last_update = std.time.timestamp();
        self.probes_sent = 0;
    }
};

/// Neighbor cache
pub const NeighborCache = struct {
    entries: std.AutoHashMap(ipv6.Address, NeighborEntry),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NeighborCache {
        return .{
            .entries = std.AutoHashMap(ipv6.Address, NeighborEntry).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NeighborCache) void {
        self.entries.deinit();
    }

    pub fn add(self: *NeighborCache, address: ipv6.Address, link_layer: [6]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = NeighborEntry.init(address, link_layer);
        try self.entries.put(address, entry);
    }

    pub fn lookup(self: *NeighborCache, address: ipv6.Address) ?NeighborEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.entries.get(address);
    }

    pub fn update(self: *NeighborCache, address: ipv6.Address, link_layer: [6]u8, is_router: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.getPtr(address)) |entry| {
            entry.link_layer = link_layer;
            entry.is_router = is_router;
            entry.markReachable();
        } else {
            var entry = NeighborEntry.init(address, link_layer);
            entry.is_router = is_router;
            try self.entries.put(address, entry);
        }
    }

    pub fn remove(self: *NeighborCache, address: ipv6.Address) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.entries.remove(address);
    }

    pub fn getEntryCount(self: *const NeighborCache) usize {
        return self.entries.count();
    }
};

/// Duplicate Address Detection (DAD) state
pub const DadState = enum {
    tentative,
    verified,
    duplicate,
};

/// Duplicate Address Detection
pub const DuplicateAddressDetection = struct {
    address: ipv6.Address,
    state: DadState,
    probes_sent: u32,
    max_probes: u32,

    pub fn init(address: ipv6.Address) DuplicateAddressDetection {
        return .{
            .address = address,
            .state = .tentative,
            .probes_sent = 0,
            .max_probes = 1, // RFC 4862 default
        };
    }

    pub fn sendProbe(self: *DuplicateAddressDetection) bool {
        if (self.probes_sent >= self.max_probes) {
            self.state = .verified;
            return false;
        }

        self.probes_sent += 1;
        return true;
    }

    pub fn markDuplicate(self: *DuplicateAddressDetection) void {
        self.state = .duplicate;
    }

    pub fn isComplete(self: *const DuplicateAddressDetection) bool {
        return self.state == .verified or self.state == .duplicate;
    }
};

test "neighbor solicitation" {
    const testing = std.testing;

    const target = try ipv6.Address.parse("2001:db8::1");
    var ns = NeighborSolicitation.init(testing.allocator, target);
    defer ns.deinit();

    const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    try ns.addSourceLinkLayer(mac);

    try testing.expectEqual(@as(usize, 1), ns.options.items.len);
    try testing.expect(std.mem.eql(u8, &mac, &ns.options.items[0].address));
}

test "neighbor advertisement" {
    const testing = std.testing;

    const target = try ipv6.Address.parse("2001:db8::2");
    const flags = NeighborAdvertisement.Flags{
        .router = true,
        .solicited = true,
        .override = true,
    };

    var na = NeighborAdvertisement.init(testing.allocator, target, flags);
    defer na.deinit();

    const mac = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    try na.addTargetLinkLayer(mac);

    try testing.expectEqual(@as(usize, 1), na.options.items.len);
}

test "neighbor cache" {
    const testing = std.testing;

    var cache = NeighborCache.init(testing.allocator);
    defer cache.deinit();

    const addr = try ipv6.Address.parse("2001:db8::1");
    const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };

    try cache.add(addr, mac);
    try testing.expectEqual(@as(usize, 1), cache.getEntryCount());

    const entry = cache.lookup(addr);
    try testing.expect(entry != null);
    try testing.expect(std.mem.eql(u8, &mac, &entry.?.link_layer));
    try testing.expectEqual(NeighborState.reachable, entry.?.state);

    _ = cache.remove(addr);
    try testing.expectEqual(@as(usize, 0), cache.getEntryCount());
}

test "duplicate address detection" {
    const testing = std.testing;

    const addr = try ipv6.Address.parse("fe80::1");
    var dad = DuplicateAddressDetection.init(addr);

    try testing.expectEqual(DadState.tentative, dad.state);
    try testing.expect(!dad.isComplete());

    // Send probe
    try testing.expect(dad.sendProbe());
    try testing.expectEqual(@as(u32, 1), dad.probes_sent);

    // Second probe should complete
    try testing.expect(!dad.sendProbe());
    try testing.expectEqual(DadState.verified, dad.state);
    try testing.expect(dad.isComplete());
}

test "prefix information option" {
    const testing = std.testing;

    const prefix = try ipv6.Address.parse("2001:db8::");
    const flags = PrefixInformationOption.Flags{
        .on_link = true,
        .autoconfig = true,
    };

    const opt = PrefixInformationOption.init(prefix, 64, flags, 86400, 14400);

    try testing.expectEqual(@as(u8, 64), opt.prefix_length);
    try testing.expectEqual(@as(u32, 86400), opt.valid_lifetime);
    try testing.expectEqual(@as(u32, 14400), opt.preferred_lifetime);
}

test "router advertisement" {
    const testing = std.testing;

    const flags = RouterAdvertisement.Flags{
        .managed_config = false,
        .other_config = false,
        .home_agent = false,
        .prf = 0,
    };

    var ra = RouterAdvertisement.init(testing.allocator, flags, 1800);
    defer ra.deinit();

    try testing.expectEqual(@as(u8, 64), ra.cur_hop_limit);
    try testing.expectEqual(@as(u16, 1800), ra.router_lifetime);
}
