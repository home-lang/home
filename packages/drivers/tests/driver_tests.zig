// Driver Tests - Unit tests for driver subsystems
const std = @import("std");
const testing = std.testing;

// xHCI USB 3.0 Controller Tests
test "xHCI: TRB structure size" {
    const TRB = packed struct {
        param_low: u32,
        param_high: u32,
        status: u32,
        control: u32,
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(TRB));
}

test "xHCI: slot context structure" {
    const SlotContext = packed struct {
        route_string: u20,
        speed: u4,
        reserved1: u1,
        mtt: u1,
        hub: u1,
        context_entries: u5,
        max_exit_latency: u16,
        root_hub_port: u8,
        num_ports: u8,
    };
    const slot = SlotContext{
        .route_string = 0,
        .speed = 4,
        .reserved1 = 0,
        .mtt = 0,
        .hub = 0,
        .context_entries = 3,
        .max_exit_latency = 0,
        .root_hub_port = 1,
        .num_ports = 0,
    };
    try testing.expectEqual(@as(u4, 4), slot.speed);
}

// HID Tests
test "HID: keyboard report structure" {
    const KeyboardReport = packed struct {
        modifiers: u8,
        reserved: u8,
        keys: [6]u8,
    };
    try testing.expectEqual(@as(usize, 8), @sizeOf(KeyboardReport));
}

test "HID: mouse report structure" {
    const MouseReport = packed struct {
        buttons: u8,
        x: i8,
        y: i8,
        wheel: i8,
    };
    try testing.expectEqual(@as(usize, 4), @sizeOf(MouseReport));
}

// NVMe Tests
test "NVMe: command structure size" {
    const NvmeCommand = packed struct {
        opcode: u8,
        flags: u8,
        command_id: u16,
        nsid: u32,
        reserved: u64,
        mptr: u64,
        prp1: u64,
        prp2: u64,
        cdw10: u32,
        cdw11: u32,
        cdw12: u32,
        cdw13: u32,
        cdw14: u32,
        cdw15: u32,
    };
    try testing.expectEqual(@as(usize, 64), @sizeOf(NvmeCommand));
}

test "NVMe: completion structure size" {
    const NvmeCompletion = packed struct {
        result: u32,
        reserved: u32,
        sq_head: u16,
        sq_id: u16,
        command_id: u16,
        status: u16,
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(NvmeCompletion));
}

// AHCI Tests
test "AHCI: command header size" {
    const AhciCommandHeader = packed struct {
        flags: u16,
        prdtl: u16,
        prdbc: u32,
        ctba: u32,
        ctbau: u32,
        reserved: [4]u32,
    };
    try testing.expectEqual(@as(usize, 32), @sizeOf(AhciCommandHeader));
}

// E1000 Tests
test "E1000: receive descriptor size" {
    const E1000RxDesc = packed struct {
        buffer_addr: u64,
        length: u16,
        checksum: u16,
        status: u8,
        errors: u8,
        special: u16,
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(E1000RxDesc));
}

test "E1000: transmit descriptor size" {
    const E1000TxDesc = packed struct {
        buffer_addr: u64,
        length: u16,
        cso: u8,
        cmd: u8,
        status: u8,
        css: u8,
        special: u16,
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(E1000TxDesc));
}

// PCI Tests
test "PCI: config header size" {
    const PciConfigHeader = packed struct {
        vendor_id: u16,
        device_id: u16,
        command: u16,
        status: u16,
        revision_id: u8,
        prog_if: u8,
        subclass: u8,
        class_code: u8,
        cache_line_size: u8,
        latency_timer: u8,
        header_type: u8,
        bist: u8,
        bar0: u32,
        bar1: u32,
        bar2: u32,
        bar3: u32,
        bar4: u32,
        bar5: u32,
        cardbus_cis: u32,
        subsystem_vendor_id: u16,
        subsystem_id: u16,
        expansion_rom: u32,
        capabilities_ptr: u8,
        reserved: [7]u8,
        interrupt_line: u8,
        interrupt_pin: u8,
        min_grant: u8,
        max_latency: u8,
    };
    try testing.expectEqual(@as(usize, 64), @sizeOf(PciConfigHeader));
}

test "PCI: BAR decoding" {
    const bar_value: u32 = 0xFEBC0000;
    const is_io = bar_value & 1;
    try testing.expectEqual(@as(u32, 0), is_io);
    const base_addr = bar_value & 0xFFFFFFF0;
    try testing.expectEqual(@as(u32, 0xFEBC0000), base_addr);
}
