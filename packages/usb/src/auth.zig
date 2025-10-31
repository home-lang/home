// USB Device Authentication
// Provides whitelist/blacklist management and device authorization

const std = @import("std");
const usb = @import("usb.zig");

/// Device authorization mode
pub const AuthMode = enum {
    allow_all, // Allow all devices (insecure)
    deny_all, // Deny all devices (maximum security)
    whitelist, // Only allow whitelisted devices
    blacklist, // Allow all except blacklisted devices
};

/// Device authorization rule
pub const AuthRule = struct {
    device_id: usb.DeviceID,
    allowed: bool,
    reason: [256]u8,
    reason_len: usize,
    created_at: i64,

    pub fn init(device_id: usb.DeviceID, allowed: bool, reason: []const u8) AuthRule {
        var rule: AuthRule = undefined;
        rule.device_id = device_id;
        rule.allowed = allowed;
        rule.created_at = std.time.timestamp();

        @memset(&rule.reason, 0);
        @memcpy(rule.reason[0..reason.len], reason);
        rule.reason_len = reason.len;

        return rule;
    }

    pub fn getReason(self: *const AuthRule) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

/// USB device authenticator
pub const Authenticator = struct {
    mode: AuthMode,
    whitelist: std.ArrayList(usb.DeviceID),
    blacklist: std.ArrayList(usb.DeviceID),
    rules: std.ArrayList(AuthRule),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, mode: AuthMode) Authenticator {
        return .{
            .mode = mode,
            .whitelist = std.ArrayList(usb.DeviceID){},
            .blacklist = std.ArrayList(usb.DeviceID){},
            .rules = std.ArrayList(AuthRule){},
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Authenticator) void {
        self.whitelist.deinit(self.allocator);
        self.blacklist.deinit(self.allocator);
        self.rules.deinit(self.allocator);
    }

    pub fn addToWhitelist(self: *Authenticator, device: usb.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already in whitelist
        for (self.whitelist.items) |*dev| {
            if (dev.eql(&device)) return;
        }

        try self.whitelist.append(self.allocator, device);

        // Add rule
        const rule = AuthRule.init(device, true, "Whitelisted device");
        try self.rules.append(self.allocator, rule);
    }

    pub fn addToBlacklist(self: *Authenticator, device: usb.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already in blacklist
        for (self.blacklist.items) |*dev| {
            if (dev.eql(&device)) return;
        }

        try self.blacklist.append(self.allocator, device);

        // Add rule
        const rule = AuthRule.init(device, false, "Blacklisted device");
        try self.rules.append(self.allocator, rule);
    }

    pub fn removeFromWhitelist(self: *Authenticator, device: *const usb.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.whitelist.items.len) {
            if (self.whitelist.items[i].eql(device)) {
                _ = self.whitelist.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn removeFromBlacklist(self: *Authenticator, device: *const usb.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.blacklist.items.len) {
            if (self.blacklist.items[i].eql(device)) {
                _ = self.blacklist.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn isAuthorized(self: *Authenticator, device: *const usb.DeviceID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return switch (self.mode) {
            .allow_all => true,
            .deny_all => false,
            .whitelist => blk: {
                for (self.whitelist.items) |*dev| {
                    if (dev.eql(device)) break :blk true;
                }
                break :blk false;
            },
            .blacklist => blk: {
                for (self.blacklist.items) |*dev| {
                    if (dev.eql(device)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    pub fn setMode(self: *Authenticator, mode: AuthMode) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.mode = mode;
    }

    pub fn getWhitelistCount(self: *Authenticator) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.whitelist.items.len;
    }

    pub fn getBlacklistCount(self: *Authenticator) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.blacklist.items.len;
    }
};

test "whitelist authorization" {
    const testing = std.testing;

    var auth = Authenticator.init(testing.allocator, .whitelist);
    defer auth.deinit();

    const dev1 = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");
    const dev2 = usb.DeviceID.init(0x05AC, 0x8242, "67890", .hid, "Apple", "Keyboard");

    // Initially, nothing is authorized
    try testing.expect(!auth.isAuthorized(&dev1));
    try testing.expect(!auth.isAuthorized(&dev2));

    // Add dev1 to whitelist
    try auth.addToWhitelist(dev1);

    // Now dev1 is authorized but dev2 is not
    try testing.expect(auth.isAuthorized(&dev1));
    try testing.expect(!auth.isAuthorized(&dev2));
}

test "blacklist authorization" {
    const testing = std.testing;

    var auth = Authenticator.init(testing.allocator, .blacklist);
    defer auth.deinit();

    const dev1 = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");
    const dev2 = usb.DeviceID.init(0x05AC, 0x8242, "67890", .hid, "Apple", "Keyboard");

    // Initially, all devices are authorized
    try testing.expect(auth.isAuthorized(&dev1));
    try testing.expect(auth.isAuthorized(&dev2));

    // Add dev1 to blacklist
    try auth.addToBlacklist(dev1);

    // Now dev1 is denied but dev2 is authorized
    try testing.expect(!auth.isAuthorized(&dev1));
    try testing.expect(auth.isAuthorized(&dev2));
}

test "mode switching" {
    const testing = std.testing;

    var auth = Authenticator.init(testing.allocator, .allow_all);
    defer auth.deinit();

    const dev = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");

    // allow_all mode
    try testing.expect(auth.isAuthorized(&dev));

    // Switch to deny_all
    auth.setMode(.deny_all);
    try testing.expect(!auth.isAuthorized(&dev));

    // Switch to whitelist
    auth.setMode(.whitelist);
    try testing.expect(!auth.isAuthorized(&dev));

    // Add to whitelist
    try auth.addToWhitelist(dev);
    try testing.expect(auth.isAuthorized(&dev));
}
