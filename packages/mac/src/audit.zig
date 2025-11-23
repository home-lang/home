// Audit Logging - Security event logging and monitoring

const std = @import("std");

/// Get current Unix timestamp in seconds since epoch
fn getUnixTimestamp() i64 {
    if (@hasDecl(std.posix, "CLOCK") and @hasDecl(std.posix, "clock_gettime")) {
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }
    return 0;
}

const context = @import("context.zig");
const policy = @import("policy.zig");
const enforcement = @import("enforcement.zig");

const SecurityContext = context.SecurityContext;
const Operation = policy.Operation;
const AccessDecision = enforcement.AccessDecision;

/// Audit event types
pub const EventType = enum {
    access_allowed,
    access_denied,
    policy_loaded,
    policy_change,
    context_change,
    capability_use,
    violation,
    system_event,

    pub fn toString(self: EventType) []const u8 {
        return @tagName(self);
    }
};

/// Audit event severity
pub const Severity = enum {
    debug,
    info,
    warning,
    err,
    critical,

    pub fn toString(self: Severity) []const u8 {
        return @tagName(self);
    }
};

/// Audit log entry
pub const AuditEntry = struct {
    timestamp: i64,
    event_type: EventType,
    severity: Severity,
    subject: ?[]const u8, // Subject context (if applicable)
    object: ?[]const u8, // Object context (if applicable)
    operation: ?[]const u8, // Operation (if applicable)
    result: ?[]const u8, // Result (allowed/denied)
    message: []const u8,
    pid: ?std.posix.pid_t, // Process ID (if applicable)

    pub fn format(
        self: AuditEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("[{d}] {s} {s}: {s}", .{
            self.timestamp,
            self.severity.toString(),
            self.event_type.toString(),
            self.message,
        });

        if (self.subject) |subj| {
            try writer.print(" subject={s}", .{subj});
        }
        if (self.object) |obj| {
            try writer.print(" object={s}", .{obj});
        }
        if (self.operation) |op| {
            try writer.print(" operation={s}", .{op});
        }
        if (self.result) |res| {
            try writer.print(" result={s}", .{res});
        }
        if (self.pid) |p| {
            try writer.print(" pid={d}", .{p});
        }
    }
};

/// Audit log
pub const AuditLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(AuditEntry),
    file: ?std.fs.File,
    mutex: std.Thread.Mutex,
    max_entries: usize, // Maximum in-memory entries (ring buffer)

    pub fn init(allocator: std.mem.Allocator) !*AuditLog {
        const log = try allocator.create(AuditLog);
        log.* = .{
            .allocator = allocator,
            .entries = std.ArrayList(AuditEntry){},
            .file = null,
            .mutex = .{},
            .max_entries = 1000, // Default: keep last 1000 entries in memory
        };
        return log;
    }

    pub fn deinit(self: *AuditLog) void {
        // Free all entry strings
        for (self.entries.items) |entry| {
            if (entry.subject) |s| self.allocator.free(s);
            if (entry.object) |o| self.allocator.free(o);
            if (entry.operation) |op| self.allocator.free(op);
            if (entry.result) |r| self.allocator.free(r);
            self.allocator.free(entry.message);
        }
        self.entries.deinit(self.allocator);

        if (self.file) |f| {
            f.close();
        }

        self.allocator.destroy(self);
    }

    /// Set output file for audit logs
    pub fn setOutputFile(self: *AuditLog, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.file) |f| {
            f.close();
        }

        self.file = try std.fs.cwd().createFile(path, .{
            .truncate = false,
            .mode = 0o600, // Only owner can read/write
        });

        // Seek to end for append
        try self.file.?.seekFromEnd(0);
    }

    /// Log an access decision
    pub fn logAccess(
        self: *AuditLog,
        subject: SecurityContext,
        object: SecurityContext,
        operation: Operation,
        decision: AccessDecision,
    ) !void {
        const subject_str = try subject.toString(self.allocator);
        const object_str = try object.toString(self.allocator);

        const event_type: EventType = if (decision.allowed) .access_allowed else .access_denied;
        const severity: Severity = if (decision.allowed) .info else .warning;

        const result_str = if (decision.allowed) "allowed" else "denied";

        try self.addEntry(.{
            .timestamp = getUnixTimestamp(),
            .event_type = event_type,
            .severity = severity,
            .subject = subject_str,
            .object = object_str,
            .operation = try self.allocator.dupe(u8, operation.toString()),
            .result = try self.allocator.dupe(u8, result_str),
            .message = try self.allocator.dupe(u8, decision.reason),
            .pid = null,
        });
    }

    /// Log a general event
    pub fn logEvent(self: *AuditLog, event_type: EventType, message: []const u8) !void {
        try self.addEntry(.{
            .timestamp = getUnixTimestamp(),
            .event_type = event_type,
            .severity = .info,
            .subject = null,
            .object = null,
            .operation = null,
            .result = null,
            .message = try self.allocator.dupe(u8, message),
            .pid = null,
        });
    }

    /// Log a violation (high severity)
    pub fn logViolation(
        self: *AuditLog,
        subject: []const u8,
        message: []const u8,
    ) !void {
        try self.addEntry(.{
            .timestamp = getUnixTimestamp(),
            .event_type = .violation,
            .severity = .critical,
            .subject = try self.allocator.dupe(u8, subject),
            .object = null,
            .operation = null,
            .result = null,
            .message = try self.allocator.dupe(u8, message),
            .pid = null,
        });
    }

    /// Internal log function
    fn addEntry(self: *AuditLog, entry: AuditEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Add to in-memory buffer (ring buffer)
        if (self.entries.items.len >= self.max_entries) {
            // Remove oldest entry
            const old = self.entries.orderedRemove(0);
            if (old.subject) |s| self.allocator.free(s);
            if (old.object) |o| self.allocator.free(o);
            if (old.operation) |op| self.allocator.free(op);
            if (old.result) |r| self.allocator.free(r);
            self.allocator.free(old.message);
        }

        try self.entries.append(self.allocator, entry);

        // Write to file if configured
        if (self.file) |f| {
            var buf: [4096]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&buf, "{any}\n", .{entry});
            try f.writeAll(formatted);
        }
    }

    /// Get recent entries
    pub fn getRecent(self: *AuditLog, num_entries: usize) []const AuditEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const start = if (self.entries.items.len > num_entries)
            self.entries.items.len - num_entries
        else
            0;

        return self.entries.items[start..];
    }

    /// Get entries by event type
    pub fn getByType(
        self: *AuditLog,
        allocator: std.mem.Allocator,
        event_type: EventType,
    ) ![]AuditEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results = std.ArrayList(AuditEntry){};

        for (self.entries.items) |entry| {
            if (entry.event_type == event_type) {
                try results.append(allocator, entry);
            }
        }

        return results.toOwnedSlice(allocator);
    }

    /// Get entries by severity
    pub fn getBySeverity(
        self: *AuditLog,
        allocator: std.mem.Allocator,
        severity: Severity,
    ) ![]AuditEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results = std.ArrayList(AuditEntry){};

        for (self.entries.items) |entry| {
            if (entry.event_type == severity) {
                try results.append(allocator, entry);
            }
        }

        return results.toOwnedSlice(allocator);
    }

    /// Clear all entries
    pub fn clear(self: *AuditLog) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.entries.items) |entry| {
            if (entry.subject) |s| self.allocator.free(s);
            if (entry.object) |o| self.allocator.free(o);
            if (entry.operation) |op| self.allocator.free(op);
            if (entry.result) |r| self.allocator.free(r);
            self.allocator.free(entry.message);
        }

        self.entries.clearRetainingCapacity();
    }

    /// Get total entry count
    pub fn count(self: *AuditLog) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }
};

test "audit log entry creation" {
    const testing = std.testing;

    const entry = AuditEntry{
        .timestamp = getUnixTimestamp(),
        .event_type = .access_denied,
        .severity = .warning,
        .subject = "user_u:user_r:user_t:s0",
        .object = "system_u:object_r:file_t:s0",
        .operation = "write",
        .result = "denied",
        .message = "Policy denies access",
        .pid = 1234,
    };

    try testing.expectEqual(EventType.access_denied, entry.event_type);
    try testing.expectEqual(Severity.warning, entry.severity);
}

test "audit log" {
    const testing = std.testing;

    var log = try AuditLog.init(testing.allocator);
    defer log.deinit();

    try log.logEvent(.policy_loaded, "Test policy loaded");

    try testing.expectEqual(@as(usize, 1), log.count());

    const recent = log.getRecent(10);
    try testing.expectEqual(@as(usize, 1), recent.len);
}
