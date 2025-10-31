// USB Security for Home OS
// Provides device authentication, port control, and anti-BadUSB protection

const std = @import("std");

pub const auth = @import("auth.zig");
pub const policy = @import("policy.zig");
pub const monitor = @import("monitor.zig");
pub const badusb = @import("badusb.zig");

/// USB device class codes
pub const DeviceClass = enum(u8) {
    per_interface = 0x00,
    audio = 0x01,
    communications = 0x02,
    hid = 0x03, // Human Interface Device (keyboard, mouse)
    physical = 0x05,
    image = 0x06,
    printer = 0x07,
    mass_storage = 0x08, // USB drives
    hub = 0x09,
    cdc_data = 0x0A,
    smart_card = 0x0B,
    content_security = 0x0D,
    video = 0x0E,
    healthcare = 0x0F,
    audio_video = 0x10,
    billboard = 0x11,
    usb_type_c_bridge = 0x12,
    diagnostic = 0xDC,
    wireless = 0xE0,
    miscellaneous = 0xEF,
    application_specific = 0xFE,
    vendor_specific = 0xFF,
};

/// USB device identifier
pub const DeviceID = struct {
    vendor_id: u16,
    product_id: u16,
    serial: [256]u8,
    serial_len: usize,
    device_class: DeviceClass,
    manufacturer: [256]u8,
    manufacturer_len: usize,
    product: [256]u8,
    product_len: usize,

    pub fn init(
        vendor_id: u16,
        product_id: u16,
        serial: []const u8,
        device_class: DeviceClass,
        manufacturer: []const u8,
        product: []const u8,
    ) DeviceID {
        var dev: DeviceID = undefined;
        dev.vendor_id = vendor_id;
        dev.product_id = product_id;
        dev.device_class = device_class;

        @memset(&dev.serial, 0);
        @memcpy(dev.serial[0..serial.len], serial);
        dev.serial_len = serial.len;

        @memset(&dev.manufacturer, 0);
        @memcpy(dev.manufacturer[0..manufacturer.len], manufacturer);
        dev.manufacturer_len = manufacturer.len;

        @memset(&dev.product, 0);
        @memcpy(dev.product[0..product.len], product);
        dev.product_len = product.len;

        return dev;
    }

    pub fn getSerial(self: *const DeviceID) []const u8 {
        return self.serial[0..self.serial_len];
    }

    pub fn getManufacturer(self: *const DeviceID) []const u8 {
        return self.manufacturer[0..self.manufacturer_len];
    }

    pub fn getProduct(self: *const DeviceID) []const u8 {
        return self.product[0..self.product_len];
    }

    pub fn eql(self: *const DeviceID, other: *const DeviceID) bool {
        return self.vendor_id == other.vendor_id and
            self.product_id == other.product_id and
            std.mem.eql(u8, self.getSerial(), other.getSerial());
    }

    pub fn format(
        self: *const DeviceID,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s} {s} ({X:0>4}:{X:0>4}) [{}]", .{
            self.getManufacturer(),
            self.getProduct(),
            self.vendor_id,
            self.product_id,
            self.device_class,
        });
    }
};

/// USB device connection status
pub const DeviceStatus = enum {
    connected,
    authorized,
    denied,
    disconnected,
};

/// USB device information
pub const Device = struct {
    id: DeviceID,
    status: DeviceStatus,
    connect_time: i64,
    port_number: u8,

    pub fn init(id: DeviceID, port_number: u8) Device {
        return .{
            .id = id,
            .status = .connected,
            .connect_time = std.time.timestamp(),
            .port_number = port_number,
        };
    }
};

test "device ID" {
    const testing = std.testing;

    const dev = DeviceID.init(
        0x046D,
        0xC52B,
        "1234567890",
        .hid,
        "Logitech",
        "USB Receiver",
    );

    try testing.expectEqual(@as(u16, 0x046D), dev.vendor_id);
    try testing.expectEqual(@as(u16, 0xC52B), dev.product_id);
    try testing.expectEqualStrings("1234567890", dev.getSerial());
    try testing.expectEqualStrings("Logitech", dev.getManufacturer());
    try testing.expectEqualStrings("USB Receiver", dev.getProduct());
}

test "device equality" {
    const testing = std.testing;

    const dev1 = DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");
    const dev2 = DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");
    const dev3 = DeviceID.init(0x046D, 0xC52B, "67890", .hid, "Logitech", "Mouse");

    try testing.expect(dev1.eql(&dev2));
    try testing.expect(!dev1.eql(&dev3));
}
