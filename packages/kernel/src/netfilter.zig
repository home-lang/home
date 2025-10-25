// Home OS Kernel - Network Filtering (iptables-style)
// Basic firewall and packet filtering

const Basics = @import("basics");
const sync = @import("sync.zig");
const audit = @import("audit.zig");

// ============================================================================
// Packet Filter Rules
// ============================================================================

pub const Protocol = enum(u8) {
    TCP = 6,
    UDP = 17,
    ICMP = 1,
    ANY = 0,
};

pub const Action = enum(u8) {
    ACCEPT = 0,
    DROP = 1,
    REJECT = 2,
    LOG = 3,
};

pub const Direction = enum(u8) {
    INPUT = 0,   // Incoming packets
    OUTPUT = 1,  // Outgoing packets
    FORWARD = 2, // Forwarded packets
};

pub const FilterRule = struct {
    /// Source IP address (0 = any)
    src_ip: u32,
    /// Source IP mask
    src_mask: u32,
    /// Destination IP address (0 = any)
    dst_ip: u32,
    /// Destination IP mask
    dst_mask: u32,
    /// Source port (0 = any)
    src_port: u16,
    /// Destination port (0 = any)
    dst_port: u16,
    /// Protocol
    protocol: Protocol,
    /// Action to take
    action: Action,
    /// Traffic direction
    direction: Direction,
    /// Rule priority (lower = higher priority)
    priority: u32,
    /// Packet counter
    packet_count: u64,
    /// Byte counter
    byte_count: u64,

    pub fn init(action: Action, direction: Direction) FilterRule {
        return .{
            .src_ip = 0,
            .src_mask = 0,
            .dst_ip = 0,
            .dst_mask = 0,
            .src_port = 0,
            .dst_port = 0,
            .protocol = .ANY,
            .action = action,
            .direction = direction,
            .priority = 100,
            .packet_count = 0,
            .byte_count = 0,
        };
    }

    /// Check if rule matches packet
    pub fn matches(self: *const FilterRule, packet: *const Packet) bool {
        // Check direction
        if (self.direction != packet.direction) {
            return false;
        }

        // Check protocol
        if (self.protocol != .ANY and self.protocol != packet.protocol) {
            return false;
        }

        // Check source IP
        if (self.src_mask != 0) {
            if ((packet.src_ip & self.src_mask) != (self.src_ip & self.src_mask)) {
                return false;
            }
        }

        // Check destination IP
        if (self.dst_mask != 0) {
            if ((packet.dst_ip & self.dst_mask) != (self.dst_ip & self.dst_mask)) {
                return false;
            }
        }

        // Check source port
        if (self.src_port != 0 and self.src_port != packet.src_port) {
            return false;
        }

        // Check destination port
        if (self.dst_port != 0 and self.dst_port != packet.dst_port) {
            return false;
        }

        return true;
    }

    /// Update counters
    pub fn updateCounters(self: *FilterRule, packet_size: u64) void {
        self.packet_count += 1;
        self.byte_count += packet_size;
    }
};

// ============================================================================
// Packet Structure
// ============================================================================

pub const Packet = struct {
    src_ip: u32,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
    protocol: Protocol,
    direction: Direction,
    size: u64,
    data: []const u8,

    pub fn init(src_ip: u32, dst_ip: u32, protocol: Protocol, direction: Direction, data: []const u8) Packet {
        return .{
            .src_ip = src_ip,
            .dst_ip = dst_ip,
            .src_port = 0,
            .dst_port = 0,
            .protocol = protocol,
            .direction = direction,
            .size = data.len,
            .data = data,
        };
    }
};

// ============================================================================
// Filter Chain
// ============================================================================

const MAX_RULES = 256;

pub const FilterChain = struct {
    rules: [MAX_RULES]?FilterRule,
    count: usize,
    default_action: Action,
    lock: sync.RwLock,

    pub fn init(default_action: Action) FilterChain {
        return .{
            .rules = [_]?FilterRule{null} ** MAX_RULES,
            .count = 0,
            .default_action = default_action,
            .lock = sync.RwLock.init(),
        };
    }

    /// Add rule to chain
    pub fn addRule(self: *FilterChain, rule: FilterRule) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.count >= MAX_RULES) {
            return error.TooManyRules;
        }

        // Insert rule in priority order
        var insert_idx: usize = 0;
        for (self.rules, 0..) |maybe_rule, i| {
            if (maybe_rule) |existing_rule| {
                if (rule.priority < existing_rule.priority) {
                    insert_idx = i;
                    break;
                }
            } else {
                insert_idx = i;
                break;
            }
        }

        // Shift rules if needed
        if (self.rules[insert_idx] != null) {
            var i: usize = self.count;
            while (i > insert_idx) : (i -= 1) {
                self.rules[i] = self.rules[i - 1];
            }
        }

        self.rules[insert_idx] = rule;
        self.count += 1;
    }

    /// Remove rule at index
    pub fn removeRule(self: *FilterChain, index: usize) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (index >= self.count) {
            return error.InvalidIndex;
        }

        // Shift rules down
        var i: usize = index;
        while (i < self.count - 1) : (i += 1) {
            self.rules[i] = self.rules[i + 1];
        }

        self.rules[self.count - 1] = null;
        self.count -= 1;
    }

    /// Filter a packet through the chain
    pub fn filterPacket(self: *FilterChain, packet: *const Packet) Action {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        // Check each rule in order
        for (&self.rules) |*maybe_rule| {
            if (maybe_rule.*) |*rule| {
                if (rule.matches(packet)) {
                    rule.updateCounters(packet.size);

                    // Log if needed
                    if (rule.action == .LOG) {
                        logPacket(packet, rule);
                        continue; // Continue to next rule
                    }

                    return rule.action;
                }
            }
        }

        // No match, use default action
        return self.default_action;
    }

    /// Get statistics
    pub fn getStats(self: *FilterChain, out: []FilterRule) usize {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        var count: usize = 0;
        for (self.rules) |maybe_rule| {
            if (maybe_rule) |rule| {
                if (count < out.len) {
                    out[count] = rule;
                    count += 1;
                }
            }
        }

        return count;
    }
};

fn logPacket(packet: *const Packet, rule: *const FilterRule) void {
    var buf: [256]u8 = undefined;
    const msg = Basics.fmt.bufPrint(&buf, "NETFILTER: {} packet from {}:{} to {}:{}", .{
        @tagName(packet.protocol),
        packet.src_ip,
        packet.src_port,
        packet.dst_ip,
        packet.dst_port,
    }) catch "netfilter_log";

    _ = rule;
    audit.logSecurityViolation(msg);
}

// ============================================================================
// Global Filter Tables
// ============================================================================

var input_chain: FilterChain = undefined;
var output_chain: FilterChain = undefined;
var forward_chain: FilterChain = undefined;
var filter_initialized = false;
var filter_enabled = false;

/// Initialize network filtering
pub fn init() void {
    if (filter_initialized) return;

    // Default policy: ACCEPT (permissive by default)
    input_chain = FilterChain.init(.ACCEPT);
    output_chain = FilterChain.init(.ACCEPT);
    forward_chain = FilterChain.init(.ACCEPT);

    filter_initialized = true;
}

/// Enable filtering
pub fn enable() void {
    if (!filter_initialized) init();
    filter_enabled = true;
}

/// Disable filtering
pub fn disable() void {
    filter_enabled = false;
}

/// Filter incoming packet
pub fn filterInput(packet: *const Packet) Action {
    if (!filter_enabled) return .ACCEPT;
    return input_chain.filterPacket(packet);
}

/// Filter outgoing packet
pub fn filterOutput(packet: *const Packet) Action {
    if (!filter_enabled) return .ACCEPT;
    return output_chain.filterPacket(packet);
}

/// Filter forwarded packet
pub fn filterForward(packet: *const Packet) Action {
    if (!filter_enabled) return .ACCEPT;
    return forward_chain.filterPacket(packet);
}

/// Add rule to input chain
pub fn addInputRule(rule: FilterRule) !void {
    if (!filter_initialized) init();
    try input_chain.addRule(rule);
}

/// Add rule to output chain
pub fn addOutputRule(rule: FilterRule) !void {
    if (!filter_initialized) init();
    try output_chain.addRule(rule);
}

// ============================================================================
// Common Rule Presets
// ============================================================================

/// Block all incoming connections (default deny)
pub fn setDefaultDeny() !void {
    if (!filter_initialized) init();

    input_chain.default_action = .DROP;
    forward_chain.default_action = .DROP;
    // Keep OUTPUT as ACCEPT to allow outgoing
}

/// Allow loopback traffic
pub fn allowLoopback() !void {
    var rule = FilterRule.init(.ACCEPT, .INPUT);
    rule.src_ip = 0x7F000001; // 127.0.0.1
    rule.src_mask = 0xFF000000; // 127.0.0.0/8
    rule.priority = 1; // High priority

    try addInputRule(rule);

    var out_rule = FilterRule.init(.ACCEPT, .OUTPUT);
    out_rule.dst_ip = 0x7F000001;
    out_rule.dst_mask = 0xFF000000;
    out_rule.priority = 1;

    try addOutputRule(out_rule);
}

/// Allow established connections (stateful-like)
pub fn allowEstablished() !void {
    // In a full implementation, this would check connection state
    // For now, just allow common response ports

    var rule = FilterRule.init(.ACCEPT, .INPUT);
    rule.src_port = 80; // HTTP responses
    rule.protocol = .TCP;
    rule.priority = 10;

    try addInputRule(rule);
}

/// Block port
pub fn blockPort(port: u16, protocol: Protocol, direction: Direction) !void {
    var rule = FilterRule.init(.DROP, direction);
    rule.dst_port = port;
    rule.protocol = protocol;
    rule.priority = 50;

    if (direction == .INPUT) {
        try addInputRule(rule);
    } else {
        try addOutputRule(rule);
    }
}

/// Allow port
pub fn allowPort(port: u16, protocol: Protocol, direction: Direction) !void {
    var rule = FilterRule.init(.ACCEPT, direction);
    rule.dst_port = port;
    rule.protocol = protocol;
    rule.priority = 50;

    if (direction == .INPUT) {
        try addInputRule(rule);
    } else {
        try addOutputRule(rule);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "filter rule matching" {
    var rule = FilterRule.init(.DROP, .INPUT);
    rule.dst_port = 22; // SSH
    rule.protocol = .TCP;

    var packet = Packet.init(0xC0A80101, 0xC0A80102, .TCP, .INPUT, "test");
    packet.dst_port = 22;

    try Basics.testing.expect(rule.matches(&packet));

    packet.dst_port = 80;
    try Basics.testing.expect(!rule.matches(&packet));
}

test "filter chain basic" {
    var chain = FilterChain.init(.ACCEPT);

    var block_ssh = FilterRule.init(.DROP, .INPUT);
    block_ssh.dst_port = 22;
    block_ssh.protocol = .TCP;

    try chain.addRule(block_ssh);

    var packet_ssh = Packet.init(0xC0A80101, 0xC0A80102, .TCP, .INPUT, "test");
    packet_ssh.dst_port = 22;

    const action = chain.filterPacket(&packet_ssh);
    try Basics.testing.expect(action == .DROP);

    var packet_http = Packet.init(0xC0A80101, 0xC0A80102, .TCP, .INPUT, "test");
    packet_http.dst_port = 80;

    const action2 = chain.filterPacket(&packet_http);
    try Basics.testing.expect(action2 == .ACCEPT);
}

test "rule priority ordering" {
    var chain = FilterChain.init(.DROP);

    var low_prio = FilterRule.init(.DROP, .INPUT);
    low_prio.priority = 100;

    var high_prio = FilterRule.init(.ACCEPT, .INPUT);
    high_prio.priority = 1;

    try chain.addRule(low_prio);
    try chain.addRule(high_prio);

    // High priority rule should be first
    try Basics.testing.expect(chain.rules[0].?.priority == 1);
    try Basics.testing.expect(chain.rules[1].?.priority == 100);
}

test "IP address matching" {
    var rule = FilterRule.init(.DROP, .INPUT);
    rule.src_ip = 0xC0A80000; // 192.168.0.0
    rule.src_mask = 0xFFFF0000; // /16

    var packet_match = Packet.init(0xC0A80105, 0xC0A80102, .TCP, .INPUT, "test");
    try Basics.testing.expect(rule.matches(&packet_match));

    var packet_nomatch = Packet.init(0xC0A90105, 0xC0A80102, .TCP, .INPUT, "test");
    try Basics.testing.expect(!rule.matches(&packet_nomatch));
}

test "counter updates" {
    var rule = FilterRule.init(.ACCEPT, .INPUT);

    try Basics.testing.expect(rule.packet_count == 0);
    try Basics.testing.expect(rule.byte_count == 0);

    rule.updateCounters(1500);

    try Basics.testing.expect(rule.packet_count == 1);
    try Basics.testing.expect(rule.byte_count == 1500);
}
