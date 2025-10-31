// Policy Management - Access control rules and policy enforcement

const std = @import("std");
const context = @import("context.zig");
const SecurityContext = context.SecurityContext;

/// Access operation types
pub const Operation = enum {
    // File operations
    read,
    write,
    execute,
    append,
    create,
    delete,
    rename,
    chmod,
    chown,

    // Network operations
    connect,
    bind,
    listen,
    accept,
    send,
    recv,

    // Process operations
    fork,
    exec,
    kill,
    ptrace,
    setuid,
    setgid,

    // IPC operations
    signal,
    mmap,
    shm_create,
    shm_attach,

    // System operations
    mount,
    umount,
    syslog,
    reboot,

    pub fn toString(self: Operation) []const u8 {
        return @tagName(self);
    }
};

/// Policy decision
pub const Decision = enum {
    allow,
    deny,
    audit_allow, // Allow but log
    audit_deny, // Deny and log
};

/// Policy rule
pub const Rule = struct {
    subject: SecurityContext, // Who (source domain)
    object: SecurityContext, // What (target type)
    operation: Operation, // How (access type)
    decision: Decision, // Allow/Deny
    priority: u8 = 50, // Rule priority (higher = more important)

    pub fn matches(
        self: Rule,
        subj: SecurityContext,
        obj: SecurityContext,
        op: Operation,
    ) bool {
        return self.subject.matches(subj) and
            self.object.matches(obj) and
            self.operation == op;
    }
};

/// Policy database
pub const Policy = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(Rule),
    default_decision: Decision,

    pub fn init(allocator: std.mem.Allocator) !*Policy {
        const policy = try allocator.create(Policy);
        policy.* = .{
            .allocator = allocator,
            .rules = std.ArrayList(Rule){},
            .default_decision = .deny,
        };
        return policy;
    }

    pub fn deinit(self: *Policy) void {
        // Free all context strings in rules
        for (self.rules.items) |*rule| {
            rule.subject.deinit(self.allocator);
            rule.object.deinit(self.allocator);
        }
        self.rules.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add a policy rule
    pub fn addRule(self: *Policy, rule: Rule) !void {
        // Clone the contexts to own the memory
        const owned_rule = Rule{
            .subject = try rule.subject.clone(self.allocator),
            .object = try rule.object.clone(self.allocator),
            .operation = rule.operation,
            .decision = rule.decision,
            .priority = rule.priority,
        };
        try self.rules.append(self.allocator, owned_rule);

        // Sort rules by priority (highest first)
        std.mem.sort(Rule, self.rules.items, {}, rulePriorityDesc);
    }

    fn rulePriorityDesc(_: void, a: Rule, b: Rule) bool {
        return a.priority > b.priority;
    }

    /// Find matching rule for access request
    pub fn findRule(
        self: *Policy,
        subject: SecurityContext,
        object: SecurityContext,
        operation: Operation,
    ) ?Rule {
        // Return first matching rule (highest priority)
        for (self.rules.items) |rule| {
            if (rule.matches(subject, object, operation)) {
                return rule;
            }
        }
        return null;
    }

    /// Evaluate access decision
    pub fn evaluate(
        self: *Policy,
        subject: SecurityContext,
        object: SecurityContext,
        operation: Operation,
    ) Decision {
        if (self.findRule(subject, object, operation)) |rule| {
            return rule.decision;
        }
        return self.default_decision;
    }

    /// Load policy from file
    pub fn loadFromFile(self: *Policy, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);

        try self.parsePolicy(content);
    }

    /// Parse policy text (simple format)
    /// Format: allow|deny subject_ctx object_ctx operation [priority]
    fn parsePolicy(self: *Policy, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var parts = std.mem.tokenize(u8, trimmed, " \t");

            // Parse decision
            const decision_str = parts.next() orelse continue;
            const decision = if (std.mem.eql(u8, decision_str, "allow"))
                Decision.allow
            else if (std.mem.eql(u8, decision_str, "deny"))
                Decision.deny
            else if (std.mem.eql(u8, decision_str, "audit_allow"))
                Decision.audit_allow
            else if (std.mem.eql(u8, decision_str, "audit_deny"))
                Decision.audit_deny
            else
                continue;

            // Parse subject, object, operation
            const subject_str = parts.next() orelse continue;
            const object_str = parts.next() orelse continue;
            const operation_str = parts.next() orelse continue;

            // Parse priority (optional)
            const priority: u8 = if (parts.next()) |p|
                std.fmt.parseInt(u8, p, 10) catch 50
            else
                50;

            // Parse operation
            const operation = std.meta.stringToEnum(Operation, operation_str) orelse continue;

            // Parse contexts
            const subject = try SecurityContext.parse(self.allocator, subject_str);
            errdefer subject.deinit(self.allocator);

            const object = try SecurityContext.parse(self.allocator, object_str);
            errdefer object.deinit(self.allocator);

            // Add rule
            try self.addRule(.{
                .subject = subject,
                .object = object,
                .operation = operation,
                .decision = decision,
                .priority = priority,
            });
        }
    }

    /// Save policy to file
    pub fn saveToFile(self: *Policy, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll("# MAC Policy File\n");
        try writer.writeAll("# Format: decision subject object operation [priority]\n\n");

        for (self.rules.items) |rule| {
            const subject_str = try rule.subject.toString(self.allocator);
            defer self.allocator.free(subject_str);

            const object_str = try rule.object.toString(self.allocator);
            defer self.allocator.free(object_str);

            const decision_str = switch (rule.decision) {
                .allow => "allow",
                .deny => "deny",
                .audit_allow => "audit_allow",
                .audit_deny => "audit_deny",
            };

            try writer.print("{s} {s} {s} {s} {d}\n", .{
                decision_str,
                subject_str,
                object_str,
                rule.operation.toString(),
                rule.priority,
            });
        }
    }

    /// Clear all rules
    pub fn clear(self: *Policy) void {
        for (self.rules.items) |*rule| {
            rule.subject.deinit(self.allocator);
            rule.object.deinit(self.allocator);
        }
        self.rules.clearRetainingCapacity();
    }

    /// Get rule count
    pub fn count(self: *Policy) usize {
        return self.rules.items.len;
    }
};

/// Policy builder for easier policy creation
pub const PolicyBuilder = struct {
    allocator: std.mem.Allocator,
    policy: *Policy,

    pub fn init(allocator: std.mem.Allocator) !PolicyBuilder {
        return .{
            .allocator = allocator,
            .policy = try Policy.init(allocator),
        };
    }

    /// Allow operation
    pub fn allow(
        self: *PolicyBuilder,
        subject: []const u8,
        object: []const u8,
        operation: Operation,
    ) !*PolicyBuilder {
        const subj = try SecurityContext.parse(self.allocator, subject);
        const obj = try SecurityContext.parse(self.allocator, object);

        try self.policy.addRule(.{
            .subject = subj,
            .object = obj,
            .operation = operation,
            .decision = .allow,
        });

        return self;
    }

    /// Deny operation
    pub fn deny(
        self: *PolicyBuilder,
        subject: []const u8,
        object: []const u8,
        operation: Operation,
    ) !*PolicyBuilder {
        const subj = try SecurityContext.parse(self.allocator, subject);
        const obj = try SecurityContext.parse(self.allocator, object);

        try self.policy.addRule(.{
            .subject = subj,
            .object = obj,
            .operation = operation,
            .decision = .deny,
        });

        return self;
    }

    pub fn build(self: *PolicyBuilder) *Policy {
        return self.policy;
    }
};

test "policy rule matching" {
    const testing = std.testing;

    var subject = try SecurityContext.create(testing.allocator, "user_u", "user_r", "user_t", "s0");
    defer subject.deinit(testing.allocator);

    var object = try SecurityContext.create(testing.allocator, "system_u", "object_r", "file_t", "s0");
    defer object.deinit(testing.allocator);

    const rule = Rule{
        .subject = subject,
        .object = object,
        .operation = .read,
        .decision = .allow,
    };

    try testing.expect(rule.matches(subject, object, .read));
    try testing.expect(!rule.matches(subject, object, .write));
}

test "policy evaluation" {
    const testing = std.testing;

    var policy = try Policy.init(testing.allocator);
    defer policy.deinit();

    const subject = try SecurityContext.create(testing.allocator, "user_u", "user_r", "user_t", "s0");
    const object = try SecurityContext.create(testing.allocator, "system_u", "object_r", "file_t", "s0");

    try policy.addRule(.{
        .subject = subject,
        .object = object,
        .operation = .read,
        .decision = .allow,
    });

    const decision = policy.evaluate(subject, object, .read);
    try testing.expectEqual(Decision.allow, decision);

    const denied = policy.evaluate(subject, object, .write);
    try testing.expectEqual(Decision.deny, denied);
}

test "policy builder" {
    const testing = std.testing;

    var builder = try PolicyBuilder.init(testing.allocator);
    _ = try builder.allow("user_u:user_r:user_t:s0", "system_u:object_r:file_t:s0", .read);
    _ = try builder.deny("guest_u:guest_r:guest_t:s0", "*:*:sensitive_t:*", .read);

    const pol = builder.build();
    defer pol.deinit();

    try testing.expectEqual(@as(usize, 2), pol.count());
}
