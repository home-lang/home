// Enforcement - Access control decision making and enforcement

const std = @import("std");
const policy = @import("policy.zig");
const context = @import("context.zig");

const Policy = policy.Policy;
const SecurityContext = context.SecurityContext;
const Operation = policy.Operation;
const Decision = policy.Decision;

/// Access decision result
pub const AccessDecision = struct {
    allowed: bool,
    reason: []const u8,
    audit: bool,

    pub fn allow(reason: []const u8) AccessDecision {
        return .{ .allowed = true, .reason = reason, .audit = false };
    }

    pub fn deny(reason: []const u8) AccessDecision {
        return .{ .allowed = false, .reason = reason, .audit = false };
    }

    pub fn allowWithAudit(reason: []const u8) AccessDecision {
        return .{ .allowed = true, .reason = reason, .audit = true };
    }

    pub fn denyWithAudit(reason: []const u8) AccessDecision {
        return .{ .allowed = false, .reason = reason, .audit = true };
    }
};

/// Evaluate access request against policy
pub fn evaluate(
    pol: *Policy,
    subject: SecurityContext,
    object: SecurityContext,
    operation: Operation,
) !AccessDecision {
    const decision = pol.evaluate(subject, object, operation);

    return switch (decision) {
        .allow => AccessDecision.allow("Policy allows access"),
        .deny => AccessDecision.deny("Policy denies access"),
        .audit_allow => AccessDecision.allowWithAudit("Policy allows with audit"),
        .audit_deny => AccessDecision.denyWithAudit("Policy denies with audit"),
    };
}

/// Check file access
pub fn checkFileAccess(
    pol: *Policy,
    process_ctx: SecurityContext,
    file_ctx: SecurityContext,
    operation: Operation,
) !AccessDecision {
    // Additional file-specific checks
    switch (operation) {
        .read, .write, .execute, .append, .delete, .rename => {
            return try evaluate(pol, process_ctx, file_ctx, operation);
        },
        else => return AccessDecision.deny("Invalid file operation"),
    }
}

/// Check network access
pub fn checkNetworkAccess(
    pol: *Policy,
    process_ctx: SecurityContext,
    network_ctx: SecurityContext,
    operation: Operation,
) !AccessDecision {
    // Additional network-specific checks
    switch (operation) {
        .connect, .bind, .listen, .accept, .send, .recv => {
            return try evaluate(pol, process_ctx, network_ctx, operation);
        },
        else => return AccessDecision.deny("Invalid network operation"),
    }
}

/// Check process access
pub fn checkProcessAccess(
    pol: *Policy,
    source_ctx: SecurityContext,
    target_ctx: SecurityContext,
    operation: Operation,
) !AccessDecision {
    // Additional process-specific checks
    switch (operation) {
        .fork, .exec, .kill, .ptrace, .signal => {
            return try evaluate(pol, source_ctx, target_ctx, operation);
        },
        else => return AccessDecision.deny("Invalid process operation"),
    }
}

/// Transition context for domain transitions (like execve in SELinux)
pub const Transition = struct {
    from: SecurityContext,
    to: SecurityContext,
    entrypoint: []const u8, // Program path that triggers transition

    /// Check if transition is allowed
    pub fn isAllowed(self: Transition, pol: *Policy) !bool {
        // Check if source domain can transition to target domain
        const decision = try evaluate(pol, self.from, self.to, .exec);
        return decision.allowed;
    }
};

/// Type enforcement - check if type transition is valid
pub fn checkTypeTransition(
    pol: *Policy,
    source_type: []const u8,
    target_type: []const u8,
    object_class: []const u8,
) bool {
    _ = pol;
    _ = object_class;

    // Simple check: only allow same-type or explicit transitions
    // In a full implementation, this would check type_transition rules
    return std.mem.eql(u8, source_type, target_type);
}

/// MLS (Multi-Level Security) enforcement
pub const MLSEnforcement = struct {
    /// Check read-down rule: can read objects at lower or equal level
    pub fn checkReadDown(subject_level: context.Level, object_level: context.Level) bool {
        return subject_level.dominates(object_level);
    }

    /// Check write-up rule: can write to objects at higher or equal level
    pub fn checkWriteUp(subject_level: context.Level, object_level: context.Level) bool {
        return object_level.dominates(subject_level);
    }

    /// Check no-read-up, no-write-down (Bell-LaPadula model)
    pub fn checkBLP(
        subject_level: context.Level,
        object_level: context.Level,
        operation: Operation,
    ) bool {
        return switch (operation) {
            .read => checkReadDown(subject_level, object_level),
            .write, .append => checkWriteUp(subject_level, object_level),
            else => true, // Other operations not subject to MLS
        };
    }
};

test "access decision" {
    const testing = std.testing;

    const allow_decision = AccessDecision.allow("test");
    try testing.expect(allow_decision.allowed);

    const deny_decision = AccessDecision.deny("test");
    try testing.expect(!deny_decision.allowed);

    const audit_decision = AccessDecision.allowWithAudit("test");
    try testing.expect(audit_decision.allowed);
    try testing.expect(audit_decision.audit);
}

test "policy evaluation" {
    const testing = std.testing;

    var pol = try Policy.init(testing.allocator);
    defer pol.deinit();

    const subject = try SecurityContext.create(testing.allocator, "user_u", "user_r", "user_t", "s0");
    const object = try SecurityContext.create(testing.allocator, "system_u", "object_r", "file_t", "s0");

    try pol.addRule(.{
        .subject = subject,
        .object = object,
        .operation = .read,
        .decision = .allow,
    });

    const decision = try evaluate(pol, subject, object, .read);
    try testing.expect(decision.allowed);
}
