// Home Programming Language - Mandatory Access Control (MAC)
// SELinux/AppArmor-style security framework for fine-grained access control
//
// This module provides:
// - Security contexts (user, role, type, level)
// - Access control policies (allow/deny rules)
// - Policy enforcement points
// - Capability management
// - Audit logging

const std = @import("std");
const builtin = @import("builtin");

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

pub const context = @import("context.zig");
pub const policy = @import("policy.zig");
pub const enforcement = @import("enforcement.zig");
pub const capabilities = @import("capabilities.zig");
pub const audit = @import("audit.zig");

// Re-export commonly used types
pub const SecurityContext = context.SecurityContext;
pub const Policy = policy.Policy;
pub const AccessDecision = enforcement.AccessDecision;
pub const Capability = capabilities.Capability;
pub const AuditLog = audit.AuditLog;

/// MAC enforcement mode
pub const EnforcementMode = enum {
    /// Enforcing mode - deny access and log violations
    enforcing,
    /// Permissive mode - allow access but log violations
    permissive,
    /// Disabled mode - no enforcement
    disabled,
};

/// Global MAC configuration
pub const Config = struct {
    mode: EnforcementMode = .enforcing,
    audit_enabled: bool = true,
    default_deny: bool = true,
    capabilities_enabled: bool = true,
};

/// MAC system state
pub const System = struct {
    allocator: std.mem.Allocator,
    config: Config,
    policy: *Policy,
    audit: ?*AuditLog,
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*System {
        const system = try allocator.create(System);

        const sys_policy = try Policy.init(allocator);
        errdefer sys_policy.deinit();

        const sys_audit = if (config.audit_enabled)
            try AuditLog.init(allocator)
        else
            null;

        system.* = .{
            .allocator = allocator,
            .config = config,
            .policy = sys_policy,
            .audit = sys_audit,
            .mutex = .unlocked,
        };

        return system;
    }

    pub fn deinit(self: *System) void {
        self.policy.deinit();
        if (self.audit) |log| {
            log.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Check if access should be granted
    pub fn checkAccess(
        self: *System,
        subject: SecurityContext,
        object: SecurityContext,
        operation: policy.Operation,
    ) !AccessDecision {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const decision = try enforcement.evaluate(
            self.policy,
            subject,
            object,
            operation,
        );

        // Audit the decision
        if (self.audit) |log| {
            try log.logAccess(subject, object, operation, decision);
        }

        return decision;
    }

    /// Set enforcement mode
    pub fn setMode(self: *System, mode: EnforcementMode) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.config.mode = mode;
    }

    /// Get current enforcement mode
    pub fn getMode(self: *System) EnforcementMode {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return self.config.mode;
    }

    /// Load policy from file
    pub fn loadPolicy(self: *System, path: []const u8) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        try self.policy.loadFromFile(path);

        if (self.audit) |log| {
            try log.logEvent(.policy_loaded, "Policy loaded from file");
        }
    }

    /// Add a policy rule
    pub fn addRule(self: *System, rule: policy.Rule) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        try self.policy.addRule(rule);

        if (self.audit) |log| {
            try log.logEvent(.policy_change, "Policy rule added");
        }
    }
};

/// Create a default MAC system with standard configuration
pub fn createDefault(allocator: std.mem.Allocator) !*System {
    return try System.init(allocator, .{});
}

/// Create a MAC system in permissive mode (for testing)
pub fn createPermissive(allocator: std.mem.Allocator) !*System {
    return try System.init(allocator, .{
        .mode = .permissive,
        .audit_enabled = true,
    });
}

test "MAC system initialization" {
    const testing = std.testing;

    var system = try createDefault(testing.allocator);
    defer system.deinit();

    try testing.expectEqual(EnforcementMode.enforcing, system.getMode());
}

test "MAC enforcement mode" {
    const testing = std.testing;

    var system = try createDefault(testing.allocator);
    defer system.deinit();

    system.setMode(.permissive);
    try testing.expectEqual(EnforcementMode.permissive, system.getMode());

    system.setMode(.disabled);
    try testing.expectEqual(EnforcementMode.disabled, system.getMode());
}
