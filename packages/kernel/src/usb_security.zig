// Home OS Kernel - USB Security
// Device authorization and BadUSB protection

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");

pub const UsbDeviceClass = enum(u8) {
    HID = 0x03,        // Human Interface Device
    STORAGE = 0x08,    // Mass Storage
    HUB = 0x09,        // Hub
    VENDOR = 0xFF,     // Vendor Specific
    _,
};

pub const AuthorizationPolicy = enum(u8) {
    ALLOW_ALL = 0,
    ALLOW_KNOWN = 1,
    DENY_ALL = 2,
};

pub const UsbDevice = struct {
    /// Vendor ID
    vendor_id: u16,
    /// Product ID
    product_id: u16,
    /// Device class
    device_class: u8,
    /// Serial number
    serial: [64]u8,
    /// Serial length
    serial_len: usize,
    /// Authorized flag
    authorized: atomic.AtomicBool,
    /// Trusted flag
    trusted: bool,

    pub fn init(vendor_id: u16, product_id: u16, device_class: u8) UsbDevice {
        return .{
            .vendor_id = vendor_id,
            .product_id = product_id,
            .device_class = device_class,
            .serial = [_]u8{0} ** 64,
            .serial_len = 0,
            .authorized = atomic.AtomicBool.init(false),
            .trusted = false,
        };
    }

    pub fn setSerial(self: *UsbDevice, serial: []const u8) !void {
        if (serial.len > 63) {
            return error.SerialTooLong;
        }

        self.serial_len = serial.len;
        @memcpy(self.serial[0..serial.len], serial);
    }

    pub fn authorize(self: *UsbDevice) void {
        self.authorized.store(true, .Release);
        audit.logSecurityViolation("USB device authorized");
    }

    pub fn deauthorize(self: *UsbDevice) void {
        self.authorized.store(false, .Release);
        audit.logSecurityViolation("USB device deauthorized");
    }

    pub fn isAuthorized(self: *const UsbDevice) bool {
        return self.authorized.load(.Acquire);
    }
};

pub const UsbAuthority = struct {
    /// Authorization policy
    policy: atomic.AtomicU8,
    /// Allowed devices
    allowed_devices: [64]?UsbDevice,
    /// Device count
    device_count: atomic.AtomicU32,
    /// Lock
    lock: sync.RwLock,
    /// Block HID by default (BadUSB protection)
    block_hid: atomic.AtomicBool,

    pub fn init(policy: AuthorizationPolicy) UsbAuthority {
        return .{
            .policy = atomic.AtomicU8.init(@intFromEnum(policy)),
            .allowed_devices = [_]?UsbDevice{null} ** 64,
            .device_count = atomic.AtomicU32.init(0),
            .lock = sync.RwLock.init(),
            .block_hid = atomic.AtomicBool.init(false),
        };
    }

    pub fn setPolicy(self: *UsbAuthority, policy: AuthorizationPolicy) !void {
        if (!capabilities.hasCapability(.CAP_SYS_ADMIN)) {
            return error.PermissionDenied;
        }

        self.policy.store(@intFromEnum(policy), .Release);
    }

    pub fn authorizeDevice(self: *UsbAuthority, device: *UsbDevice) !void {
        const current_policy: AuthorizationPolicy = @enumFromInt(self.policy.load(.Acquire));

        switch (current_policy) {
            .ALLOW_ALL => device.authorize(),
            .ALLOW_KNOWN => {
                if (self.isKnownDevice(device)) {
                    device.authorize();
                } else {
                    return error.UnknownDevice;
                }
            },
            .DENY_ALL => return error.DeviceDenied,
        }

        // BadUSB protection - block unauthorized HID
        if (device.device_class == @intFromEnum(UsbDeviceClass.HID)) {
            if (self.block_hid.load(.Acquire) and !device.trusted) {
                device.deauthorize();
                audit.logSecurityViolation("BadUSB: HID device blocked");
                return error.HidBlocked;
            }
        }
    }

    pub fn addTrustedDevice(self: *UsbAuthority, device: UsbDevice) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const count = self.device_count.load(.Acquire);
        if (count >= 64) {
            return error.TooManyDevices;
        }

        self.allowed_devices[count] = device;
        _ = self.device_count.fetchAdd(1, .Release);
    }

    fn isKnownDevice(self: *UsbAuthority, device: *const UsbDevice) bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.allowed_devices) |maybe_dev| {
            if (maybe_dev) |known| {
                if (known.vendor_id == device.vendor_id and
                    known.product_id == device.product_id)
                {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn enableHidProtection(self: *UsbAuthority) void {
        self.block_hid.store(true, .Release);
        audit.logSecurityViolation("BadUSB protection enabled");
    }
};

var global_authority: UsbAuthority = undefined;
var usb_initialized = false;

pub fn init(policy: AuthorizationPolicy) void {
    if (!usb_initialized) {
        global_authority = UsbAuthority.init(policy);
        usb_initialized = true;
    }
}

pub fn getAuthority() *UsbAuthority {
    if (!usb_initialized) init(.ALLOW_KNOWN);
    return &global_authority;
}

test "usb device authorization" {
    var device = UsbDevice.init(0x1234, 0x5678, 0x03);

    try Basics.testing.expect(!device.isAuthorized());

    device.authorize();
    try Basics.testing.expect(device.isAuthorized());
}

test "usb authority policy" {
    var authority = UsbAuthority.init(.ALLOW_ALL);
    var device = UsbDevice.init(0x1234, 0x5678, 0x08);

    try authority.authorizeDevice(&device);
    try Basics.testing.expect(device.isAuthorized());
}

test "usb badusb protection" {
    var authority = UsbAuthority.init(.ALLOW_ALL);
    authority.enableHidProtection();

    var hid_device = UsbDevice.init(0x1234, 0x5678, @intFromEnum(UsbDeviceClass.HID));

    const result = authority.authorizeDevice(&hid_device);
    try Basics.testing.expect(result == error.HidBlocked);
}
