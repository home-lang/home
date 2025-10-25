// Home OS Kernel - Security Audit Logging
// Logs security-critical events for monitoring and forensics

const Basics = @import("basics");
const process = @import("process.zig");
const sync = @import("sync.zig");

// ============================================================================
// Audit Event Types
// ============================================================================

pub const AuditEventType = enum(u16) {
    /// System boot/shutdown
    AUDIT_SYSTEM_BOOT = 1,
    AUDIT_SYSTEM_SHUTDOWN = 2,

    /// Authentication events
    AUDIT_AUTH_SUCCESS = 100,
    AUDIT_AUTH_FAILURE = 101,

    /// Privilege changes
    AUDIT_SETUID = 200,
    AUDIT_SETGID = 201,
    AUDIT_SETEUID = 202,
    AUDIT_SETEGID = 203,
    AUDIT_CAPABILITY_ADD = 204,
    AUDIT_CAPABILITY_DROP = 205,

    /// File access
    AUDIT_FILE_OPEN = 300,
    AUDIT_FILE_CREATE = 301,
    AUDIT_FILE_DELETE = 302,
    AUDIT_FILE_PERMISSION_DENIED = 303,

    /// Process events
    AUDIT_PROCESS_CREATE = 400,
    AUDIT_PROCESS_EXIT = 401,
    AUDIT_SIGNAL_SEND = 402,

    /// Security violations
    AUDIT_ACCESS_DENIED = 500,
    AUDIT_SECURITY_VIOLATION = 501,
    AUDIT_RATE_LIMIT_EXCEEDED = 502,
    AUDIT_RESOURCE_LIMIT_EXCEEDED = 503,

    /// Network events
    AUDIT_NETWORK_CONNECT = 600,
    AUDIT_NETWORK_BIND = 601,
    AUDIT_NETWORK_LISTEN = 602,

    /// Module loading
    AUDIT_MODULE_LOAD = 700,
    AUDIT_MODULE_UNLOAD = 701,
};

pub const AuditSeverity = enum(u8) {
    DEBUG = 0,
    INFO = 1,
    WARNING = 2,
    ERROR = 3,
    CRITICAL = 4,
};

// ============================================================================
// Audit Event Structure
// ============================================================================

pub const AuditEvent = struct {
    /// Event type
    event_type: AuditEventType,
    /// Severity level
    severity: AuditSeverity,
    /// Timestamp (TODO: add real timestamp)
    timestamp: u64,
    /// Process ID
    pid: u32,
    /// User ID
    uid: u32,
    /// Event-specific data
    data: [256]u8,
    data_len: usize,

    pub fn init(event_type: AuditEventType, severity: AuditSeverity) AuditEvent {
        const current = process.getCurrentProcess();

        return .{
            .event_type = event_type,
            .severity = severity,
            .timestamp = 0, // TODO: Get current timestamp
            .pid = if (current) |p| p.pid else 0,
            .uid = if (current) |p| p.uid else 0,
            .data = undefined,
            .data_len = 0,
        };
    }

    /// Add string data to event
    pub fn addData(self: *AuditEvent, data: []const u8) void {
        const copy_len = Basics.math.min(data.len, 255 - self.data_len);
        @memcpy(self.data[self.data_len .. self.data_len + copy_len], data[0..copy_len]);
        self.data_len += copy_len;
    }

    /// Get data as string
    pub fn getData(self: *const AuditEvent) []const u8 {
        return self.data[0..self.data_len];
    }
};

// ============================================================================
// Audit Log Buffer (Ring Buffer)
// ============================================================================

const AUDIT_LOG_SIZE = 1024; // Store last 1024 events

var audit_log: [AUDIT_LOG_SIZE]AuditEvent = undefined;
var audit_log_head: usize = 0;
var audit_log_tail: usize = 0;
var audit_log_lock = sync.Spinlock.init();
var audit_log_initialized = false;

/// Initialize audit logging
pub fn init() void {
    audit_log_lock.acquire();
    defer audit_log_lock.release();

    if (audit_log_initialized) return;

    audit_log_head = 0;
    audit_log_tail = 0;
    audit_log_initialized = true;
}

/// Log an audit event
pub fn logEvent(event: AuditEvent) void {
    audit_log_lock.acquire();
    defer audit_log_lock.release();

    if (!audit_log_initialized) return;

    // Add event to ring buffer
    audit_log[audit_log_head] = event;
    audit_log_head = (audit_log_head + 1) % AUDIT_LOG_SIZE;

    // If full, move tail forward (overwrite oldest)
    if (audit_log_head == audit_log_tail) {
        audit_log_tail = (audit_log_tail + 1) % AUDIT_LOG_SIZE;
    }

    // TODO: Also write to serial/disk for persistence
}

/// Get audit log events (for reading)
pub fn getEvents(out: []AuditEvent) usize {
    audit_log_lock.acquire();
    defer audit_log_lock.release();

    var count: usize = 0;
    var idx = audit_log_tail;

    while (idx != audit_log_head and count < out.len) {
        out[count] = audit_log[idx];
        count += 1;
        idx = (idx + 1) % AUDIT_LOG_SIZE;
    }

    return count;
}

// ============================================================================
// Convenience Logging Functions
// ============================================================================

/// Log privilege change (setuid, setgid, etc.)
pub fn logPrivilegeChange(event_type: AuditEventType, old_val: u32, new_val: u32) void {
    var event = AuditEvent.init(event_type, .WARNING);

    var buf: [64]u8 = undefined;
    const msg = Basics.fmt.bufPrint(&buf, "Changed from {} to {}", .{ old_val, new_val }) catch "privilege_change";
    event.addData(msg);

    logEvent(event);
}

/// Log authentication attempt
pub fn logAuth(success: bool, username: []const u8) void {
    const event_type = if (success) AuditEventType.AUDIT_AUTH_SUCCESS else AuditEventType.AUDIT_AUTH_FAILURE;
    const severity = if (success) AuditSeverity.INFO else AuditSeverity.WARNING;

    var event = AuditEvent.init(event_type, severity);
    event.addData(username);
    logEvent(event);
}

/// Log file access
pub fn logFileAccess(path: []const u8, denied: bool) void {
    const event_type = if (denied) AuditEventType.AUDIT_FILE_PERMISSION_DENIED else AuditEventType.AUDIT_FILE_OPEN;
    const severity = if (denied) AuditSeverity.WARNING else AuditSeverity.INFO;

    var event = AuditEvent.init(event_type, severity);
    event.addData(path);
    logEvent(event);
}

/// Log access denied
pub fn logAccessDenied(resource: []const u8, reason: []const u8) void {
    var event = AuditEvent.init(.AUDIT_ACCESS_DENIED, .WARNING);

    var buf: [256]u8 = undefined;
    const msg = Basics.fmt.bufPrint(&buf, "{s}: {s}", .{ resource, reason }) catch "access_denied";
    event.addData(msg);

    logEvent(event);
}

/// Log security violation
pub fn logSecurityViolation(violation: []const u8) void {
    var event = AuditEvent.init(.AUDIT_SECURITY_VIOLATION, .ERROR);
    event.addData(violation);
    logEvent(event);
}

/// Log rate limit exceeded
pub fn logRateLimitExceeded(operation: []const u8) void {
    var event = AuditEvent.init(.AUDIT_RATE_LIMIT_EXCEEDED, .WARNING);
    event.addData(operation);
    logEvent(event);
}

/// Log resource limit exceeded
pub fn logResourceLimitExceeded(resource: []const u8) void {
    var event = AuditEvent.init(.AUDIT_RESOURCE_LIMIT_EXCEEDED, .WARNING);
    event.addData(resource);
    logEvent(event);
}

/// Log process creation
pub fn logProcessCreate(child_pid: u32) void {
    var event = AuditEvent.init(.AUDIT_PROCESS_CREATE, .INFO);

    var buf: [32]u8 = undefined;
    const msg = Basics.fmt.bufPrint(&buf, "PID {}", .{child_pid}) catch "process_create";
    event.addData(msg);

    logEvent(event);
}

/// Log process exit
pub fn logProcessExit(exit_code: i32) void {
    var event = AuditEvent.init(.AUDIT_PROCESS_EXIT, .INFO);

    var buf: [32]u8 = undefined;
    const msg = Basics.fmt.bufPrint(&buf, "Exit code: {}", .{exit_code}) catch "process_exit";
    event.addData(msg);

    logEvent(event);
}

/// Log signal send
pub fn logSignalSend(target_pid: u32, signal: i32) void {
    var event = AuditEvent.init(.AUDIT_SIGNAL_SEND, .INFO);

    var buf: [64]u8 = undefined;
    const msg = Basics.fmt.bufPrint(&buf, "Signal {} to PID {}", .{ signal, target_pid }) catch "signal_send";
    event.addData(msg);

    logEvent(event);
}

// ============================================================================
// Audit Configuration
// ============================================================================

pub const AuditConfig = struct {
    /// Log all file access (can be verbose)
    log_file_access: bool = false,
    /// Log all process creation
    log_process_create: bool = true,
    /// Log all authentication attempts
    log_auth: bool = true,
    /// Log all privilege changes
    log_privilege_changes: bool = true,
    /// Log all access denied events
    log_access_denied: bool = true,
    /// Minimum severity to log
    min_severity: AuditSeverity = .INFO,
};

var audit_config = AuditConfig{};

pub fn setConfig(config: AuditConfig) void {
    audit_config = config;
}

pub fn getConfig() AuditConfig {
    return audit_config;
}

/// Check if event should be logged based on configuration
pub fn shouldLog(event_type: AuditEventType, severity: AuditSeverity) bool {
    // Check minimum severity
    if (@intFromEnum(severity) < @intFromEnum(audit_config.min_severity)) {
        return false;
    }

    // Check specific event types
    return switch (event_type) {
        .AUDIT_FILE_OPEN, .AUDIT_FILE_CREATE, .AUDIT_FILE_DELETE => audit_config.log_file_access,
        .AUDIT_PROCESS_CREATE, .AUDIT_PROCESS_EXIT => audit_config.log_process_create,
        .AUDIT_AUTH_SUCCESS, .AUDIT_AUTH_FAILURE => audit_config.log_auth,
        .AUDIT_SETUID, .AUDIT_SETGID, .AUDIT_SETEUID, .AUDIT_SETEGID => audit_config.log_privilege_changes,
        .AUDIT_ACCESS_DENIED, .AUDIT_FILE_PERMISSION_DENIED => audit_config.log_access_denied,
        else => true, // Log everything else by default
    };
}

// ============================================================================
// Tests
// ============================================================================

test "audit log initialization" {
    init();
    try Basics.testing.expect(audit_log_initialized);
}

test "log event" {
    init();

    var event = AuditEvent.init(.AUDIT_AUTH_FAILURE, .WARNING);
    event.addData("test_user");

    logEvent(event);

    // Verify event was logged
    var events: [10]AuditEvent = undefined;
    const count = getEvents(&events);

    try Basics.testing.expect(count > 0);
    try Basics.testing.expect(events[count - 1].event_type == .AUDIT_AUTH_FAILURE);
}

test "audit event data" {
    var event = AuditEvent.init(.AUDIT_AUTH_SUCCESS, .INFO);
    event.addData("test_user");

    try Basics.testing.expectEqualStrings("test_user", event.getData());
}
