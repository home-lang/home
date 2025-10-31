// Home OS - Enhanced Driver Support
// Core driver system with PCI, ACPI, graphics, and input device support

const std = @import("std");

// ============================================================================
// Public API Exports
// ============================================================================

// Core drivers
pub const pci = @import("pci.zig");
pub const acpi = @import("acpi.zig");
pub const graphics = @import("graphics.zig");
pub const input = @import("input.zig");

// Serial/console
pub const uart = @import("uart.zig");

// Storage
pub const nvme = @import("nvme.zig");
pub const ahci = @import("ahci.zig");
pub const block = @import("block.zig");

// Network
pub const e1000 = @import("e1000.zig");
pub const virtio_net = @import("virtio_net.zig");

// Framebuffer
pub const framebuffer = @import("framebuffer.zig");

// Time
pub const rtc = @import("rtc.zig");

// Device Tree / Platform
pub const dtb_parser = @import("dtb_parser.zig");

// Broadcom (Raspberry Pi)
pub const bcm_gpio = @import("bcm_gpio.zig");
pub const bcm_mailbox = @import("bcm_mailbox.zig");
pub const bcm_timer = @import("bcm_timer.zig");

// ============================================================================
// Driver Core Types
// ============================================================================

pub const DriverType = enum {
    pci,
    acpi,
    graphics,
    input,
    storage,
    network,
    usb,
    custom,
};

pub const DriverError = error{
    NotFound,
    NotSupported,
    AlreadyInitialized,
    InitializationFailed,
    InvalidConfiguration,
    DeviceNotReady,
    IoError,
    OutOfMemory,
};

pub const DriverState = enum {
    uninitialized,
    initializing,
    ready,
    suspended,
    error_state,
};

// ============================================================================
// Driver Interface
// ============================================================================

pub const Driver = struct {
    name: []const u8,
    driver_type: DriverType,
    version: Version,
    state: DriverState,
    vtable: *const VTable,
    context: *anyopaque,

    pub const Version = struct {
        major: u16,
        minor: u16,
        patch: u16,

        pub fn format(
            self: Version,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        }
    };

    pub const VTable = struct {
        init: *const fn (ctx: *anyopaque) DriverError!void,
        deinit: *const fn (ctx: *anyopaque) void,
        suspend_fn: ?*const fn (ctx: *anyopaque) DriverError!void = null,
        resume_fn: ?*const fn (ctx: *anyopaque) DriverError!void = null,
        ioctl: ?*const fn (ctx: *anyopaque, command: u32, arg: usize) DriverError!usize = null,
    };

    pub fn init(self: *Driver) DriverError!void {
        if (self.state != .uninitialized) {
            return DriverError.AlreadyInitialized;
        }
        self.state = .initializing;
        try self.vtable.init(self.context);
        self.state = .ready;
    }

    pub fn deinit(self: *Driver) void {
        self.vtable.deinit(self.context);
        self.state = .uninitialized;
    }

    pub fn suspendDriver(self: *Driver) DriverError!void {
        if (self.vtable.suspend_fn) |suspend_callback| {
            try suspend_callback(self.context);
            self.state = .suspended;
        }
    }

    pub fn resumeDriver(self: *Driver) DriverError!void {
        if (self.vtable.resume_fn) |resume_callback| {
            try resume_callback(self.context);
            self.state = .ready;
        }
    }

    pub fn ioctl(self: *Driver, command: u32, arg: usize) DriverError!usize {
        if (self.vtable.ioctl) |ioctl_fn| {
            return ioctl_fn(self.context, command, arg);
        }
        return DriverError.NotSupported;
    }
};

// ============================================================================
// Driver Registry
// ============================================================================

pub const DriverRegistry = struct {
    drivers: std.ArrayList(*Driver),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) DriverRegistry {
        return .{
            .drivers = std.ArrayList(*Driver).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *DriverRegistry) void {
        self.drivers.deinit();
    }

    pub fn register(self: *DriverRegistry, driver: *Driver) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if driver already registered
        for (self.drivers.items) |d| {
            if (std.mem.eql(u8, d.name, driver.name)) {
                return DriverError.AlreadyInitialized;
            }
        }

        try self.drivers.append(driver);
        try driver.init();
    }

    pub fn unregister(self: *DriverRegistry, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.drivers.items, 0..) |driver, i| {
            if (std.mem.eql(u8, driver.name, name)) {
                driver.deinit();
                _ = self.drivers.orderedRemove(i);
                return;
            }
        }

        return DriverError.NotFound;
    }

    pub fn find(self: *DriverRegistry, name: []const u8) ?*Driver {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.drivers.items) |driver| {
            if (std.mem.eql(u8, driver.name, name)) {
                return driver;
            }
        }

        return null;
    }

    pub fn findByType(self: *DriverRegistry, driver_type: DriverType) []*Driver {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(*Driver).init(self.allocator);
        for (self.drivers.items) |driver| {
            if (driver.driver_type == driver_type) {
                result.append(driver) catch break;
            }
        }

        return result.toOwnedSlice() catch &[_]*Driver{};
    }
};

// ============================================================================
// Device Types
// ============================================================================

pub const Device = struct {
    name: []const u8,
    device_id: u64,
    vendor_id: u32,
    driver: ?*Driver,

    pub fn attachDriver(self: *Device, driver: *Driver) !void {
        if (self.driver != null) {
            return DriverError.AlreadyInitialized;
        }
        self.driver = driver;
    }

    pub fn detachDriver(self: *Device) void {
        self.driver = null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "driver version formatting" {
    const testing = std.testing;

    const version = Driver.Version{ .major = 1, .minor = 2, .patch = 3 };

    var buf: [32]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{}", .{version});
    try testing.expect(std.mem.eql(u8, "1.2.3", str));
}

test "driver registry" {
    const testing = std.testing;

    var registry = DriverRegistry.init(testing.allocator);
    defer registry.deinit();

    // Create a dummy driver
    const DummyContext = struct {
        initialized: bool = false,
    };

    const dummy_vtable = Driver.VTable{
        .init = struct {
            fn init(ctx: *anyopaque) DriverError!void {
                const context: *DummyContext = @ptrCast(@alignCast(ctx));
                context.initialized = true;
            }
        }.init,
        .deinit = struct {
            fn deinit(ctx: *anyopaque) void {
                const context: *DummyContext = @ptrCast(@alignCast(ctx));
                context.initialized = false;
            }
        }.deinit,
    };

    var dummy_ctx = DummyContext{};
    var dummy_driver = Driver{
        .name = "dummy",
        .driver_type = .custom,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .state = .uninitialized,
        .vtable = &dummy_vtable,
        .context = &dummy_ctx,
    };

    // Register driver
    try registry.register(&dummy_driver);
    try testing.expect(dummy_ctx.initialized);
    try testing.expectEqual(DriverState.ready, dummy_driver.state);

    // Find driver
    const found = registry.find("dummy");
    try testing.expect(found != null);
    try testing.expect(std.mem.eql(u8, found.?.name, "dummy"));

    // Unregister driver
    try registry.unregister("dummy");
    try testing.expect(!dummy_ctx.initialized);

    const not_found = registry.find("dummy");
    try testing.expect(not_found == null);
}
