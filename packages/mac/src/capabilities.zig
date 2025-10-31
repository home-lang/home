// Capabilities - Linux-style capability management

const std = @import("std");

/// POSIX capabilities (similar to Linux capabilities)
pub const Capability = enum(u32) {
    // File capabilities
    CAP_CHOWN = 0, // Change file ownership
    CAP_DAC_OVERRIDE = 1, // Bypass file read/write/execute checks
    CAP_DAC_READ_SEARCH = 2, // Bypass file read and directory search checks
    CAP_FOWNER = 3, // Bypass permission checks on operations that require file owner
    CAP_FSETID = 4, // Don't clear set-user-ID and set-group-ID

    // Process capabilities
    CAP_KILL = 5, // Bypass permission checks for sending signals
    CAP_SETGID = 6, // Make arbitrary manipulations of process GIDs
    CAP_SETUID = 7, // Make arbitrary manipulations of process UIDs
    CAP_SETPCAP = 8, // Transfer capabilities

    // Network capabilities
    CAP_NET_BIND_SERVICE = 10, // Bind to privileged ports (<1024)
    CAP_NET_BROADCAST = 11, // Allow broadcasting
    CAP_NET_ADMIN = 12, // Network administration
    CAP_NET_RAW = 13, // Use RAW and PACKET sockets

    // System capabilities
    CAP_SYS_CHROOT = 18, // Use chroot()
    CAP_SYS_PTRACE = 19, // Trace arbitrary processes
    CAP_SYS_ADMIN = 21, // System administration
    CAP_SYS_BOOT = 22, // Reboot system
    CAP_SYS_TIME = 25, // Set system clock
    CAP_SYS_MODULE = 16, // Load/unload kernel modules
    CAP_SYS_RAWIO = 17, // Perform I/O port operations

    // Audit capabilities
    CAP_AUDIT_CONTROL = 30, // Control kernel auditing
    CAP_AUDIT_WRITE = 29, // Write to kernel audit log

    pub fn toString(self: Capability) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(name: []const u8) ?Capability {
        return std.meta.stringToEnum(Capability, name);
    }
};

/// Capability set
pub const CapabilitySet = struct {
    caps: std.AutoHashMap(u32, void),

    pub fn init(allocator: std.mem.Allocator) CapabilitySet {
        return .{
            .caps = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    pub fn deinit(self: *CapabilitySet) void {
        self.caps.deinit();
    }

    /// Add capability to set
    pub fn add(self: *CapabilitySet, cap: Capability) !void {
        try self.caps.put(@intFromEnum(cap), {});
    }

    /// Remove capability from set
    pub fn remove(self: *CapabilitySet, cap: Capability) void {
        _ = self.caps.remove(@intFromEnum(cap));
    }

    /// Check if capability is in set
    pub fn has(self: *CapabilitySet, cap: Capability) bool {
        return self.caps.contains(@intFromEnum(cap));
    }

    /// Clear all capabilities
    pub fn clear(self: *CapabilitySet) void {
        self.caps.clearRetainingCapacity();
    }

    /// Check if this set has all capabilities from another set
    pub fn hasAll(self: *CapabilitySet, other: *CapabilitySet) bool {
        var iter = other.caps.keyIterator();
        while (iter.next()) |cap| {
            if (!self.caps.contains(cap.*)) return false;
        }
        return true;
    }

    /// Add all capabilities from another set
    pub fn merge(self: *CapabilitySet, other: *CapabilitySet) !void {
        var iter = other.caps.keyIterator();
        while (iter.next()) |cap| {
            try self.caps.put(cap.*, {});
        }
    }

    /// Get capability count
    pub fn count(self: *CapabilitySet) usize {
        return self.caps.count();
    }
};

/// Process capability sets (effective, permitted, inheritable)
pub const ProcessCapabilities = struct {
    effective: CapabilitySet, // Currently enabled capabilities
    permitted: CapabilitySet, // Maximum capabilities that can be enabled
    inheritable: CapabilitySet, // Capabilities preserved across execve()

    pub fn init(allocator: std.mem.Allocator) ProcessCapabilities {
        return .{
            .effective = CapabilitySet.init(allocator),
            .permitted = CapabilitySet.init(allocator),
            .inheritable = CapabilitySet.init(allocator),
        };
    }

    pub fn deinit(self: *ProcessCapabilities) void {
        self.effective.deinit();
        self.permitted.deinit();
        self.inheritable.deinit();
    }

    /// Make capability effective (must be in permitted set)
    pub fn makeEffective(self: *ProcessCapabilities, cap: Capability) !void {
        if (!self.permitted.has(cap)) {
            return error.CapabilityNotPermitted;
        }
        try self.effective.add(cap);
    }

    /// Drop capability from effective set
    pub fn dropEffective(self: *ProcessCapabilities, cap: Capability) void {
        self.effective.remove(cap);
    }

    /// Check if capability is effective
    pub fn isEffective(self: *ProcessCapabilities, cap: Capability) bool {
        return self.effective.has(cap);
    }

    /// Grant full capabilities (root-like)
    pub fn grantAll(self: *ProcessCapabilities) !void {
        inline for (@typeInfo(Capability).Enum.fields) |field| {
            const cap: Capability = @enumFromInt(field.value);
            try self.permitted.add(cap);
            try self.effective.add(cap);
        }
    }

    /// Drop all capabilities
    pub fn dropAll(self: *ProcessCapabilities) void {
        self.effective.clear();
        self.permitted.clear();
        self.inheritable.clear();
    }
};

/// Pre-defined capability sets
pub const CapabilitySets = struct {
    /// Root capabilities (all capabilities)
    pub fn root(allocator: std.mem.Allocator) !CapabilitySet {
        var set = CapabilitySet.init(allocator);
        inline for (@typeInfo(Capability).Enum.fields) |field| {
            try set.add(@enumFromInt(field.value));
        }
        return set;
    }

    /// Network service capabilities (bind privileged ports, network admin)
    pub fn networkService(allocator: std.mem.Allocator) !CapabilitySet {
        var set = CapabilitySet.init(allocator);
        try set.add(.CAP_NET_BIND_SERVICE);
        try set.add(.CAP_NET_ADMIN);
        return set;
    }

    /// File management capabilities
    pub fn fileManager(allocator: std.mem.Allocator) !CapabilitySet {
        var set = CapabilitySet.init(allocator);
        try set.add(.CAP_CHOWN);
        try set.add(.CAP_DAC_OVERRIDE);
        try set.add(.CAP_FOWNER);
        return set;
    }

    /// No capabilities (unprivileged)
    pub fn none(allocator: std.mem.Allocator) CapabilitySet {
        return CapabilitySet.init(allocator);
    }
};

/// Check if operation requires capability
pub fn requiresCapability(operation: []const u8) ?Capability {
    const map = std.ComptimeStringMap(Capability, .{
        .{ "chown", .CAP_CHOWN },
        .{ "chmod", .CAP_FOWNER },
        .{ "kill", .CAP_KILL },
        .{ "setuid", .CAP_SETUID },
        .{ "setgid", .CAP_SETGID },
        .{ "bind_privileged", .CAP_NET_BIND_SERVICE },
        .{ "ptrace", .CAP_SYS_PTRACE },
        .{ "reboot", .CAP_SYS_BOOT },
        .{ "chroot", .CAP_SYS_CHROOT },
    });

    return map.get(operation);
}

test "capability set" {
    const testing = std.testing;

    var set = CapabilitySet.init(testing.allocator);
    defer set.deinit();

    try set.add(.CAP_CHOWN);
    try set.add(.CAP_KILL);

    try testing.expect(set.has(.CAP_CHOWN));
    try testing.expect(set.has(.CAP_KILL));
    try testing.expect(!set.has(.CAP_NET_ADMIN));

    try testing.expectEqual(@as(usize, 2), set.count());
}

test "process capabilities" {
    const testing = std.testing;

    var caps = ProcessCapabilities.init(testing.allocator);
    defer caps.deinit();

    // Grant CAP_CHOWN to permitted
    try caps.permitted.add(.CAP_CHOWN);

    // Make it effective
    try caps.makeEffective(.CAP_CHOWN);

    try testing.expect(caps.isEffective(.CAP_CHOWN));

    // Try to make non-permitted capability effective (should fail)
    const result = caps.makeEffective(.CAP_KILL);
    try testing.expectError(error.CapabilityNotPermitted, result);
}

test "capability sets presets" {
    const testing = std.testing;

    var net_caps = try CapabilitySets.networkService(testing.allocator);
    defer net_caps.deinit();

    try testing.expect(net_caps.has(.CAP_NET_BIND_SERVICE));
    try testing.expect(net_caps.has(.CAP_NET_ADMIN));
}
