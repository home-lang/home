// Home Programming Language - USB Subsystem
// Universal Serial Bus infrastructure

const Basics = @import("basics");
const sync = @import("sync");

// ============================================================================
// USB Device Descriptors
// ============================================================================

pub const UsbDeviceDescriptor = extern struct {
    b_length: u8,
    b_descriptor_type: u8,
    bcd_usb: u16,
    b_device_class: u8,
    b_device_sub_class: u8,
    b_device_protocol: u8,
    b_max_packet_size0: u8,
    id_vendor: u16,
    id_product: u16,
    bcd_device: u16,
    i_manufacturer: u8,
    i_product: u8,
    i_serial_number: u8,
    b_num_configurations: u8,
};

pub const UsbConfigDescriptor = extern struct {
    b_length: u8,
    b_descriptor_type: u8,
    w_total_length: u16,
    b_num_interfaces: u8,
    b_configuration_value: u8,
    i_configuration: u8,
    bm_attributes: u8,
    b_max_power: u8,
};

pub const UsbInterfaceDescriptor = extern struct {
    b_length: u8,
    b_descriptor_type: u8,
    b_interface_number: u8,
    b_alternate_setting: u8,
    b_num_endpoints: u8,
    b_interface_class: u8,
    b_interface_sub_class: u8,
    b_interface_protocol: u8,
    i_interface: u8,
};

pub const UsbEndpointDescriptor = extern struct {
    b_length: u8,
    b_descriptor_type: u8,
    b_endpoint_address: u8,
    bm_attributes: u8,
    w_max_packet_size: u16,
    b_interval: u8,

    pub fn getDirection(self: *const UsbEndpointDescriptor) EndpointDirection {
        return if ((self.b_endpoint_address & 0x80) != 0) .In else .Out;
    }

    pub fn getNumber(self: *const UsbEndpointDescriptor) u8 {
        return self.b_endpoint_address & 0x0F;
    }

    pub fn getType(self: *const UsbEndpointDescriptor) EndpointType {
        return @enumFromInt(self.bm_attributes & 0x03);
    }
};

// ============================================================================
// USB Device Classes
// ============================================================================

pub const UsbClass = enum(u8) {
    PerInterface = 0x00,
    Audio = 0x01,
    Comm = 0x02,
    HID = 0x03,
    Physical = 0x05,
    Image = 0x06,
    Printer = 0x07,
    MassStorage = 0x08,
    Hub = 0x09,
    CDCData = 0x0A,
    SmartCard = 0x0B,
    ContentSecurity = 0x0D,
    Video = 0x0E,
    PersonalHealthcare = 0x0F,
    AudioVideo = 0x10,
    Diagnostic = 0xDC,
    Wireless = 0xE0,
    Miscellaneous = 0xEF,
    ApplicationSpecific = 0xFE,
    VendorSpecific = 0xFF,
    _,
};

pub const EndpointDirection = enum {
    Out,
    In,
};

pub const EndpointType = enum(u2) {
    Control = 0,
    Isochronous = 1,
    Bulk = 2,
    Interrupt = 3,
};

// ============================================================================
// USB Request Types and Codes
// ============================================================================

pub const UsbRequestType = packed struct(u8) {
    recipient: u5,
    request_type: u2,
    direction: u1,
};

pub const UsbRequest = enum(u8) {
    GetStatus = 0,
    ClearFeature = 1,
    SetFeature = 3,
    SetAddress = 5,
    GetDescriptor = 6,
    SetDescriptor = 7,
    GetConfiguration = 8,
    SetConfiguration = 9,
    GetInterface = 10,
    SetInterface = 11,
    SynchFrame = 12,
    _,
};

pub const UsbDescriptorType = enum(u8) {
    Device = 1,
    Configuration = 2,
    String = 3,
    Interface = 4,
    Endpoint = 5,
    DeviceQualifier = 6,
    OtherSpeedConfig = 7,
    InterfacePower = 8,
    _,
};

pub const UsbSetupPacket = extern struct {
    bm_request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,

    pub fn init(request_type: UsbRequestType, request: UsbRequest, value: u16, index: u16, length: u16) UsbSetupPacket {
        return .{
            .bm_request_type = @bitCast(request_type),
            .b_request = @intFromEnum(request),
            .w_value = value,
            .w_index = index,
            .w_length = length,
        };
    }
};

// ============================================================================
// USB Transfer Request Block (URB)
// ============================================================================

pub const UrbStatus = enum {
    Pending,
    Completed,
    Error,
    Stalled,
    Timeout,
};

pub const Urb = struct {
    device: *UsbDevice,
    endpoint: u8,
    transfer_type: EndpointType,
    direction: EndpointDirection,
    buffer: []u8,
    actual_length: usize,
    status: UrbStatus,
    callback: ?*const fn (*Urb) void,
    context: ?*anyopaque,

    pub fn init(device: *UsbDevice, endpoint: u8, transfer_type: EndpointType, direction: EndpointDirection, buffer: []u8) Urb {
        return .{
            .device = device,
            .endpoint = endpoint,
            .transfer_type = transfer_type,
            .direction = direction,
            .buffer = buffer,
            .actual_length = 0,
            .status = .Pending,
            .callback = null,
            .context = null,
        };
    }

    pub fn complete(self: *Urb, status: UrbStatus, actual_length: usize) void {
        self.status = status;
        self.actual_length = actual_length;

        if (self.callback) |cb| {
            cb(self);
        }
    }
};

// ============================================================================
// USB Device
// ============================================================================

pub const UsbDeviceState = enum {
    Attached,
    Powered,
    Default,
    Addressed,
    Configured,
};

pub const UsbDevice = struct {
    address: u8,
    state: UsbDeviceState,
    speed: UsbSpeed,
    device_descriptor: UsbDeviceDescriptor,
    config_descriptor: ?*UsbConfigDescriptor,
    controller: *UsbController,
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    pub fn init(allocator: Basics.Allocator, controller: *UsbController, speed: UsbSpeed) !*UsbDevice {
        const device = try allocator.create(UsbDevice);
        device.* = .{
            .address = 0,
            .state = .Attached,
            .speed = speed,
            .device_descriptor = undefined,
            .config_descriptor = null,
            .controller = controller,
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
        return device;
    }

    pub fn deinit(self: *UsbDevice) void {
        if (self.config_descriptor) |config| {
            self.allocator.destroy(config);
        }
        self.allocator.destroy(self);
    }

    pub fn controlTransfer(self: *UsbDevice, setup: UsbSetupPacket, buffer: []u8) !usize {
        var urb = Urb.init(self, 0, .Control, if (setup.bm_request_type & 0x80 != 0) .In else .Out, buffer);

        // Submit to controller
        try self.controller.submitUrb(&urb);

        // Wait for completion (simplified - should use proper synchronization)
        while (urb.status == .Pending) {
            // TODO: Sleep/yield
        }

        if (urb.status != .Completed) {
            return error.TransferFailed;
        }

        return urb.actual_length;
    }

    pub fn getDeviceDescriptor(self: *UsbDevice) !void {
        const setup = UsbSetupPacket.init(
            .{ .recipient = 0, .request_type = 0, .direction = 1 },
            .GetDescriptor,
            (@as(u16, @intFromEnum(UsbDescriptorType.Device)) << 8) | 0,
            0,
            @sizeOf(UsbDeviceDescriptor),
        );

        var buffer: [@sizeOf(UsbDeviceDescriptor)]u8 = undefined;
        const len = try self.controlTransfer(setup, &buffer);

        if (len < @sizeOf(UsbDeviceDescriptor)) {
            return error.InvalidDescriptor;
        }

        self.device_descriptor = @as(*const UsbDeviceDescriptor, @ptrCast(@alignCast(&buffer))).*;
    }

    pub fn setAddress(self: *UsbDevice, address: u8) !void {
        const setup = UsbSetupPacket.init(
            .{ .recipient = 0, .request_type = 0, .direction = 0 },
            .SetAddress,
            address,
            0,
            0,
        );

        _ = try self.controlTransfer(setup, &[_]u8{});

        self.address = address;
        self.state = .Addressed;
    }

    pub fn setConfiguration(self: *UsbDevice, config_value: u8) !void {
        const setup = UsbSetupPacket.init(
            .{ .recipient = 0, .request_type = 0, .direction = 0 },
            .SetConfiguration,
            config_value,
            0,
            0,
        );

        _ = try self.controlTransfer(setup, &[_]u8{});

        self.state = .Configured;
    }
};

// ============================================================================
// USB Speed
// ============================================================================

pub const UsbSpeed = enum {
    Low, // 1.5 Mbps
    Full, // 12 Mbps
    High, // 480 Mbps
    Super, // 5 Gbps
    SuperPlus, // 10 Gbps
};

// ============================================================================
// USB Controller Interface
// ============================================================================

pub const UsbController = struct {
    name: []const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        submitUrb: *const fn (controller: *UsbController, urb: *Urb) anyerror!void,
        cancelUrb: *const fn (controller: *UsbController, urb: *Urb) anyerror!void,
        reset: *const fn (controller: *UsbController) anyerror!void,
    };

    pub fn submitUrb(self: *UsbController, urb: *Urb) !void {
        return self.vtable.submitUrb(self, urb);
    }

    pub fn cancelUrb(self: *UsbController, urb: *Urb) !void {
        return self.vtable.cancelUrb(self, urb);
    }

    pub fn reset(self: *UsbController) !void {
        return self.vtable.reset(self);
    }
};

// ============================================================================
// USB Hub
// ============================================================================

pub const UsbHub = struct {
    device: *UsbDevice,
    num_ports: u8,
    ports: []UsbHubPort,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, device: *UsbDevice, num_ports: u8) !*UsbHub {
        const hub = try allocator.create(UsbHub);
        const ports = try allocator.alloc(UsbHubPort, num_ports);

        for (ports, 0..) |*port, i| {
            port.* = UsbHubPort{
                .number = @intCast(i + 1),
                .status = .Disconnected,
                .device = null,
            };
        }

        hub.* = .{
            .device = device,
            .num_ports = num_ports,
            .ports = ports,
            .allocator = allocator,
        };

        return hub;
    }

    pub fn deinit(self: *UsbHub) void {
        self.allocator.free(self.ports);
        self.allocator.destroy(self);
    }
};

pub const UsbHubPort = struct {
    number: u8,
    status: PortStatus,
    device: ?*UsbDevice,
};

pub const PortStatus = enum {
    Disconnected,
    Connected,
    Enabled,
    Suspended,
    Reset,
};

// ============================================================================
// Tests
// ============================================================================

test "USB descriptor sizes" {
    try Basics.testing.expectEqual(@as(usize, 18), @sizeOf(UsbDeviceDescriptor));
    try Basics.testing.expectEqual(@as(usize, 9), @sizeOf(UsbConfigDescriptor));
    try Basics.testing.expectEqual(@as(usize, 9), @sizeOf(UsbInterfaceDescriptor));
    try Basics.testing.expectEqual(@as(usize, 7), @sizeOf(UsbEndpointDescriptor));
    try Basics.testing.expectEqual(@as(usize, 8), @sizeOf(UsbSetupPacket));
}

test "endpoint descriptor parsing" {
    const endpoint = UsbEndpointDescriptor{
        .b_length = 7,
        .b_descriptor_type = 5,
        .b_endpoint_address = 0x81, // IN endpoint 1
        .bm_attributes = 0x02, // Bulk
        .w_max_packet_size = 512,
        .b_interval = 0,
    };

    try Basics.testing.expectEqual(EndpointDirection.In, endpoint.getDirection());
    try Basics.testing.expectEqual(@as(u8, 1), endpoint.getNumber());
    try Basics.testing.expectEqual(EndpointType.Bulk, endpoint.getType());
}
