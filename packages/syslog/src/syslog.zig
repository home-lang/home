// Syslog Security - Secure logging with authentication, encryption, and access control
//
// This package provides secure syslog functionality with integrity protection,
// encryption, access control, and rate limiting.

const std = @import("std");

/// Get current Unix timestamp in seconds since epoch
fn getUnixTimestamp() i64 {
    if (@hasDecl(std.posix, "CLOCK") and @hasDecl(std.posix, "clock_gettime")) {
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }
    return 0;
}

pub const auth = @import("auth.zig");
pub const encrypt = @import("encrypt.zig");
pub const access = @import("access.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const remote = @import("remote.zig");

/// Syslog severity levels (RFC 5424)
pub const Severity = enum(u8) {
    emergency = 0, // System is unusable
    alert = 1, // Action must be taken immediately
    critical = 2, // Critical conditions
    err = 3, // Error conditions
    warning = 4, // Warning conditions
    notice = 5, // Normal but significant
    info = 6, // Informational messages
    debug = 7, // Debug-level messages

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .emergency => "EMERG",
            .alert => "ALERT",
            .critical => "CRIT",
            .err => "ERROR",
            .warning => "WARN",
            .notice => "NOTICE",
            .info => "INFO",
            .debug => "DEBUG",
        };
    }

    pub fn fromInt(value: u8) !Severity {
        return std.meta.intToEnum(Severity, value);
    }
};

/// Syslog facility (RFC 5424)
pub const Facility = enum(u8) {
    kernel = 0,
    user = 1,
    mail = 2,
    daemon = 3,
    auth = 4,
    syslog = 5,
    lpr = 6,
    news = 7,
    uucp = 8,
    cron = 9,
    authpriv = 10,
    ftp = 11,
    local0 = 16,
    local1 = 17,
    local2 = 18,
    local3 = 19,
    local4 = 20,
    local5 = 21,
    local6 = 22,
    local7 = 23,

    pub fn toString(self: Facility) []const u8 {
        return switch (self) {
            .kernel => "kernel",
            .user => "user",
            .mail => "mail",
            .daemon => "daemon",
            .auth => "auth",
            .syslog => "syslog",
            .lpr => "lpr",
            .news => "news",
            .uucp => "uucp",
            .cron => "cron",
            .authpriv => "authpriv",
            .ftp => "ftp",
            .local0 => "local0",
            .local1 => "local1",
            .local2 => "local2",
            .local3 => "local3",
            .local4 => "local4",
            .local5 => "local5",
            .local6 => "local6",
            .local7 => "local7",
        };
    }
};

/// Log message
pub const LogMessage = struct {
    facility: Facility,
    severity: Severity,
    timestamp: i64,
    hostname: [256]u8,
    hostname_len: usize,
    app_name: [48]u8,
    app_name_len: usize,
    process_id: u32,
    message: []u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        facility: Facility,
        severity: Severity,
        hostname: []const u8,
        app_name: []const u8,
        process_id: u32,
        message: []const u8,
    ) !LogMessage {
        if (hostname.len > 255) return error.HostnameTooLong;
        if (app_name.len > 47) return error.AppNameTooLong;

        const msg_copy = try allocator.dupe(u8, message);

        var log = LogMessage{
            .facility = facility,
            .severity = severity,
            .timestamp = getUnixTimestamp(),
            .hostname = [_]u8{0} ** 256,
            .hostname_len = hostname.len,
            .app_name = [_]u8{0} ** 48,
            .app_name_len = app_name.len,
            .process_id = process_id,
            .message = msg_copy,
            .allocator = allocator,
        };

        @memcpy(log.hostname[0..hostname.len], hostname);
        @memcpy(log.app_name[0..app_name.len], app_name);

        return log;
    }

    pub fn deinit(self: *LogMessage) void {
        self.allocator.free(self.message);
    }

    pub fn getHostname(self: *const LogMessage) []const u8 {
        return self.hostname[0..self.hostname_len];
    }

    pub fn getAppName(self: *const LogMessage) []const u8 {
        return self.app_name[0..self.app_name_len];
    }

    /// Get priority (facility * 8 + severity)
    pub fn getPriority(self: *const LogMessage) u8 {
        return (@intFromEnum(self.facility) * 8) + @intFromEnum(self.severity);
    }

    /// Format as RFC 5424 syslog message
    pub fn formatRFC5424(self: *const LogMessage, allocator: std.mem.Allocator) ![]u8 {
        const iso_time = try formatISO8601(allocator, self.timestamp);
        defer allocator.free(iso_time);

        return try std.fmt.allocPrint(
            allocator,
            "<{d}>1 {s} {s} {s} {d} - - {s}",
            .{
                self.getPriority(),
                iso_time,
                self.getHostname(),
                self.getAppName(),
                self.process_id,
                self.message,
            },
        );
    }
};

fn formatISO8601(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    // Simplified ISO 8601 formatting
    return try std.fmt.allocPrint(allocator, "{d}Z", .{timestamp});
}

/// Syslog configuration
pub const SyslogConfig = struct {
    /// Enable authentication (HMAC)
    enable_auth: bool = true,
    /// Enable encryption for sensitive logs
    enable_encryption: bool = false,
    /// Enable access control
    enable_access_control: bool = true,
    /// Enable rate limiting
    enable_rate_limit: bool = true,
    /// Maximum log message size
    max_message_size: usize = 8192,
    /// Rate limit (messages per second)
    rate_limit: u32 = 1000,
    /// Minimum severity to log
    min_severity: Severity = .info,
};

test "severity levels" {
    const testing = std.testing;

    const emerg = Severity.emergency;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(emerg));
    try testing.expectEqualStrings("EMERG", emerg.toString());

    const info = Severity.info;
    try testing.expectEqual(@as(u8, 6), @intFromEnum(info));
}

test "log message" {
    const testing = std.testing;

    var msg = try LogMessage.init(
        testing.allocator,
        .daemon,
        .info,
        "localhost",
        "myapp",
        1234,
        "Test message",
    );
    defer msg.deinit();

    try testing.expectEqual(Facility.daemon, msg.facility);
    try testing.expectEqual(Severity.info, msg.severity);
    try testing.expectEqualStrings("localhost", msg.getHostname());
    try testing.expectEqualStrings("myapp", msg.getAppName());
    try testing.expectEqual(@as(u32, 1234), msg.process_id);

    // Priority = facility * 8 + severity = 3 * 8 + 6 = 30
    try testing.expectEqual(@as(u8, 30), msg.getPriority());
}
