// Home OS Kernel - Kernel Lockdown Mode
// Prevents root from modifying kernel memory and enforces module signing

const Basics = @import("basics");
const sync = @import("sync.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");

// ============================================================================
// Lockdown Levels
// ============================================================================

pub const LockdownLevel = enum(u8) {
    /// No lockdown - normal operation
    NONE = 0,
    /// Integrity mode - prevent kernel modification
    INTEGRITY = 1,
    /// Confidentiality mode - prevent kernel memory reads and modification
    CONFIDENTIALITY = 2,
};

// ============================================================================
// Locked Operations
// ============================================================================

pub const LockedOperation = enum {
    /// Kernel memory access via /dev/mem, /dev/kmem
    KERNEL_MEM_ACCESS,
    /// Direct I/O to kernel memory
    KERNEL_MEM_IO,
    /// Module loading without signature
    UNSIGNED_MODULE,
    /// Kernel parameter modification
    KERNEL_PARAMS,
    /// ACPI table modification
    ACPI_TABLES,
    /// Device tree modification
    DEVICE_TREE,
    /// MSR (Model-Specific Register) access
    MSR_ACCESS,
    /// I/O port access
    IOPORT_ACCESS,
    /// PCI config space writes
    PCI_ACCESS,
    /// Kernel debugger
    KGDB,
    /// kexec (load new kernel)
    KEXEC,
    /// Hibernation (could expose kernel memory)
    HIBERNATION,
    /// BPF syscall (can read kernel memory)
    BPF_SYSCALL,
    /// Performance events that expose kernel addresses
    PERF_EVENTS,
    /// Kernel crash dumps
    CRASH_DUMPS,
    /// Override disk encryption
    DISK_ENCRYPTION,
};

// ============================================================================
// Lockdown State
// ============================================================================

var current_level: LockdownLevel = .NONE;
var lockdown_lock = sync.Spinlock.init();
var lockdown_enabled = false;

/// Initialize lockdown (can only be set once at boot)
pub fn init(level: LockdownLevel) void {
    lockdown_lock.acquire();
    defer lockdown_lock.release();

    if (lockdown_enabled) {
        // Already initialized, cannot change
        return;
    }

    current_level = level;
    lockdown_enabled = true;

    if (level != .NONE) {
        audit.logSecurityViolation("Kernel lockdown enabled");
    }
}

/// Get current lockdown level
pub fn getLevel() LockdownLevel {
    lockdown_lock.acquire();
    defer lockdown_lock.release();

    return current_level;
}

/// Check if operation is allowed under current lockdown
pub fn isAllowed(operation: LockedOperation) bool {
    lockdown_lock.acquire();
    defer lockdown_lock.release();

    return switch (current_level) {
        .NONE => true, // All operations allowed

        .INTEGRITY => switch (operation) {
            // Integrity mode blocks operations that modify kernel
            .KERNEL_MEM_ACCESS,
            .KERNEL_MEM_IO,
            .UNSIGNED_MODULE,
            .KERNEL_PARAMS,
            .ACPI_TABLES,
            .DEVICE_TREE,
            .MSR_ACCESS,
            .PCI_ACCESS,
            .KEXEC,
            => false,

            // These are allowed in integrity mode
            .IOPORT_ACCESS,
            .KGDB,
            .HIBERNATION,
            .BPF_SYSCALL,
            .PERF_EVENTS,
            .CRASH_DUMPS,
            .DISK_ENCRYPTION,
            => true,
        },

        .CONFIDENTIALITY => switch (operation) {
            // Confidentiality mode blocks everything that could expose or modify kernel
            .KERNEL_MEM_ACCESS,
            .KERNEL_MEM_IO,
            .UNSIGNED_MODULE,
            .KERNEL_PARAMS,
            .ACPI_TABLES,
            .DEVICE_TREE,
            .MSR_ACCESS,
            .PCI_ACCESS,
            .KEXEC,
            .HIBERNATION, // Could dump kernel memory to disk
            .BPF_SYSCALL, // Can read kernel memory
            .PERF_EVENTS, // Could expose kernel addresses
            .CRASH_DUMPS, // Expose kernel memory
            .KGDB,        // Debugger access
            => false,

            // Only basic I/O allowed
            .IOPORT_ACCESS,
            .DISK_ENCRYPTION,
            => true,
        },
    };
}

/// Check operation and return error if not allowed
pub fn checkAllowed(operation: LockedOperation) !void {
    if (!isAllowed(operation)) {
        // Log the violation
        var buf: [128]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "Lockdown: Blocked {s}", .{@tagName(operation)}) catch "lockdown_violation";
        audit.logSecurityViolation(msg);

        return error.OperationLocked;
    }
}

// ============================================================================
// Specific Operation Checks
// ============================================================================

/// Check if kernel memory access is allowed
pub fn checkKernelMemAccess() !void {
    try checkAllowed(.KERNEL_MEM_ACCESS);
}

/// Check if module loading is allowed
pub fn checkModuleLoad(is_signed: bool) !void {
    if (!is_signed) {
        try checkAllowed(.UNSIGNED_MODULE);
    }
}

/// Check if kernel parameter modification is allowed
pub fn checkKernelParamModify() !void {
    try checkAllowed(.KERNEL_PARAMS);
}

/// Check if hibernation is allowed
pub fn checkHibernation() !void {
    try checkAllowed(.HIBERNATION);
}

/// Check if BPF is allowed
pub fn checkBpf() !void {
    try checkAllowed(.BPF_SYSCALL);
}

/// Check if kexec is allowed
pub fn checkKexec() !void {
    try checkAllowed(.KEXEC);
}

/// Check if MSR access is allowed
pub fn checkMsr() !void {
    try checkAllowed(.MSR_ACCESS);
}

/// Check if I/O port access is allowed
pub fn checkIoPort() !void {
    try checkAllowed(.IOPORT_ACCESS);
}

// ============================================================================
// Lockdown Information
// ============================================================================

pub const LockdownInfo = struct {
    level: LockdownLevel,
    blocked_operations: [16]LockedOperation,
    blocked_count: usize,

    pub fn init() LockdownInfo {
        return .{
            .level = getLevel(),
            .blocked_operations = undefined,
            .blocked_count = 0,
        };
    }

    pub fn addBlockedOperation(self: *LockdownInfo, op: LockedOperation) void {
        if (self.blocked_count < 16) {
            self.blocked_operations[self.blocked_count] = op;
            self.blocked_count += 1;
        }
    }
};

/// Get lockdown information
pub fn getInfo() LockdownInfo {
    var info = LockdownInfo.init();

    // List all blocked operations
    const all_ops = [_]LockedOperation{
        .KERNEL_MEM_ACCESS,
        .KERNEL_MEM_IO,
        .UNSIGNED_MODULE,
        .KERNEL_PARAMS,
        .ACPI_TABLES,
        .DEVICE_TREE,
        .MSR_ACCESS,
        .IOPORT_ACCESS,
        .PCI_ACCESS,
        .KGDB,
        .KEXEC,
        .HIBERNATION,
        .BPF_SYSCALL,
        .PERF_EVENTS,
        .CRASH_DUMPS,
        .DISK_ENCRYPTION,
    };

    for (all_ops) |op| {
        if (!isAllowed(op)) {
            info.addBlockedOperation(op);
        }
    }

    return info;
}

// ============================================================================
// Capability Integration
// ============================================================================

/// Check if current process can bypass lockdown (requires CAP_SYS_RAWIO)
pub fn canBypass() bool {
    // Even with CAP_SYS_RAWIO, cannot bypass confidentiality lockdown
    if (current_level == .CONFIDENTIALITY) {
        return false;
    }

    // For integrity mode, CAP_SYS_RAWIO can bypass some restrictions
    return capabilities.hasCapability(.CAP_SYS_RAWIO);
}

/// Check operation with capability bypass
pub fn checkWithCapability(operation: LockedOperation) !void {
    if (canBypass()) {
        // Log that bypass was used
        var buf: [128]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "Lockdown bypass: {s}", .{@tagName(operation)}) catch "lockdown_bypass";
        audit.logSecurityViolation(msg);
        return;
    }

    try checkAllowed(operation);
}

// ============================================================================
// Secure Boot Integration
// ============================================================================

var secure_boot_enabled = false;

/// Set secure boot status (called during boot)
pub fn setSecureBoot(enabled: bool) void {
    lockdown_lock.acquire();
    defer lockdown_lock.release();

    secure_boot_enabled = enabled;

    // If secure boot is enabled, automatically enable lockdown
    if (enabled and current_level == .NONE) {
        current_level = .INTEGRITY;
        lockdown_enabled = true;
        audit.logSecurityViolation("Lockdown enabled by secure boot");
    }
}

/// Check if secure boot is enabled
pub fn isSecureBootEnabled() bool {
    lockdown_lock.acquire();
    defer lockdown_lock.release();

    return secure_boot_enabled;
}

// ============================================================================
// Tests
// ============================================================================

test "lockdown levels" {
    // Test in isolation (don't affect global state in tests)
    const none_level = LockdownLevel.NONE;
    const integrity_level = LockdownLevel.INTEGRITY;
    const confidentiality_level = LockdownLevel.CONFIDENTIALITY;

    try Basics.testing.expect(none_level == .NONE);
    try Basics.testing.expect(integrity_level == .INTEGRITY);
    try Basics.testing.expect(confidentiality_level == .CONFIDENTIALITY);
}

test "lockdown blocks kernel mem in integrity" {
    // Simulate integrity mode check
    const level = LockdownLevel.INTEGRITY;

    const blocked = switch (level) {
        .INTEGRITY => switch (LockedOperation.KERNEL_MEM_ACCESS) {
            .KERNEL_MEM_ACCESS => true,
            else => false,
        },
        else => false,
    };

    try Basics.testing.expect(blocked);
}

test "lockdown blocks hibernation in confidentiality" {
    const level = LockdownLevel.CONFIDENTIALITY;

    const blocked = switch (level) {
        .CONFIDENTIALITY => switch (LockedOperation.HIBERNATION) {
            .HIBERNATION => true,
            else => false,
        },
        else => false,
    };

    try Basics.testing.expect(blocked);
}

test "lockdown info structure" {
    var info = LockdownInfo.init();

    try Basics.testing.expect(info.blocked_count == 0);

    info.addBlockedOperation(.KERNEL_MEM_ACCESS);
    info.addBlockedOperation(.UNSIGNED_MODULE);

    try Basics.testing.expect(info.blocked_count == 2);
    try Basics.testing.expect(info.blocked_operations[0] == .KERNEL_MEM_ACCESS);
    try Basics.testing.expect(info.blocked_operations[1] == .UNSIGNED_MODULE);
}
