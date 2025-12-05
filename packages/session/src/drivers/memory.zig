const std = @import("std");
const posix = std.posix;
const session = @import("../session.zig");

/// Helper to get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// In-memory session driver (for development/testing)
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(StoredSession),

    const Self = @This();

    const StoredSession = struct {
        data: session.SessionData,
        expires_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .sessions = std.StringHashMap(StoredSession).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var data = entry.value_ptr.data;
            data.deinit();
        }
        self.sessions.deinit();
        self.allocator.destroy(self);
    }

    pub fn driver(self: *Self) session.SessionDriver {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn read(ptr: *anyopaque, id: []const u8) anyerror!?session.SessionData {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const stored = self.sessions.get(id) orelse return null;

        // Check expiration
        if (stored.expires_at < getTimestamp()) {
            // Expired, remove it
            if (self.sessions.fetchRemove(id)) |removed| {
                self.allocator.free(removed.key);
                var data = removed.value.data;
                data.deinit();
            }
            return null;
        }

        return stored.data;
    }

    fn write(ptr: *anyopaque, id: []const u8, data: session.SessionData) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Remove old entry if exists
        if (self.sessions.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
            var old_data = removed.value.data;
            old_data.deinit();
        }

        const id_copy = try self.allocator.dupe(u8, id);
        const data_copy = try data.clone(self.allocator);

        try self.sessions.put(id_copy, .{
            .data = data_copy,
            .expires_at = getTimestamp() + 7200, // 2 hour default
        });
    }

    fn destroy(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.sessions.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
            var data = removed.value.data;
            data.deinit();
        }
    }

    fn gc(ptr: *anyopaque, max_lifetime: i64) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const now = getTimestamp();
        const cutoff = now - max_lifetime;

        // Collect expired keys
        var expired_keys: [256][]const u8 = undefined;
        var expired_count: usize = 0;

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.data.last_activity < cutoff) {
                if (expired_count < expired_keys.len) {
                    expired_keys[expired_count] = entry.key_ptr.*;
                    expired_count += 1;
                }
            }
        }

        // Remove expired
        for (expired_keys[0..expired_count]) |key| {
            if (self.sessions.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                var data = removed.value.data;
                data.deinit();
            }
        }
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = session.SessionDriver.VTable{
        .read = read,
        .write = write,
        .destroy = destroy,
        .gc = gc,
        .deinit = deinitFn,
    };
};

// Tests
test "memory driver basic operations" {
    const allocator = std.testing.allocator;

    const drv = try MemoryDriver.init(allocator);
    defer drv.deinit();

    var d = drv.driver();

    // Create session data
    var data = session.SessionData.init(allocator);
    const key = try allocator.dupe(u8, "user_id");
    try data.data.put(key, .{ .int = 42 });

    // Write
    try d.write("test-session-id", data);
    data.deinit();

    // Read
    const read_data = try d.read("test-session-id");
    try std.testing.expect(read_data != null);

    const value = read_data.?.data.get("user_id");
    try std.testing.expect(value != null);
    try std.testing.expectEqual(@as(i64, 42), value.?.asInt().?);

    // Destroy
    try d.destroy("test-session-id");
    const destroyed = try d.read("test-session-id");
    try std.testing.expect(destroyed == null);
}
