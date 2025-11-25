// Security Context - SELinux-style security labels
// Format: user:role:type:level

const std = @import("std");

/// Security context components (similar to SELinux)
pub const SecurityContext = struct {
    user: []const u8, // Security user (e.g., "system_u", "user_u")
    role: []const u8, // Security role (e.g., "system_r", "user_r")
    type_label: []const u8, // Type/domain (e.g., "httpd_t", "user_t")
    level: []const u8, // MLS/MCS level (e.g., "s0", "s0-s0:c0.c1023")

    /// Parse security context from string (user:role:type:level)
    pub fn parse(allocator: std.mem.Allocator, context_str: []const u8) !SecurityContext {
        var parts = std.mem.splitScalar(u8, context_str, ':');

        const user = parts.next() orelse return error.InvalidContext;
        const role = parts.next() orelse return error.InvalidContext;
        const type_label = parts.next() orelse return error.InvalidContext;
        const level = parts.next() orelse "s0"; // Default level

        return .{
            .user = try allocator.dupe(u8, user),
            .role = try allocator.dupe(u8, role),
            .type_label = try allocator.dupe(u8, type_label),
            .level = try allocator.dupe(u8, level),
        };
    }

    /// Create a new security context
    pub fn create(
        allocator: std.mem.Allocator,
        user: []const u8,
        role: []const u8,
        type_label: []const u8,
        level: []const u8,
    ) !SecurityContext {
        return .{
            .user = try allocator.dupe(u8, user),
            .role = try allocator.dupe(u8, role),
            .type_label = try allocator.dupe(u8, type_label),
            .level = try allocator.dupe(u8, level),
        };
    }

    /// Format context as string (user:role:type:level)
    pub fn toString(self: SecurityContext, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{s}:{s}:{s}:{s}",
            .{ self.user, self.role, self.type_label, self.level },
        );
    }

    /// Free allocated memory
    pub fn deinit(self: *SecurityContext, allocator: std.mem.Allocator) void {
        allocator.free(self.user);
        allocator.free(self.role);
        allocator.free(self.type_label);
        allocator.free(self.level);
    }

    /// Check if two contexts match (wildcards supported)
    pub fn matches(self: SecurityContext, other: SecurityContext) bool {
        return (std.mem.eql(u8, self.user, "*") or std.mem.eql(u8, self.user, other.user)) and
            (std.mem.eql(u8, self.role, "*") or std.mem.eql(u8, self.role, other.role)) and
            (std.mem.eql(u8, self.type_label, "*") or std.mem.eql(u8, self.type_label, other.type_label)) and
            (std.mem.eql(u8, self.level, "*") or std.mem.eql(u8, self.level, other.level));
    }

    /// Clone a context
    pub fn clone(self: SecurityContext, allocator: std.mem.Allocator) !SecurityContext {
        return create(allocator, self.user, self.role, self.type_label, self.level);
    }
};

/// Common security contexts
pub const Contexts = struct {
    /// System context (highest privilege)
    pub fn system(allocator: std.mem.Allocator) !SecurityContext {
        return SecurityContext.create(allocator, "system_u", "system_r", "system_t", "s0");
    }

    /// User context (normal user)
    pub fn user(allocator: std.mem.Allocator) !SecurityContext {
        return SecurityContext.create(allocator, "user_u", "user_r", "user_t", "s0");
    }

    /// Guest context (restricted user)
    pub fn guest(allocator: std.mem.Allocator) !SecurityContext {
        return SecurityContext.create(allocator, "guest_u", "guest_r", "guest_t", "s0");
    }

    /// Service context (daemon/service)
    pub fn service(allocator: std.mem.Allocator, name: []const u8) !SecurityContext {
        const type_label = try std.fmt.allocPrint(allocator, "{s}_t", .{name});
        defer allocator.free(type_label);
        return SecurityContext.create(allocator, "system_u", "system_r", type_label, "s0");
    }

    /// Unconfined context (no restrictions)
    pub fn unconfined(allocator: std.mem.Allocator) !SecurityContext {
        return SecurityContext.create(allocator, "unconfined_u", "unconfined_r", "unconfined_t", "s0");
    }
};

/// Security level comparison for MLS (Multi-Level Security)
pub const Level = struct {
    sensitivity: u8,
    categories: std.AutoHashMap(u16, void),

    pub fn init(allocator: std.mem.Allocator) Level {
        return .{
            .sensitivity = 0,
            .categories = std.AutoHashMap(u16, void).init(allocator),
        };
    }

    pub fn deinit(self: *Level) void {
        self.categories.deinit();
    }

    /// Parse level string (e.g., "s0", "s0:c0.c3", "s0-s1:c0.c1023")
    pub fn parse(allocator: std.mem.Allocator, level_str: []const u8) !Level {
        var level = Level.init(allocator);

        // Extract sensitivity (e.g., "s0" -> 0)
        if (level_str.len > 0 and level_str[0] == 's') {
            if (level_str.len > 1) {
                level.sensitivity = level_str[1] - '0';
            }
        }

        // Parse categories (c0.c3 format means categories 0 through 3)
        // Format: s0:c0.c3 or s0:c0,c1,c5 or s0-s1:c0.c1023
        if (std.mem.indexOf(u8, level_str, ":c")) |cat_start| {
            const cat_str = level_str[cat_start + 2 ..];

            // Check for range format (c0.c3)
            if (std.mem.indexOf(u8, cat_str, ".c")) |range_sep| {
                const start_str = cat_str[0..range_sep];
                const end_str = cat_str[range_sep + 2 ..];

                // Find end of range (might have comma after)
                const end_idx = std.mem.indexOfScalar(u8, end_str, ',') orelse end_str.len;
                const end_val = end_str[0..end_idx];

                const start_cat = std.fmt.parseInt(u16, start_str, 10) catch 0;
                const end_cat = std.fmt.parseInt(u16, end_val, 10) catch start_cat;

                // Add all categories in range
                var cat = start_cat;
                while (cat <= end_cat) : (cat += 1) {
                    try level.categories.put(cat, {});
                }
            } else {
                // Parse comma-separated categories (c0,c1,c5)
                var cat_parts = std.mem.splitScalar(u8, cat_str, ',');
                while (cat_parts.next()) |part| {
                    if (part.len > 0 and part[0] == 'c') {
                        if (std.fmt.parseInt(u16, part[1..], 10)) |cat| {
                            try level.categories.put(cat, {});
                        } else |_| {}
                    }
                }
            }
        }

        return level;
    }

    /// Check if this level dominates another (for MLS enforcement)
    pub fn dominates(self: Level, other: Level) bool {
        if (self.sensitivity < other.sensitivity) return false;

        // Check if all of other's categories are in self's categories
        var iter = other.categories.keyIterator();
        while (iter.next()) |cat| {
            if (!self.categories.contains(cat.*)) return false;
        }

        return true;
    }
};

test "security context creation" {
    const testing = std.testing;

    var ctx = try SecurityContext.create(testing.allocator, "user_u", "user_r", "user_t", "s0");
    defer ctx.deinit(testing.allocator);

    try testing.expectEqualStrings("user_u", ctx.user);
    try testing.expectEqualStrings("user_r", ctx.role);
    try testing.expectEqualStrings("user_t", ctx.type_label);
    try testing.expectEqualStrings("s0", ctx.level);
}

test "security context parsing" {
    const testing = std.testing;

    var ctx = try SecurityContext.parse(testing.allocator, "system_u:system_r:httpd_t:s0");
    defer ctx.deinit(testing.allocator);

    try testing.expectEqualStrings("system_u", ctx.user);
    try testing.expectEqualStrings("system_r", ctx.role);
    try testing.expectEqualStrings("httpd_t", ctx.type_label);
    try testing.expectEqualStrings("s0", ctx.level);
}

test "security context matching" {
    const testing = std.testing;

    var ctx1 = try SecurityContext.create(testing.allocator, "user_u", "user_r", "user_t", "s0");
    defer ctx1.deinit(testing.allocator);

    var ctx2 = try SecurityContext.create(testing.allocator, "user_u", "user_r", "user_t", "s0");
    defer ctx2.deinit(testing.allocator);

    var ctx_wildcard = try SecurityContext.create(testing.allocator, "*", "*", "user_t", "*");
    defer ctx_wildcard.deinit(testing.allocator);

    try testing.expect(ctx1.matches(ctx2));
    try testing.expect(ctx_wildcard.matches(ctx1));
}

test "common contexts" {
    const testing = std.testing;

    var sys_ctx = try Contexts.system(testing.allocator);
    defer sys_ctx.deinit(testing.allocator);

    var user_ctx = try Contexts.user(testing.allocator);
    defer user_ctx.deinit(testing.allocator);

    try testing.expectEqualStrings("system_t", sys_ctx.type_label);
    try testing.expectEqualStrings("user_t", user_ctx.type_label);
}
