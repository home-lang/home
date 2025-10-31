# IPv6 Networking

Comprehensive IPv6 networking implementation for Home OS with full support for addressing, routing, neighbor discovery, ICMPv6, and DHCPv6.

## Features

- **IPv6 Addressing**: Complete address handling with RFC 5952 formatting
- **ICMPv6**: Internet Control Message Protocol for IPv6 (RFC 4443)
- **Neighbor Discovery Protocol (NDP)**: Address resolution and router discovery (RFC 4861)
- **IPv6 Routing**: Routing table management with longest prefix matching
- **DHCPv6**: Dynamic Host Configuration Protocol for IPv6 (RFC 8415)
- **Path MTU Discovery**: Automatic MTU detection and caching
- **Fragmentation**: IPv6 fragment header support

## Architecture

### Modules

```
ipv6/
├── ipv6.zig      # Core IPv6 addressing and headers
├── icmpv6.zig    # ICMPv6 protocol implementation
├── ndp.zig       # Neighbor Discovery Protocol
├── routing.zig   # IPv6 routing and forwarding
└── dhcpv6.zig    # DHCPv6 client and server
```

## Usage

### IPv6 Address Handling

```zig
const ipv6 = @import("ipv6");

// Parse addresses
const addr1 = try ipv6.Address.parse("2001:db8::1");
const addr2 = try ipv6.Address.parse("fe80::1");
const loopback = try ipv6.Address.parse("::1");

// Check address properties
if (addr.isLinkLocal()) {
    std.debug.print("Link-local address\n", .{});
}

if (addr.isMulticast()) {
    const scope = addr.getMulticastScope().?;
    std.debug.print("Multicast scope: {}\n", .{scope});
}

// Create solicited-node multicast address
const solicited = addr.solicitedNode();
std.debug.print("Solicited-node: {}\n", .{solicited});

// Format addresses (RFC 5952)
std.debug.print("Address: {}\n", .{addr});
```

### IPv6 Prefixes

```zig
// Create prefix
const prefix = try ipv6.Prefix.init(
    try ipv6.Address.parse("2001:db8::"),
    64
);

// Check if address is in prefix
const addr = try ipv6.Address.parse("2001:db8::1234");
if (prefix.contains(addr)) {
    std.debug.print("Address is in prefix\n", .{});
}

// Get network address
const network = prefix.getNetwork();
std.debug.print("Network: {}\n", .{network});
```

### ICMPv6 Echo (Ping)

```zig
const icmpv6 = @import("icmpv6");

// Create echo request
const data = "Hello, IPv6!";
var echo = icmpv6.EchoMessage.init(false, 0x1234, 1, data);

// Serialize message
const packet = try echo.serialize(allocator);
defer allocator.free(packet);

// Compute checksum
const src = try ipv6.Address.parse("2001:db8::1");
const dst = try ipv6.Address.parse("2001:db8::2");
const checksum = icmpv6.computeChecksum(src, dst, packet);

// Verify checksum
if (icmpv6.verifyChecksum(src, dst, packet)) {
    std.debug.print("Checksum valid\n", .{});
}
```

### ICMPv6 Error Messages

```zig
// Destination unreachable
const unreachable = icmpv6.DestinationUnreachable.init(
    .no_route,
    invoking_packet,
);

// Packet too big (for Path MTU Discovery)
const too_big = icmpv6.PacketTooBig.init(1280, invoking_packet);

// Time exceeded
const time_exceeded = icmpv6.TimeExceeded.init(
    .hop_limit,
    invoking_packet,
);
```

### Neighbor Discovery Protocol (NDP)

#### Neighbor Solicitation

```zig
const ndp = @import("ndp");

// Create neighbor solicitation
const target = try ipv6.Address.parse("2001:db8::1");
var ns = ndp.NeighborSolicitation.init(allocator, target);
defer ns.deinit();

// Add source link-layer address option
const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
try ns.addSourceLinkLayer(mac);
```

#### Neighbor Advertisement

```zig
// Create neighbor advertisement
const flags = ndp.NeighborAdvertisement.Flags{
    .router = true,
    .solicited = true,
    .override = true,
};

var na = ndp.NeighborAdvertisement.init(allocator, target, flags);
defer na.deinit();

// Add target link-layer address
try na.addTargetLinkLayer(mac);
```

#### Neighbor Cache

```zig
// Initialize neighbor cache
var cache = ndp.NeighborCache.init(allocator);
defer cache.deinit();

// Add neighbor
const addr = try ipv6.Address.parse("2001:db8::1");
const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
try cache.add(addr, mac);

// Lookup neighbor
if (cache.lookup(addr)) |entry| {
    std.debug.print("Link-layer: {x:0>2}\n", .{entry.link_layer});
    std.debug.print("State: {}\n", .{entry.state});
}

// Update neighbor state
try cache.update(addr, mac, true); // is_router = true
```

#### Duplicate Address Detection (DAD)

```zig
// Initialize DAD
const addr = try ipv6.Address.parse("fe80::1");
var dad = ndp.DuplicateAddressDetection.init(addr);

// Send probes
while (dad.sendProbe()) {
    // Send neighbor solicitation for target address
    // Wait for response
}

// Check result
if (dad.state == .verified) {
    std.debug.print("Address is unique\n", .{});
} else if (dad.state == .duplicate) {
    std.debug.print("Address is duplicate!\n", .{});
}
```

#### Router Discovery

```zig
// Router Solicitation (from host)
var rs = ndp.RouterSolicitation.init(allocator);
defer rs.deinit();

try rs.addSourceLinkLayer(host_mac);

// Router Advertisement (from router)
const ra_flags = ndp.RouterAdvertisement.Flags{
    .managed_config = false,
    .other_config = false,
    .home_agent = false,
    .prf = 0, // Medium preference
};

var ra = ndp.RouterAdvertisement.init(allocator, ra_flags, 1800);
defer ra.deinit();

ra.cur_hop_limit = 64;
ra.reachable_time = 30000; // 30 seconds
ra.retrans_timer = 1000; // 1 second
```

### IPv6 Routing

#### Routing Table Management

```zig
const routing = @import("routing");

// Initialize routing table
var table = routing.RoutingTable.init(allocator);
defer table.deinit();

// Add route
const prefix = try ipv6.Prefix.init(
    try ipv6.Address.parse("2001:db8::"),
    32
);
const gateway = try ipv6.Address.parse("fe80::1");
const route = routing.Route.init(prefix, gateway, 1, .indirect, 10);
try table.addRoute(route);

// Add default route
try table.addDefaultRoute(
    try ipv6.Address.parse("fe80::1"),
    1, // interface index
    1  // metric
);

// Lookup route (longest prefix match)
const dest = try ipv6.Address.parse("2001:db8::1234");
if (table.lookup(dest)) |found_route| {
    std.debug.print("Next hop: {}\n", .{found_route.gateway.?});
    std.debug.print("Interface: {d}\n", .{found_route.interface_index});
    std.debug.print("Metric: {d}\n", .{found_route.metric});
}

// Remove route
_ = table.removeRoute(prefix);
```

#### Path MTU Discovery

```zig
// Initialize Path MTU cache
var mtu_cache = routing.PathMTUCache.init(allocator, 600); // 10 min timeout
defer mtu_cache.deinit();

// Update MTU for destination
const dest = try ipv6.Address.parse("2001:db8::1");
try mtu_cache.update(dest, 1280);

// Lookup MTU
if (mtu_cache.lookup(dest)) |mtu| {
    std.debug.print("Path MTU: {d}\n", .{mtu});
}
```

#### Fragment Header

```zig
// Create fragment header
const frag = routing.FragmentHeader.init(
    @intFromEnum(ipv6.Protocol.tcp),
    512,   // offset
    true,  // more fragments
    0x12345678 // identification
);

// Parse fragment info
const offset = frag.getOffset();
const has_more = frag.hasMoreFragments();
```

### DHCPv6

#### DHCPv6 Client

```zig
const dhcpv6 = @import("dhcpv6");

// Create DUID from MAC address
const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
const duid = try dhcpv6.Duid.fromLinkLayer(allocator, 1, &mac);

// Initialize DHCPv6 client
var client = dhcpv6.Client.init(allocator, duid);
defer client.deinit();

// Start address acquisition
client.solicit();

// Create IA_NA (Identity Association for Non-temporary Addresses)
var ia_na = dhcpv6.IA_NA.init(allocator, 1, 3600, 7200);
defer ia_na.deinit();

// Add address to IA_NA
const addr = try ipv6.Address.parse("2001:db8::1");
const ia_addr = dhcpv6.IA_Address.init(addr, 3600, 7200);
try ia_na.addAddress(ia_addr);

client.ia_na = ia_na;

// Request specific address
client.request();

// Renew lease
client.renew();

// Release address
client.release();
```

#### DHCPv6 Server

```zig
// Create server DUID
const server_mac = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
const server_duid = try dhcpv6.Duid.fromLinkLayer(allocator, 1, &server_mac);

// Initialize DHCPv6 server
var server = dhcpv6.Server.init(allocator, server_duid);
defer server.deinit();

// Add addresses to pool
try server.addAddressToPool(try ipv6.Address.parse("2001:db8::100"));
try server.addAddressToPool(try ipv6.Address.parse("2001:db8::101"));
try server.addAddressToPool(try ipv6.Address.parse("2001:db8::102"));

// Add prefixes for delegation
const prefix = try ipv6.Prefix.init(
    try ipv6.Address.parse("2001:db8:1::"),
    48
);
try server.addPrefixToPool(prefix);
```

#### Prefix Delegation

```zig
// Request prefix delegation
var ia_pd = dhcpv6.IA_PD.init(allocator, 2, 3600, 7200);
defer ia_pd.deinit();

const delegated_prefix = try ipv6.Prefix.init(
    try ipv6.Address.parse("2001:db8:1::"),
    48
);
const ia_prefix = dhcpv6.IA_Prefix.init(delegated_prefix, 3600, 7200);
try ia_pd.addPrefix(ia_prefix);
```

## Special IPv6 Addresses

### Well-Known Addresses

```zig
// Unspecified address (::)
const unspecified = ipv6.Address.unspecified;

// Loopback address (::1)
const loopback = ipv6.Address.loopback;

// All nodes multicast (ff02::1)
const all_nodes = ipv6.Address.all_nodes;

// All routers multicast (ff02::2)
const all_routers = ipv6.Address.all_routers;

// DHCPv6 multicast addresses
const dhcp_relay = dhcpv6.MulticastAddresses.all_dhcp_relay_agents_and_servers;
const dhcp_servers = dhcpv6.MulticastAddresses.all_dhcp_servers;
```

### Address Scopes

```zig
const addr = try ipv6.Address.parse("fe80::1");

// Link-local (fe80::/10)
if (addr.isLinkLocal()) {
    std.debug.print("Link-local\n", .{});
}

// Unique local (fc00::/7)
if (addr.isUniqueLocal()) {
    std.debug.print("Unique local\n", .{});
}

// Global unicast
if (addr.isGlobalUnicast()) {
    std.debug.print("Global unicast\n", .{});
}

// Multicast scope
if (addr.isMulticast()) {
    switch (addr.getMulticastScope().?) {
        .interface_local => std.debug.print("Interface-local\n", .{}),
        .link_local => std.debug.print("Link-local\n", .{}),
        .site_local => std.debug.print("Site-local\n", .{}),
        .organization_local => std.debug.print("Organization-local\n", .{}),
        .global => std.debug.print("Global\n", .{}),
        else => {},
    }
}
```

## IPv6 Header Construction

```zig
const src = try ipv6.Address.parse("2001:db8::1");
const dst = try ipv6.Address.parse("2001:db8::2");

var header = ipv6.Header.init(
    src,
    dst,
    @intFromEnum(ipv6.Protocol.tcp),
    1024 // payload length
);

// Set traffic class
header.setTrafficClass(0xA0);

// Set flow label
header.setFlowLabel(0x12345);

// Get values
const version = header.getVersion(); // 6
const tc = header.getTrafficClass();
const fl = header.getFlowLabel();

std.debug.print("IPv6 Version: {d}\n", .{version});
std.debug.print("Traffic Class: 0x{x}\n", .{tc});
std.debug.print("Flow Label: 0x{x}\n", .{fl});
```

## Network Configuration Example

Complete example of configuring IPv6 on an interface:

```zig
const std = @import("std");
const ipv6 = @import("ipv6");
const ndp = @import("ndp");
const routing = @import("routing");

pub fn configureIPv6Interface(allocator: std.mem.Allocator, interface_index: u32) !void {
    // 1. Generate link-local address
    const link_local = try ipv6.Address.parse("fe80::1");

    // 2. Perform Duplicate Address Detection
    var dad = ndp.DuplicateAddressDetection.init(link_local);
    while (dad.sendProbe()) {
        // Send neighbor solicitation
        // Wait for potential conflict
        std.time.sleep(1_000_000_000); // 1 second
    }

    if (dad.state == .duplicate) {
        return error.DuplicateAddress;
    }

    // 3. Initialize neighbor cache
    var cache = ndp.NeighborCache.init(allocator);
    defer cache.deinit();

    // 4. Initialize routing table
    var routes = routing.RoutingTable.init(allocator);
    defer routes.deinit();

    // 5. Add link-local route
    const ll_prefix = try ipv6.Prefix.init(
        try ipv6.Address.parse("fe80::"),
        64
    );
    const ll_route = routing.Route.init(
        ll_prefix,
        null, // No gateway for direct route
        interface_index,
        .direct,
        0
    );
    try routes.addRoute(ll_route);

    // 6. Send router solicitation
    var rs = ndp.RouterSolicitation.init(allocator);
    defer rs.deinit();

    const mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    try rs.addSourceLinkLayer(mac);

    // 7. Process router advertisements to get:
    //    - Default gateway
    //    - Global prefix
    //    - DNS servers
    //    - MTU

    std.debug.print("IPv6 configured on interface {d}\n", .{interface_index});
}
```

## Performance Considerations

### Address Lookup

- Neighbor cache uses hash map for O(1) lookups
- Routing table uses longest prefix matching with sorted routes
- Path MTU cache with configurable timeout

### Memory Usage

- IPv6 addresses: 16 bytes
- IPv6 headers: 40 bytes (vs 20 bytes for IPv4)
- Neighbor cache entries: ~64 bytes per entry
- Routes: ~80 bytes per route

### Optimization Tips

1. **Use link-local addresses** for local communication to avoid routing
2. **Enable Path MTU Discovery** to avoid fragmentation
3. **Cache neighbor entries** to reduce NDP traffic
4. **Aggregate routes** to minimize routing table size
5. **Use multicast** for efficient group communication

## Security Considerations

### Secure Neighbor Discovery (SEND)

While not yet implemented, consider these security best practices:

1. **Rate limit NDP messages** to prevent flooding
2. **Validate source addresses** in Neighbor Advertisements
3. **Implement RA Guard** on switch ports
4. **Monitor for duplicate addresses** (DAD attacks)
5. **Filter bogon addresses** at network edge

### DHCPv6 Security

1. **Authenticate DHCP messages** using DHCP authentication option
2. **Validate DHCPUIDs** to prevent spoofing
3. **Implement DHCPv6 snooping** on switches
4. **Rate limit DHCP traffic**
5. **Monitor for rogue DHCP servers**

## Testing

Run all IPv6 tests:

```bash
# Test all modules
zig build test --match ipv6

# Test specific modules
zig test packages/ipv6/src/ipv6.zig
zig test packages/ipv6/src/icmpv6.zig
zig test packages/ipv6/src/ndp.zig
zig test packages/ipv6/src/routing.zig
zig test packages/ipv6/src/dhcpv6.zig
```

## References

- [RFC 8200](https://www.rfc-editor.org/rfc/rfc8200.html) - Internet Protocol, Version 6 (IPv6) Specification
- [RFC 4443](https://www.rfc-editor.org/rfc/rfc4443.html) - Internet Control Message Protocol (ICMPv6) for IPv6
- [RFC 4861](https://www.rfc-editor.org/rfc/rfc4861.html) - Neighbor Discovery for IP version 6 (IPv6)
- [RFC 4862](https://www.rfc-editor.org/rfc/rfc4862.html) - IPv6 Stateless Address Autoconfiguration
- [RFC 8415](https://www.rfc-editor.org/rfc/rfc8415.html) - Dynamic Host Configuration Protocol for IPv6 (DHCPv6)
- [RFC 5952](https://www.rfc-editor.org/rfc/rfc5952.html) - A Recommendation for IPv6 Address Text Representation
- [RFC 4191](https://www.rfc-editor.org/rfc/rfc4191.html) - Default Router Preferences
- [RFC 3646](https://www.rfc-editor.org/rfc/rfc3646.html) - DNS Configuration options for DHCPv6

## License

This IPv6 implementation is part of Home OS and follows the project's licensing terms.
