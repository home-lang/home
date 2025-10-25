// Home OS Kernel - Information Leakage Prevention
// Prevents kernel addresses and sensitive data from leaking to userspace

const Basics = @import("basics");
const random = @import("random.zig");

// ============================================================================
// Pointer Obfuscation
// ============================================================================

var pointer_cookie: u64 = 0;
var cookie_initialized = false;

/// Initialize pointer obfuscation cookie
pub fn initPointerCookie() void {
    if (cookie_initialized) return;

    pointer_cookie = random.getRandom();
    cookie_initialized = true;
}

/// Obfuscate a kernel pointer before exposing to userspace
pub fn obfuscatePointer(ptr: usize) usize {
    if (!cookie_initialized) initPointerCookie();

    // XOR with random cookie and rotate
    const obfuscated = ptr ^ pointer_cookie;
    // Additional obfuscation: rotate bits
    return (obfuscated << 13) | (obfuscated >> (64 - 13));
}

/// Deobfuscate a pointer (for kernel internal use only)
pub fn deobfuscatePointer(obfuscated: usize) usize {
    if (!cookie_initialized) return 0;

    // Reverse rotation
    const rotated_back = (obfuscated >> 13) | (obfuscated << (64 - 13));
    // XOR with cookie
    return rotated_back ^ pointer_cookie;
}

// ============================================================================
// Address Sanitization for Error Messages
// ============================================================================

/// Sanitize kernel address in error message
pub fn sanitizeAddress(addr: usize) []const u8 {
    _ = addr;
    // Replace actual address with placeholder
    return "<kernel>";
}

/// Format error message without exposing kernel addresses
pub fn formatSafeError(comptime fmt: []const u8, args: anytype) []const u8 {
    // In production, this would parse fmt and replace %p with obfuscated pointers
    _ = fmt;
    _ = args;
    return "Error occurred (details hidden for security)";
}

// ============================================================================
// /proc Information Filtering
// ============================================================================

pub const ProcFilter = struct {
    /// Hide kernel addresses in /proc/kallsyms
    hide_kallsyms: bool = true,
    /// Hide kernel modules in /proc/modules
    hide_modules: bool = false,
    /// Restrict /proc/[pid]/maps to process owner
    restrict_maps: bool = true,
    /// Hide command line args
    hide_cmdline: bool = false,
    /// Hide environment variables
    hide_environ: bool = true,

    pub fn init() ProcFilter {
        return .{};
    }

    /// Check if current user can see kallsyms
    pub fn canSeeKallsyms(self: *const ProcFilter) bool {
        if (!self.hide_kallsyms) return true;

        // Only root can see kernel symbols
        const capabilities = @import("capabilities.zig");
        return capabilities.hasCapability(.CAP_SYSLOG);
    }

    /// Check if current user can see process maps
    pub fn canSeeMaps(self: *const ProcFilter, target_uid: u32) bool {
        if (!self.restrict_maps) return true;

        const process = @import("process.zig");
        const current = process.getCurrentProcess() orelse return false;

        // Owner can always see their own maps
        if (current.uid == target_uid) return true;

        // Root can see all maps
        if (current.uid == 0) return true;

        return false;
    }
};

var global_proc_filter = ProcFilter.init();

pub fn setProcFilter(filter: ProcFilter) void {
    global_proc_filter = filter;
}

pub fn getProcFilter() *const ProcFilter {
    return &global_proc_filter;
}

// ============================================================================
// Kernel Log Filtering
// ============================================================================

pub const LogLevel = enum(u8) {
    EMERG = 0,   // System is unusable
    ALERT = 1,   // Action must be taken immediately
    CRIT = 2,    // Critical conditions
    ERR = 3,     // Error conditions
    WARNING = 4, // Warning conditions
    NOTICE = 5,  // Normal but significant
    INFO = 6,    // Informational
    DEBUG = 7,   // Debug-level messages
};

/// Filter kernel log message to remove sensitive information
pub fn filterLogMessage(msg: []const u8, level: LogLevel) []const u8 {
    _ = level;

    // In production, this would:
    // 1. Replace kernel addresses with <kernel>
    // 2. Remove function names from stack traces
    // 3. Sanitize user data
    // For now, just return as-is
    return msg;
}

/// Check if user can read kernel logs
pub fn canReadKernelLog() bool {
    const capabilities = @import("capabilities.zig");
    return capabilities.hasCapability(.CAP_SYSLOG);
}

// ============================================================================
// Stack Trace Sanitization
// ============================================================================

pub const StackFrame = struct {
    ip: usize,              // Instruction pointer
    function_name: [64]u8,  // Function name
    function_len: usize,

    pub fn init(ip: usize, name: []const u8) StackFrame {
        var frame: StackFrame = undefined;
        frame.ip = ip;

        const len = Basics.math.min(name.len, 63);
        @memcpy(frame.function_name[0..len], name[0..len]);
        frame.function_len = len;

        return frame;
    }

    /// Get sanitized instruction pointer
    pub fn getSanitizedIp(self: *const StackFrame) []const u8 {
        if (canReadKernelLog()) {
            // Privileged user can see actual addresses
            var buf: [32]u8 = undefined;
            _ = Basics.fmt.bufPrint(&buf, "0x{x}", .{self.ip}) catch "";
            return &buf;
        } else {
            // Unprivileged user sees obfuscated address
            return "<kernel>";
        }
    }

    /// Get function name (if allowed)
    pub fn getFunctionName(self: *const StackFrame) []const u8 {
        if (canReadKernelLog()) {
            return self.function_name[0..self.function_len];
        } else {
            return "<hidden>";
        }
    }
};

// ============================================================================
// Memory Zeroing for Freed Objects
// ============================================================================

/// Securely zero memory before freeing
pub fn secureZero(ptr: [*]u8, len: usize) void {
    // Use volatile write to prevent compiler optimization
    var i: usize = 0;
    while (i < len) : (i += 1) {
        @as(*volatile u8, @ptrCast(&ptr[i])).* = 0;
    }
}

/// Zero sensitive structure before freeing
pub fn zeroSensitiveData(comptime T: type, ptr: *T) void {
    const bytes: [*]u8 = @ptrCast(ptr);
    secureZero(bytes, @sizeOf(T));
}

// ============================================================================
// Timing Attack Mitigation
// ============================================================================

/// Constant-time comparison to prevent timing attacks
pub fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        diff |= byte_a ^ byte_b;
    }

    return diff == 0;
}

/// Constant-time string comparison
pub fn constantTimeStringEqual(a: []const u8, b: []const u8) bool {
    return constantTimeEqual(a, b);
}

// ============================================================================
// KASLR Cookie Management
// ============================================================================

var kaslr_offset: usize = 0;
var kaslr_initialized = false;

/// Initialize KASLR offset (called at boot)
pub fn initKaslrOffset(offset: usize) void {
    if (kaslr_initialized) return;

    kaslr_offset = offset;
    kaslr_initialized = true;
}

/// Get KASLR offset (privileged only)
pub fn getKaslrOffset() !usize {
    if (!canReadKernelLog()) {
        return error.PermissionDenied;
    }

    return kaslr_offset;
}

/// Convert kernel address to obfuscated form for export
pub fn exportKernelAddress(addr: usize) usize {
    if (canReadKernelLog()) {
        return addr; // Privileged user gets real address
    } else {
        return obfuscatePointer(addr);
    }
}

// ============================================================================
// Uninitialized Memory Detection
// ============================================================================

const POISON_BYTE: u8 = 0xAA;

/// Poison freed memory to detect use-after-free
pub fn poisonMemory(ptr: [*]u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        ptr[i] = POISON_BYTE;
    }
}

/// Check if memory contains poison pattern
pub fn isMemoryPoisoned(ptr: [*]const u8, len: usize) bool {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (ptr[i] != POISON_BYTE) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "pointer obfuscation" {
    initPointerCookie();

    const orig_ptr: usize = 0x12345678;
    const obfuscated = obfuscatePointer(orig_ptr);

    // Obfuscated should be different
    try Basics.testing.expect(obfuscated != orig_ptr);

    // Should be able to deobfuscate
    const deobfuscated = deobfuscatePointer(obfuscated);
    try Basics.testing.expect(deobfuscated == orig_ptr);
}

test "secure zero" {
    var data = [_]u8{1, 2, 3, 4, 5};

    secureZero(&data, 5);

    for (data) |byte| {
        try Basics.testing.expect(byte == 0);
    }
}

test "constant time comparison" {
    const a = "password123";
    const b = "password123";
    const c = "password456";

    try Basics.testing.expect(constantTimeEqual(a, b));
    try Basics.testing.expect(!constantTimeEqual(a, c));
}

test "memory poisoning" {
    var data = [_]u8{0} ** 10;

    poisonMemory(&data, 10);

    try Basics.testing.expect(isMemoryPoisoned(&data, 10));

    data[5] = 0xFF;
    try Basics.testing.expect(!isMemoryPoisoned(&data, 10));
}

test "proc filter" {
    const filter = ProcFilter.init();

    try Basics.testing.expect(filter.hide_kallsyms);
    try Basics.testing.expect(filter.restrict_maps);
}
