// USB Policy Engine
// Port control, class-based restrictions, and security policies

const std = @import("std");
const usb = @import("usb.zig");

/// USB policy action
pub const PolicyAction = enum {
    allow,
    deny,
    prompt, // Ask user for authorization
    quarantine, // Allow but monitor closely
};

/// Policy enforcement level
pub const EnforcementLevel = enum {
    permissive, // Log violations but allow
    enforcing, // Block violations
    paranoid, // Strict enforcement with auditing
};

/// Device class policy
pub const ClassPolicy = struct {
    device_class: usb.DeviceClass,
    action: PolicyAction,
    max_devices: ?u32, // null = unlimited
    require_auth: bool,

    pub fn init(device_class: usb.DeviceClass, action: PolicyAction) ClassPolicy {
        return .{
            .device_class = device_class,
            .action = action,
            .max_devices = null,
            .require_auth = false,
        };
    }

    pub fn withMaxDevices(self: ClassPolicy, max: u32) ClassPolicy {
        var policy = self;
        policy.max_devices = max;
        return policy;
    }

    pub fn withAuthRequired(self: ClassPolicy) ClassPolicy {
        var policy = self;
        policy.require_auth = true;
        return policy;
    }
};

/// USB port status
pub const PortStatus = enum {
    enabled,
    disabled,
    auth_required,
};

/// USB port configuration
pub const Port = struct {
    number: u8,
    status: PortStatus,
    connected_device: ?usb.DeviceID,
    connection_count: u32,

    pub fn init(number: u8) Port {
        return .{
            .number = number,
            .status = .enabled,
            .connected_device = null,
            .connection_count = 0,
        };
    }
};

/// Policy engine
pub const PolicyEngine = struct {
    class_policies: std.AutoHashMap(usb.DeviceClass, ClassPolicy),
    ports: std.ArrayList(Port),
    enforcement: EnforcementLevel,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    class_device_count: std.AutoHashMap(usb.DeviceClass, u32),

    pub fn init(allocator: std.mem.Allocator, enforcement: EnforcementLevel) PolicyEngine {
        return .{
            .class_policies = std.AutoHashMap(usb.DeviceClass, ClassPolicy).init(allocator),
            .ports = std.ArrayList(Port){},
            .enforcement = enforcement,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .class_device_count = std.AutoHashMap(usb.DeviceClass, u32).init(allocator),
        };
    }

    pub fn deinit(self: *PolicyEngine) void {
        self.class_policies.deinit();
        self.ports.deinit(self.allocator);
        self.class_device_count.deinit();
    }

    pub fn addClassPolicy(self: *PolicyEngine, policy: ClassPolicy) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.class_policies.put(policy.device_class, policy);
    }

    pub fn addPort(self: *PolicyEngine, port: Port) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.ports.append(self.allocator, port);
    }

    pub fn getPortByNumber(self: *PolicyEngine, port_number: u8) ?*Port {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.ports.items) |*port| {
            if (port.number == port_number) return port;
        }
        return null;
    }

    pub fn disablePort(self: *PolicyEngine, port_number: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.ports.items) |*port| {
            if (port.number == port_number) {
                port.status = .disabled;
                port.connected_device = null;
                return;
            }
        }
        return error.PortNotFound;
    }

    pub fn enablePort(self: *PolicyEngine, port_number: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.ports.items) |*port| {
            if (port.number == port_number) {
                port.status = .enabled;
                return;
            }
        }
        return error.PortNotFound;
    }

    pub fn checkDevicePolicy(self: *PolicyEngine, device: *const usb.DeviceID) !PolicyAction {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get policy for this device class
        const policy = self.class_policies.get(device.device_class) orelse {
            // No specific policy, use default based on enforcement level
            return switch (self.enforcement) {
                .permissive => .allow,
                .enforcing => .prompt,
                .paranoid => .deny,
            };
        };

        // Check max devices limit
        if (policy.max_devices) |max| {
            const count = self.class_device_count.get(device.device_class) orelse 0;
            if (count >= max) {
                return .deny;
            }
        }

        return policy.action;
    }

    pub fn registerDevice(self: *PolicyEngine, device: *const usb.DeviceID, port_number: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update port
        for (self.ports.items) |*port| {
            if (port.number == port_number) {
                port.connected_device = device.*;
                port.connection_count += 1;
                break;
            }
        }

        // Update class count
        const count = self.class_device_count.get(device.device_class) orelse 0;
        try self.class_device_count.put(device.device_class, count + 1);
    }

    pub fn unregisterDevice(self: *PolicyEngine, device: *const usb.DeviceID, port_number: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update port
        for (self.ports.items) |*port| {
            if (port.number == port_number) {
                port.connected_device = null;
                break;
            }
        }

        // Update class count
        if (self.class_device_count.get(device.device_class)) |count| {
            if (count > 0) {
                try self.class_device_count.put(device.device_class, count - 1);
            }
        }
    }

    pub fn getClassDeviceCount(self: *PolicyEngine, device_class: usb.DeviceClass) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.class_device_count.get(device_class) orelse 0;
    }
};

test "class policy" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .enforcing);
    defer engine.deinit();

    // Add policy: deny all mass storage devices
    const policy = ClassPolicy.init(.mass_storage, .deny);
    try engine.addClassPolicy(policy);

    const usb_drive = usb.DeviceID.init(
        0x0781,
        0x5567,
        "12345",
        .mass_storage,
        "SanDisk",
        "Cruzer Blade",
    );

    const action = try engine.checkDevicePolicy(&usb_drive);
    try testing.expectEqual(PolicyAction.deny, action);
}

test "max devices limit" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .enforcing);
    defer engine.deinit();

    // Allow max 2 HID devices
    const policy = ClassPolicy.init(.hid, .allow).withMaxDevices(2);
    try engine.addClassPolicy(policy);

    const mouse = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");
    const keyboard = usb.DeviceID.init(0x05AC, 0x8242, "67890", .hid, "Apple", "Keyboard");
    const gamepad = usb.DeviceID.init(0x045E, 0x02EA, "ABCDE", .hid, "Microsoft", "Xbox Controller");

    // First two should be allowed
    try engine.registerDevice(&mouse, 1);
    try testing.expectEqual(@as(u32, 1), engine.getClassDeviceCount(.hid));

    try engine.registerDevice(&keyboard, 2);
    try testing.expectEqual(@as(u32, 2), engine.getClassDeviceCount(.hid));

    // Third should be denied
    const action = try engine.checkDevicePolicy(&gamepad);
    try testing.expectEqual(PolicyAction.deny, action);
}

test "port control" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .enforcing);
    defer engine.deinit();

    // Add ports
    try engine.addPort(Port.init(1));
    try engine.addPort(Port.init(2));

    // Disable port 2
    try engine.disablePort(2);

    const port1 = engine.getPortByNumber(1).?;
    const port2 = engine.getPortByNumber(2).?;

    try testing.expectEqual(PortStatus.enabled, port1.status);
    try testing.expectEqual(PortStatus.disabled, port2.status);

    // Enable port 2
    try engine.enablePort(2);
    try testing.expectEqual(PortStatus.enabled, port2.status);
}
