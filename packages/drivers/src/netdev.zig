// Home Programming Language - Network Device Abstraction
// Generic network device interface

const std = @import("std");
const atomic = @import("atomic.zig");

/// Network device type
pub const DeviceType = enum {
    Ethernet,
    Wireless,
    Loopback,
    Virtual,
};

/// Network device state
pub const DeviceState = enum {
    Down,
    Up,
    Running,
    Error,
};

/// MAC address
pub const MacAddress = struct {
    bytes: [6]u8,

    pub fn init(bytes: [6]u8) MacAddress {
        return .{ .bytes = bytes };
    }

    pub fn format(
        self: *const MacAddress,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
            self.bytes[0],
            self.bytes[1],
            self.bytes[2],
            self.bytes[3],
            self.bytes[4],
            self.bytes[5],
        });
    }
};

/// Network packet
pub const Packet = struct {
    data: []u8,
    length: usize,
    flags: u32,

    pub fn init(data: []u8, length: usize) Packet {
        return .{
            .data = data,
            .length = length,
            .flags = 0,
        };
    }
};

/// Network device statistics
pub const Statistics = struct {
    rx_packets: atomic.AtomicCounter,
    tx_packets: atomic.AtomicCounter,
    rx_bytes: atomic.AtomicCounter,
    tx_bytes: atomic.AtomicCounter,
    rx_errors: atomic.AtomicCounter,
    tx_errors: atomic.AtomicCounter,

    pub fn init() Statistics {
        return .{
            .rx_packets = atomic.AtomicCounter.init(0),
            .tx_packets = atomic.AtomicCounter.init(0),
            .rx_bytes = atomic.AtomicCounter.init(0),
            .tx_bytes = atomic.AtomicCounter.init(0),
            .rx_errors = atomic.AtomicCounter.init(0),
            .tx_errors = atomic.AtomicCounter.init(0),
        };
    }

    pub fn recordRx(self: *Statistics, bytes: usize) void {
        _ = self.rx_packets.increment();
        _ = self.rx_bytes.fetchAdd(bytes, .seq_cst);
    }

    pub fn recordTx(self: *Statistics, bytes: usize) void {
        _ = self.tx_packets.increment();
        _ = self.tx_bytes.fetchAdd(bytes, .seq_cst);
    }

    pub fn recordRxError(self: *Statistics) void {
        _ = self.rx_errors.increment();
    }

    pub fn recordTxError(self: *Statistics) void {
        _ = self.tx_errors.increment();
    }
};

/// Network device operations
pub const DeviceOps = struct {
    open: *const fn (*Device) anyerror!void,
    close: *const fn (*Device) void,
    transmit: *const fn (*Device, Packet) anyerror!void,
    receive: *const fn (*Device) anyerror!?Packet,
};

/// Network device
pub const Device = struct {
    name: []const u8,
    device_type: DeviceType,
    state: DeviceState,
    mac_address: MacAddress,
    mtu: u32,
    stats: Statistics,
    ops: DeviceOps,
    driver_data: ?*anyopaque,

    pub fn init(
        name: []const u8,
        device_type: DeviceType,
        mac: MacAddress,
        ops: DeviceOps,
    ) Device {
        return .{
            .name = name,
            .device_type = device_type,
            .state = .Down,
            .mac_address = mac,
            .mtu = 1500,
            .stats = Statistics.init(),
            .ops = ops,
            .driver_data = null,
        };
    }

    pub fn open(self: *Device) !void {
        try self.ops.open(self);
        self.state = .Up;
    }

    pub fn close(self: *Device) void {
        self.ops.close(self);
        self.state = .Down;
    }

    pub fn transmit(self: *Device, packet: Packet) !void {
        if (self.state != .Up and self.state != .Running) {
            return error.DeviceNotUp;
        }
        try self.ops.transmit(self, packet);
        self.stats.recordTx(packet.length);
    }

    pub fn receive(self: *Device) !?Packet {
        if (self.state != .Up and self.state != .Running) {
            return error.DeviceNotUp;
        }
        if (try self.ops.receive(self)) |packet| {
            self.stats.recordRx(packet.length);
            return packet;
        }
        return null;
    }
};

// Dummy operations for testing
fn dummyOpen(_: *Device) !void {}
fn dummyClose(_: *Device) void {}
fn dummyTransmit(_: *Device, _: Packet) !void {}
fn dummyReceive(_: *Device) !?Packet {
    return null;
}

test "network device initialization" {
    const mac = MacAddress.init(.{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 });
    const ops = DeviceOps{
        .open = dummyOpen,
        .close = dummyClose,
        .transmit = dummyTransmit,
        .receive = dummyReceive,
    };

    var device = Device.init("eth0", .Ethernet, mac, ops);

    try std.testing.expectEqual(DeviceState.Down, device.state);
    try device.open();
    try std.testing.expectEqual(DeviceState.Up, device.state);
    device.close();
    try std.testing.expectEqual(DeviceState.Down, device.state);
}

test "network statistics" {
    var stats = Statistics.init();

    stats.recordRx(100);
    stats.recordRx(200);
    stats.recordTx(150);

    try std.testing.expectEqual(@as(u64, 2), stats.rx_packets.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 300), stats.rx_bytes.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 1), stats.tx_packets.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 150), stats.tx_bytes.load(.seq_cst));
}
