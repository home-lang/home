// IPv6 Routing Implementation
// RFC 8200 - IPv6 routing and forwarding

const std = @import("std");
const ipv6 = @import("ipv6.zig");

/// Route type
pub const RouteType = enum {
    direct, // Directly connected network
    indirect, // Via gateway
    host, // Host-specific route
    default, // Default route
};

/// Route entry
pub const Route = struct {
    destination: ipv6.Prefix,
    gateway: ?ipv6.Address,
    interface_index: u32,
    route_type: RouteType,
    metric: u32,
    lifetime: u32, // Seconds, 0 = infinite
    timestamp: i64,

    pub fn init(
        destination: ipv6.Prefix,
        gateway: ?ipv6.Address,
        interface_index: u32,
        route_type: RouteType,
        metric: u32,
    ) Route {
        return .{
            .destination = destination,
            .gateway = gateway,
            .interface_index = interface_index,
            .route_type = route_type,
            .metric = metric,
            .lifetime = 0,
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn isExpired(self: *const Route) bool {
        if (self.lifetime == 0) return false;
        const now = std.time.timestamp();
        return (now - self.timestamp) > self.lifetime;
    }

    pub fn matches(self: *const Route, addr: ipv6.Address) bool {
        return self.destination.contains(addr);
    }
};

/// Routing table
pub const RoutingTable = struct {
    routes: std.ArrayList(Route),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RoutingTable {
        return .{
            .routes = std.ArrayList(Route){},
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RoutingTable) void {
        self.routes.deinit(self.allocator);
    }

    /// Add route to table
    pub fn addRoute(self: *RoutingTable, route: Route) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.routes.append(self.allocator, route);
        self.sortRoutes();
    }

    /// Remove route
    pub fn removeRoute(self: *RoutingTable, destination: ipv6.Prefix) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.routes.items, 0..) |route, i| {
            if (route.destination.address.eql(destination.address) and
                route.destination.length == destination.length)
            {
                _ = self.routes.orderedRemove(i);
                return true;
            }
        }

        return false;
    }

    /// Lookup best matching route
    pub fn lookup(self: *RoutingTable, addr: ipv6.Address) ?Route {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove expired routes
        var i: usize = 0;
        while (i < self.routes.items.len) {
            if (self.routes.items[i].isExpired()) {
                _ = self.routes.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Find best match (longest prefix match)
        var best_match: ?Route = null;
        var best_length: u8 = 0;

        for (self.routes.items) |route| {
            if (route.matches(addr) and route.destination.length >= best_length) {
                best_match = route;
                best_length = route.destination.length;
            }
        }

        return best_match;
    }

    /// Sort routes by prefix length (longest first) and metric
    fn sortRoutes(self: *RoutingTable) void {
        const Context = struct {
            fn lessThan(_: @This(), a: Route, b: Route) bool {
                if (a.destination.length != b.destination.length) {
                    return a.destination.length > b.destination.length;
                }
                return a.metric < b.metric;
            }
        };

        std.mem.sort(Route, self.routes.items, Context{}, Context.lessThan);
    }

    /// Get route count
    pub fn getRouteCount(self: *const RoutingTable) usize {
        return self.routes.items.len;
    }

    /// Add default route
    pub fn addDefaultRoute(
        self: *RoutingTable,
        gateway: ipv6.Address,
        interface_index: u32,
        metric: u32,
    ) !void {
        const default_prefix = try ipv6.Prefix.init(ipv6.Address.unspecified, 0);
        const route = Route.init(default_prefix, gateway, interface_index, .default, metric);
        try self.addRoute(route);
    }
};

/// Routing header types (RFC 8200)
pub const RoutingType = enum(u8) {
    source_route = 0, // Deprecated
    type_2 = 2, // Mobile IPv6
    segment_routing = 4, // Segment Routing Header
    _,
};

/// Routing header
pub const RoutingHeader = packed struct {
    next_header: u8,
    hdr_ext_len: u8,
    routing_type: u8,
    segments_left: u8,
    type_specific_data: [4]u8,

    pub fn init(next_header: u8, routing_type: RoutingType, segments_left: u8) RoutingHeader {
        return .{
            .next_header = next_header,
            .hdr_ext_len = 0,
            .routing_type = @intFromEnum(routing_type),
            .segments_left = segments_left,
            .type_specific_data = [_]u8{0} ** 4,
        };
    }
};

/// Fragment header (RFC 8200)
pub const FragmentHeader = packed struct {
    next_header: u8,
    reserved: u8,
    fragment_offset_flags: u16, // offset(13 bits) + reserved(2) + M flag(1)
    identification: u32,

    pub fn init(next_header: u8, offset: u13, more_fragments: bool, id: u32) FragmentHeader {
        const offset_u16: u16 = @intCast(offset);
        const flags: u16 = if (more_fragments) 1 else 0;
        return .{
            .next_header = next_header,
            .reserved = 0,
            .fragment_offset_flags = (offset_u16 << 3) | flags,
            .identification = id,
        };
    }

    pub fn getOffset(self: FragmentHeader) u13 {
        return @intCast(self.fragment_offset_flags >> 3);
    }

    pub fn hasMoreFragments(self: FragmentHeader) bool {
        return (self.fragment_offset_flags & 1) == 1;
    }
};

/// Path MTU Discovery
pub const PathMTU = struct {
    destination: ipv6.Address,
    mtu: u32,
    timestamp: i64,

    pub const MIN_MTU: u32 = 1280; // RFC 8200 minimum
    pub const DEFAULT_MTU: u32 = 1500;

    pub fn init(destination: ipv6.Address, mtu: u32) PathMTU {
        return .{
            .destination = destination,
            .mtu = @max(mtu, MIN_MTU),
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn isExpired(self: *const PathMTU, timeout: i64) bool {
        const now = std.time.timestamp();
        return (now - self.timestamp) > timeout;
    }
};

/// Path MTU cache
pub const PathMTUCache = struct {
    entries: std.AutoHashMap(ipv6.Address, PathMTU),
    mutex: std.Thread.Mutex,
    timeout: i64, // Seconds

    pub fn init(allocator: std.mem.Allocator, timeout: i64) PathMTUCache {
        return .{
            .entries = std.AutoHashMap(ipv6.Address, PathMTU).init(allocator),
            .mutex = std.Thread.Mutex{},
            .timeout = timeout,
        };
    }

    pub fn deinit(self: *PathMTUCache) void {
        self.entries.deinit();
    }

    pub fn update(self: *PathMTUCache, destination: ipv6.Address, mtu: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = PathMTU.init(destination, mtu);
        try self.entries.put(destination, entry);
    }

    pub fn lookup(self: *PathMTUCache, destination: ipv6.Address) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(destination)) |entry| {
            if (!entry.isExpired(self.timeout)) {
                return entry.mtu;
            }
            _ = self.entries.remove(destination);
        }

        return null;
    }
};

/// Forwarding decision
pub const ForwardingDecision = struct {
    action: Action,
    next_hop: ?ipv6.Address,
    interface_index: u32,
    mtu: u32,

    pub const Action = enum {
        deliver, // Deliver to local stack
        forward, // Forward to next hop
        drop, // Drop packet
    };

    pub fn deliver(interface_index: u32) ForwardingDecision {
        return .{
            .action = .deliver,
            .next_hop = null,
            .interface_index = interface_index,
            .mtu = PathMTU.DEFAULT_MTU,
        };
    }

    pub fn forward(next_hop: ipv6.Address, interface_index: u32, mtu: u32) ForwardingDecision {
        return .{
            .action = .forward,
            .next_hop = next_hop,
            .interface_index = interface_index,
            .mtu = mtu,
        };
    }

    pub fn drop() ForwardingDecision {
        return .{
            .action = .drop,
            .next_hop = null,
            .interface_index = 0,
            .mtu = 0,
        };
    }
};

test "routing table" {
    const testing = std.testing;

    var table = RoutingTable.init(testing.allocator);
    defer table.deinit();

    // Add route
    const prefix = try ipv6.Prefix.init(try ipv6.Address.parse("2001:db8::"), 32);
    const gateway = try ipv6.Address.parse("fe80::1");
    const route = Route.init(prefix, gateway, 1, .indirect, 10);

    try table.addRoute(route);
    try testing.expectEqual(@as(usize, 1), table.getRouteCount());

    // Lookup
    const addr = try ipv6.Address.parse("2001:db8::100");
    const found = table.lookup(addr);
    try testing.expect(found != null);
    try testing.expect(found.?.gateway.?.eql(gateway));
}

test "default route" {
    const testing = std.testing;

    var table = RoutingTable.init(testing.allocator);
    defer table.deinit();

    const gateway = try ipv6.Address.parse("fe80::1");
    try table.addDefaultRoute(gateway, 1, 1);

    // Should match any address
    const addr = try ipv6.Address.parse("2606:2800:220:1:248:1893:25c8:1946");
    const found = table.lookup(addr);
    try testing.expect(found != null);
    try testing.expect(found.?.gateway.?.eql(gateway));
}

test "longest prefix match" {
    const testing = std.testing;

    var table = RoutingTable.init(testing.allocator);
    defer table.deinit();

    // Add broad prefix
    const prefix1 = try ipv6.Prefix.init(try ipv6.Address.parse("2001:db8::"), 32);
    const route1 = Route.init(prefix1, try ipv6.Address.parse("fe80::1"), 1, .indirect, 10);
    try table.addRoute(route1);

    // Add more specific prefix
    const prefix2 = try ipv6.Prefix.init(try ipv6.Address.parse("2001:db8:1::"), 48);
    const route2 = Route.init(prefix2, try ipv6.Address.parse("fe80::2"), 2, .indirect, 10);
    try table.addRoute(route2);

    // Should match more specific route
    const addr = try ipv6.Address.parse("2001:db8:1::100");
    const found = table.lookup(addr);
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 2), found.?.interface_index);
}

test "fragment header" {
    const testing = std.testing;

    const frag = FragmentHeader.init(@intFromEnum(ipv6.Protocol.tcp), 512, true, 0x12345678);

    try testing.expectEqual(@as(u13, 512), frag.getOffset());
    try testing.expect(frag.hasMoreFragments());
    try testing.expectEqual(@as(u32, 0x12345678), frag.identification);
}

test "path MTU discovery" {
    const testing = std.testing;

    var cache = PathMTUCache.init(testing.allocator, 600); // 10 minutes
    defer cache.deinit();

    const dest = try ipv6.Address.parse("2001:db8::1");
    try cache.update(dest, 1280);

    const mtu = cache.lookup(dest);
    try testing.expect(mtu != null);
    try testing.expectEqual(@as(u32, 1280), mtu.?);
}

test "route expiration" {
    const testing = std.testing;

    var table = RoutingTable.init(testing.allocator);
    defer table.deinit();

    const prefix = try ipv6.Prefix.init(try ipv6.Address.parse("2001:db8::"), 32);
    var route = Route.init(prefix, try ipv6.Address.parse("fe80::1"), 1, .indirect, 10);
    route.lifetime = 1; // 1 second
    route.timestamp = std.time.timestamp() - 2; // 2 seconds ago

    try table.addRoute(route);

    // Should be expired and removed during lookup
    const addr = try ipv6.Address.parse("2001:db8::100");
    const found = table.lookup(addr);
    try testing.expect(found == null);
    try testing.expectEqual(@as(usize, 0), table.getRouteCount());
}
