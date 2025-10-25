// Home OS Kernel - POSIX Capabilities System
// Fine-grained privilege management beyond traditional root/non-root

const Basics = @import("basics");
const process = @import("process.zig");

// ============================================================================
// Capability Definitions (POSIX.1e)
// ============================================================================

/// POSIX Capabilities - Fine-grained privileges
pub const Capability = enum(u6) {
    /// Override file read/write/execute permission checks
    CAP_DAC_OVERRIDE = 0,
    /// Override file ownership checks
    CAP_DAC_READ_SEARCH = 1,
    /// Override file owner checks (chown, etc.)
    CAP_FOWNER = 2,
    /// Override file setuid/setgid checks
    CAP_FSETID = 3,
    /// Send signals to any process
    CAP_KILL = 4,
    /// Set GID of arbitrary processes
    CAP_SETGID = 5,
    /// Set UID of arbitrary processes
    CAP_SETUID = 6,
    /// Transfer any capability
    CAP_SETPCAP = 7,
    /// Bind to privileged ports (< 1024)
    CAP_NET_BIND_SERVICE = 8,
    /// Configure network (interfaces, routing, etc.)
    CAP_NET_ADMIN = 9,
    /// Use raw sockets
    CAP_NET_RAW = 10,
    /// Lock memory (mlock, mlockall)
    CAP_IPC_LOCK = 11,
    /// Override IPC ownership checks
    CAP_IPC_OWNER = 12,
    /// Load/unload kernel modules
    CAP_SYS_MODULE = 13,
    /// Use raw I/O (iopl, ioperm)
    CAP_SYS_RAWIO = 14,
    /// Use chroot()
    CAP_SYS_CHROOT = 15,
    /// Trace arbitrary processes (ptrace)
    CAP_SYS_PTRACE = 16,
    /// Override resource limits
    CAP_SYS_RESOURCE = 17,
    /// Set system time
    CAP_SYS_TIME = 18,
    /// Configure TTY
    CAP_SYS_TTY_CONFIG = 19,
    /// Create device files (mknod)
    CAP_MKNOD = 20,
    /// Change file timestamps
    CAP_FSETFCAP = 21,
    /// Set file capabilities
    CAP_SETFCAP = 22,
    /// Override mandatory access control
    CAP_MAC_OVERRIDE = 23,
    /// Configure MAC policy
    CAP_MAC_ADMIN = 24,
    /// Configure system logging
    CAP_SYSLOG = 25,
    /// Wake the system
    CAP_WAKE_ALARM = 26,
    /// Override audit logging restrictions
    CAP_AUDIT_CONTROL = 27,
    /// Write audit log
    CAP_AUDIT_WRITE = 28,
    /// Use reboot() syscall
    CAP_SYS_BOOT = 29,
    /// Set process nice value
    CAP_SYS_NICE = 30,
    /// Perform system administration tasks
    CAP_SYS_ADMIN = 31,
};

/// Total number of capabilities
pub const MAX_CAPS = 32;

// ============================================================================
// Capability Sets
// ============================================================================

/// Set of capabilities represented as a bitmap
pub const CapabilitySet = packed struct(u64) {
    dac_override: bool = false,
    dac_read_search: bool = false,
    fowner: bool = false,
    fsetid: bool = false,
    kill: bool = false,
    setgid: bool = false,
    setuid: bool = false,
    setpcap: bool = false,
    net_bind_service: bool = false,
    net_admin: bool = false,
    net_raw: bool = false,
    ipc_lock: bool = false,
    ipc_owner: bool = false,
    sys_module: bool = false,
    sys_rawio: bool = false,
    sys_chroot: bool = false,
    sys_ptrace: bool = false,
    sys_resource: bool = false,
    sys_time: bool = false,
    sys_tty_config: bool = false,
    mknod: bool = false,
    fsetfcap: bool = false,
    setfcap: bool = false,
    mac_override: bool = false,
    mac_admin: bool = false,
    syslog: bool = false,
    wake_alarm: bool = false,
    audit_control: bool = false,
    audit_write: bool = false,
    sys_boot: bool = false,
    sys_nice: bool = false,
    sys_admin: bool = false,
    _reserved: u32 = 0,

    /// Empty capability set (no capabilities)
    pub fn none() CapabilitySet {
        return .{};
    }

    /// Full capability set (all capabilities - for root)
    pub fn all() CapabilitySet {
        return @bitCast(@as(u64, 0xFFFFFFFF)); // Lower 32 bits are capabilities
    }

    /// Check if a capability is set
    pub fn has(self: CapabilitySet, cap: Capability) bool {
        const bit = @intFromEnum(cap);
        const value: u64 = @bitCast(self);
        return (value & (@as(u64, 1) << @intCast(bit))) != 0;
    }

    /// Add a capability
    pub fn add(self: *CapabilitySet, cap: Capability) void {
        const bit = @intFromEnum(cap);
        var value: u64 = @bitCast(self.*);
        value |= @as(u64, 1) << @intCast(bit);
        self.* = @bitCast(value);
    }

    /// Remove a capability
    pub fn remove(self: *CapabilitySet, cap: Capability) void {
        const bit = @intFromEnum(cap);
        var value: u64 = @bitCast(self.*);
        value &= ~(@as(u64, 1) << @intCast(bit));
        self.* = @bitCast(value);
    }

    /// Check if set contains all capabilities from another set
    pub fn contains(self: CapabilitySet, other: CapabilitySet) bool {
        const self_val: u64 = @bitCast(self);
        const other_val: u64 = @bitCast(other);
        return (self_val & other_val) == other_val;
    }

    /// Merge two capability sets
    pub fn merge(self: *CapabilitySet, other: CapabilitySet) void {
        var self_val: u64 = @bitCast(self.*);
        const other_val: u64 = @bitCast(other);
        self_val |= other_val;
        self.* = @bitCast(self_val);
    }
};

// ============================================================================
// Capability Checking Functions
// ============================================================================

/// Check if current process has a specific capability
pub fn hasCapability(cap: Capability) bool {
    const current = process.getCurrentProcess() orelse return false;

    // Root always has all capabilities
    if (current.euid == 0) return true;

    // Check capability set
    const caps: CapabilitySet = @bitCast(current.capabilities);
    return caps.has(cap);
}

/// Require a specific capability (error if not present)
pub fn requireCapability(cap: Capability) !void {
    if (!hasCapability(cap)) {
        return error.CapabilityRequired;
    }
}

/// Check if process has any of the given capabilities
pub fn hasAnyCapability(caps: []const Capability) bool {
    for (caps) |cap| {
        if (hasCapability(cap)) return true;
    }
    return false;
}

/// Check if process has all of the given capabilities
pub fn hasAllCapabilities(caps: []const Capability) bool {
    for (caps) |cap| {
        if (!hasCapability(cap)) return false;
    }
    return true;
}

// ============================================================================
// Helper Functions for Common Privilege Checks
// ============================================================================

/// Check if process can override file permissions
pub fn canOverrideFilePerms() bool {
    return hasCapability(.CAP_DAC_OVERRIDE) or hasCapability(.CAP_FOWNER);
}

/// Check if process can change ownership
pub fn canChangeOwnership() bool {
    return hasCapability(.CAP_FOWNER) or hasCapability(.CAP_CHOWN);
}

/// Check if process can send signal to any process
pub fn canKillAnyProcess() bool {
    return hasCapability(.CAP_KILL);
}

/// Check if process can bind to privileged port
pub fn canBindPrivilegedPort(port: u16) bool {
    if (port >= 1024) return true; // Non-privileged ports
    return hasCapability(.CAP_NET_BIND_SERVICE);
}

/// Check if process can perform network administration
pub fn canAdminNetwork() bool {
    return hasCapability(.CAP_NET_ADMIN);
}

/// Check if process can use raw sockets
pub fn canUseRawSockets() bool {
    return hasCapability(.CAP_NET_RAW);
}

/// Check if process can load kernel modules
pub fn canLoadModules() bool {
    return hasCapability(.CAP_SYS_MODULE);
}

/// Check if process can perform system administration
pub fn canAdminSystem() bool {
    return hasCapability(.CAP_SYS_ADMIN);
}

/// Check if process can trace other processes
pub fn canTrace() bool {
    return hasCapability(.CAP_SYS_PTRACE);
}

/// Check if process can set system time
pub fn canSetTime() bool {
    return hasCapability(.CAP_SYS_TIME);
}

/// Check if process can reboot system
pub fn canReboot() bool {
    return hasCapability(.CAP_SYS_BOOT);
}

/// Check if process can change UIDs
pub fn canSetUid() bool {
    return hasCapability(.CAP_SETUID);
}

/// Check if process can change GIDs
pub fn canSetGid() bool {
    return hasCapability(.CAP_SETGID);
}

// ============================================================================
// Capability Management Syscalls (to be integrated)
// ============================================================================

/// Drop a capability from current process
pub fn dropCapability(cap: Capability) !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    current.lock.acquire();
    defer current.lock.release();

    var caps: CapabilitySet = @bitCast(current.capabilities);
    caps.remove(cap);
    current.capabilities = @bitCast(caps);
}

/// Add a capability to current process (requires CAP_SETPCAP)
pub fn addCapability(cap: Capability) !void {
    try requireCapability(.CAP_SETPCAP);

    const current = process.getCurrentProcess() orelse return error.NoProcess;

    current.lock.acquire();
    defer current.lock.release();

    var caps: CapabilitySet = @bitCast(current.capabilities);
    caps.add(cap);
    current.capabilities = @bitCast(caps);
}

/// Clear all capabilities
pub fn clearCapabilities() !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    current.lock.acquire();
    defer current.lock.release();

    current.capabilities = @bitCast(CapabilitySet.none());
}

// ============================================================================
// Tests
// ============================================================================

test "capability set operations" {
    var caps = CapabilitySet.none();

    // Initially empty
    try Basics.testing.expect(!caps.has(.CAP_NET_ADMIN));

    // Add capability
    caps.add(.CAP_NET_ADMIN);
    try Basics.testing.expect(caps.has(.CAP_NET_ADMIN));

    // Remove capability
    caps.remove(.CAP_NET_ADMIN);
    try Basics.testing.expect(!caps.has(.CAP_NET_ADMIN));
}

test "capability set merge" {
    var caps1 = CapabilitySet.none();
    caps1.add(.CAP_NET_ADMIN);

    var caps2 = CapabilitySet.none();
    caps2.add(.CAP_SYS_ADMIN);

    caps1.merge(caps2);

    try Basics.testing.expect(caps1.has(.CAP_NET_ADMIN));
    try Basics.testing.expect(caps1.has(.CAP_SYS_ADMIN));
}

test "all capabilities set" {
    const caps = CapabilitySet.all();

    try Basics.testing.expect(caps.has(.CAP_NET_ADMIN));
    try Basics.testing.expect(caps.has(.CAP_SYS_ADMIN));
    try Basics.testing.expect(caps.has(.CAP_KILL));
}
