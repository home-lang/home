// Access control for syslog

const std = @import("std");
const syslog = @import("syslog.zig");

/// Access control permission
pub const Permission = enum {
    read,
    write,
    admin,
};

/// Access control entry
pub const ACL = struct {
    user_id: u32,
    facility: ?syslog.Facility, // null = all facilities
    min_severity: syslog.Severity,
    permissions: std.EnumSet(Permission),

    pub fn allows(self: *const ACL, perm: Permission) bool {
        return self.permissions.contains(perm);
    }

    pub fn canRead(self: *const ACL, facility: syslog.Facility, severity: syslog.Severity) bool {
        if (!self.allows(.read)) return false;

        // Check facility filter
        if (self.facility) |allowed_facility| {
            if (facility != allowed_facility) return false;
        }

        // Check severity filter (only show min_severity and higher priority)
        if (@intFromEnum(severity) > @intFromEnum(self.min_severity)) {
            return false;
        }

        return true;
    }
};

/// Access control list manager
pub const AccessControl = struct {
    acls: std.ArrayList(ACL),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AccessControl {
        return .{
            .acls = std.ArrayList(ACL){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AccessControl) void {
        self.acls.deinit(self.allocator);
    }

    pub fn addACL(self: *AccessControl, acl: ACL) !void {
        try self.acls.append(self.allocator, acl);
    }

    pub fn checkPermission(
        self: *const AccessControl,
        user_id: u32,
        perm: Permission,
    ) bool {
        for (self.acls.items) |*acl| {
            if (acl.user_id == user_id and acl.allows(perm)) {
                return true;
            }
        }
        return false;
    }

    pub fn canReadLog(
        self: *const AccessControl,
        user_id: u32,
        message: *const syslog.LogMessage,
    ) bool {
        for (self.acls.items) |*acl| {
            if (acl.user_id == user_id) {
                if (acl.canRead(message.facility, message.severity)) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn filterLogs(
        self: *const AccessControl,
        user_id: u32,
        messages: []const syslog.LogMessage,
        allocator: std.mem.Allocator,
    ) ![]syslog.LogMessage {
        var filtered = std.ArrayList(syslog.LogMessage){};
        defer filtered.deinit(allocator);

        for (messages) |*msg| {
            if (self.canReadLog(user_id, msg)) {
                try filtered.append(allocator, msg.*);
            }
        }

        return filtered.toOwnedSlice(allocator);
    }
};

/// Pre-defined roles
pub const Role = enum {
    admin,
    operator,
    auditor,
    user,

    pub fn getACL(self: Role, user_id: u32) ACL {
        return switch (self) {
            .admin => .{
                .user_id = user_id,
                .facility = null,
                .min_severity = .debug,
                .permissions = std.EnumSet(Permission).init(.{
                    .read = true,
                    .write = true,
                    .admin = true,
                }),
            },
            .operator => .{
                .user_id = user_id,
                .facility = null,
                .min_severity = .info,
                .permissions = std.EnumSet(Permission).init(.{
                    .read = true,
                    .write = true,
                    .admin = false,
                }),
            },
            .auditor => .{
                .user_id = user_id,
                .facility = null,
                .min_severity = .notice,
                .permissions = std.EnumSet(Permission).init(.{
                    .read = true,
                    .write = false,
                    .admin = false,
                }),
            },
            .user => .{
                .user_id = user_id,
                .facility = .user,
                .min_severity = .notice,
                .permissions = std.EnumSet(Permission).init(.{
                    .read = true,
                    .write = false,
                    .admin = false,
                }),
            },
        };
    }
};

test "acl permissions" {
    const testing = std.testing;

    const admin_acl = Role.admin.getACL(1000);
    try testing.expect(admin_acl.allows(.read));
    try testing.expect(admin_acl.allows(.write));
    try testing.expect(admin_acl.allows(.admin));

    const auditor_acl = Role.auditor.getACL(2000);
    try testing.expect(auditor_acl.allows(.read));
    try testing.expect(!auditor_acl.allows(.write));
    try testing.expect(!auditor_acl.allows(.admin));
}

test "access control" {
    const testing = std.testing;

    var ac = AccessControl.init(testing.allocator);
    defer ac.deinit();

    // Add admin ACL
    try ac.addACL(Role.admin.getACL(1000));

    // Add regular user ACL
    try ac.addACL(Role.user.getACL(2000));

    // Admin can read
    try testing.expect(ac.checkPermission(1000, .read));
    try testing.expect(ac.checkPermission(1000, .admin));

    // User cannot admin
    try testing.expect(ac.checkPermission(2000, .read));
    try testing.expect(!ac.checkPermission(2000, .admin));
}

test "log filtering" {
    const testing = std.testing;

    var ac = AccessControl.init(testing.allocator);
    defer ac.deinit();

    // User can only see .user facility
    try ac.addACL(Role.user.getACL(2000));

    var msg1 = try syslog.LogMessage.init(
        testing.allocator,
        .user,
        .info,
        "host",
        "app",
        1,
        "User message",
    );
    defer msg1.deinit();

    var msg2 = try syslog.LogMessage.init(
        testing.allocator,
        .daemon,
        .info,
        "host",
        "app",
        2,
        "Daemon message",
    );
    defer msg2.deinit();

    // User can read user facility
    try testing.expect(ac.canReadLog(2000, &msg1));

    // User cannot read daemon facility
    try testing.expect(!ac.canReadLog(2000, &msg2));
}
