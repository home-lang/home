// Home Programming Language - Intel e1000 Network Driver
// Driver for Intel 82540/82545/82574 NICs (widely used in VMs)

const std = @import("std");
const pci = @import("pci.zig");
const netdev = @import("netdev.zig");
const dma = @import("dma.zig");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// e1000 Register Offsets
// ============================================================================

pub const E1000Regs = struct {
    pub const CTRL: u32 = 0x00000; // Device Control
    pub const STATUS: u32 = 0x00008; // Device Status
    pub const EECD: u32 = 0x00010; // EEPROM Control
    pub const EERD: u32 = 0x00014; // EEPROM Read
    pub const CTRL_EXT: u32 = 0x00018; // Extended Control
    pub const MDIC: u32 = 0x00020; // MDI Control
    pub const FCAL: u32 = 0x00028; // Flow Control Address Low
    pub const FCAH: u32 = 0x0002C; // Flow Control Address High
    pub const FCT: u32 = 0x00030; // Flow Control Type
    pub const VET: u32 = 0x00038; // VLAN Ether Type
    pub const ICR: u32 = 0x000C0; // Interrupt Cause Read
    pub const ITR: u32 = 0x000C4; // Interrupt Throttling
    pub const ICS: u32 = 0x000C8; // Interrupt Cause Set
    pub const IMS: u32 = 0x000D0; // Interrupt Mask Set
    pub const IMC: u32 = 0x000D8; // Interrupt Mask Clear
    pub const RCTL: u32 = 0x00100; // Receive Control
    pub const TCTL: u32 = 0x00400; // Transmit Control
    pub const TIPG: u32 = 0x00410; // Transmit IPG
    pub const RDBAL: u32 = 0x02800; // RX Descriptor Base Low
    pub const RDBAH: u32 = 0x02804; // RX Descriptor Base High
    pub const RDLEN: u32 = 0x02808; // RX Descriptor Length
    pub const RDH: u32 = 0x02810; // RX Descriptor Head
    pub const RDT: u32 = 0x02818; // RX Descriptor Tail
    pub const TDBAL: u32 = 0x03800; // TX Descriptor Base Low
    pub const TDBAH: u32 = 0x03804; // TX Descriptor Base High
    pub const TDLEN: u32 = 0x03808; // TX Descriptor Length
    pub const TDH: u32 = 0x03810; // TX Descriptor Head
    pub const TDT: u32 = 0x03818; // TX Descriptor Tail
    pub const RAL: u32 = 0x05400; // Receive Address Low
    pub const RAH: u32 = 0x05404; // Receive Address High
    pub const MTA: u32 = 0x05200; // Multicast Table Array
};

// ============================================================================
// Control Register Bits
// ============================================================================

pub const CTRL_FD: u32 = 1 << 0; // Full Duplex
pub const CTRL_LRST: u32 = 1 << 3; // Link Reset
pub const CTRL_ASDE: u32 = 1 << 5; // Auto-Speed Detection
pub const CTRL_SLU: u32 = 1 << 6; // Set Link Up
pub const CTRL_ILOS: u32 = 1 << 7; // Invert Loss of Signal
pub const CTRL_RST: u32 = 1 << 26; // Device Reset
pub const CTRL_VME: u32 = 1 << 30; // VLAN Mode Enable
pub const CTRL_PHY_RST: u32 = 1 << 31; // PHY Reset

pub const RCTL_EN: u32 = 1 << 1; // Receiver Enable
pub const RCTL_SBP: u32 = 1 << 2; // Store Bad Packets
pub const RCTL_UPE: u32 = 1 << 3; // Unicast Promiscuous
pub const RCTL_MPE: u32 = 1 << 4; // Multicast Promiscuous
pub const RCTL_LPE: u32 = 1 << 5; // Long Packet Enable
pub const RCTL_BAM: u32 = 1 << 15; // Broadcast Accept Mode
pub const RCTL_BSIZE_2048: u32 = 0 << 16; // Buffer size 2048
pub const RCTL_SECRC: u32 = 1 << 26; // Strip Ethernet CRC

pub const TCTL_EN: u32 = 1 << 1; // Transmit Enable
pub const TCTL_PSP: u32 = 1 << 3; // Pad Short Packets
pub const TCTL_CT_SHIFT: u5 = 4; // Collision Threshold
pub const TCTL_COLD_SHIFT: u5 = 12; // Collision Distance

// ============================================================================
// Descriptor Structures
// ============================================================================

pub const RxDescriptor = extern struct {
    buffer_addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,

    pub const STATUS_DD: u8 = 1 << 0; // Descriptor Done
    pub const STATUS_EOP: u8 = 1 << 1; // End of Packet
};

pub const TxDescriptor = extern struct {
    buffer_addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,

    pub const CMD_EOP: u8 = 1 << 0; // End of Packet
    pub const CMD_IFCS: u8 = 1 << 1; // Insert FCS
    pub const CMD_RS: u8 = 1 << 3; // Report Status
    pub const STATUS_DD: u8 = 1 << 0; // Descriptor Done
};

// ============================================================================
// e1000 Device
// ============================================================================

const RX_RING_SIZE = 256;
const TX_RING_SIZE = 256;

pub const E1000Device = struct {
    pci_device: *pci.PciDevice,
    mmio_base: u64,
    net_device: netdev.NetDevice,

    rx_ring: []align(16) RxDescriptor,
    tx_ring: []align(16) TxDescriptor,
    rx_buffers: [RX_RING_SIZE]dma.DmaBuffer,
    tx_buffers: [TX_RING_SIZE]dma.DmaBuffer,

    rx_tail: atomic.AtomicU32,
    tx_tail: atomic.AtomicU32,

    lock: sync.Spinlock,
    allocator: std.mem.Allocator,

    // Error handling
    link_up: bool = false,
    error_count: u32 = 0,
    last_error: ?anyerror = null,

    // Constants
    pub const TX_TIMEOUT_MS: u64 = 5_000; // 5 seconds for transmit
    pub const LINK_CHECK_TIMEOUT_MS: u64 = 10_000; // 10 seconds for link up
    pub const MAX_TX_RETRIES: u8 = 3;
    pub const ERROR_THRESHOLD: u32 = 20; // Reset after 20 consecutive errors

    pub fn init(allocator: std.mem.Allocator, pci_device: *pci.PciDevice) !*E1000Device {
        const device = try allocator.create(E1000Device);
        errdefer allocator.destroy(device);

        // Get MMIO BAR (BAR0)
        const bar = pci_device.getBar(0);
        const mmio_addr = switch (bar) {
            .Memory => |mem| mem.address,
            else => return error.InvalidBar,
        };

        // Enable bus mastering and memory access
        pci_device.enableBusMastering();
        pci_device.enableMemorySpace();

        // Allocate descriptor rings
        const rx_ring = try allocator.alignedAlloc(RxDescriptor, 16, RX_RING_SIZE);
        errdefer allocator.free(rx_ring);

        const tx_ring = try allocator.alignedAlloc(TxDescriptor, 16, TX_RING_SIZE);
        errdefer allocator.free(tx_ring);

        device.* = .{
            .pci_device = pci_device,
            .mmio_base = mmio_addr,
            .net_device = undefined,
            .rx_ring = rx_ring,
            .tx_ring = tx_ring,
            .rx_buffers = undefined,
            .tx_buffers = undefined,
            .rx_tail = atomic.AtomicU32.init(0),
            .tx_tail = atomic.AtomicU32.init(0),
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };

        // Allocate DMA buffers
        for (0..RX_RING_SIZE) |i| {
            device.rx_buffers[i] = try dma.DmaBuffer.allocate(allocator, 2048);
        }

        for (0..TX_RING_SIZE) |i| {
            device.tx_buffers[i] = try dma.DmaBuffer.allocate(allocator, 2048);
        }

        // Initialize device
        try device.reset();
        const mac = try device.readMacAddress();

        device.net_device = netdev.NetDevice.init(
            "eth0",
            .Ethernet,
            mac,
            1500,
            &e1000_ops,
        );
        device.net_device.driver_data = device;

        try device.initRx();
        try device.initTx();

        return device;
    }

    pub fn deinit(self: *E1000Device) void {
        // Free DMA buffers
        for (0..RX_RING_SIZE) |i| {
            self.rx_buffers[i].free();
        }
        for (0..TX_RING_SIZE) |i| {
            self.tx_buffers[i].free();
        }

        self.allocator.free(self.tx_ring);
        self.allocator.free(self.rx_ring);
        self.allocator.destroy(self);
    }

    fn readReg(self: *E1000Device, offset: u32) u32 {
        const ptr: *volatile u32 = @ptrFromInt(self.mmio_base + offset);
        return ptr.*;
    }

    fn writeReg(self: *E1000Device, offset: u32, value: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(self.mmio_base + offset);
        ptr.* = value;
    }

    fn reset(self: *E1000Device) !void {
        // Global reset
        self.writeReg(E1000Regs.CTRL, self.readReg(E1000Regs.CTRL) | CTRL_RST);

        // Wait for reset to complete
        for (0..1000) |_| {
            if ((self.readReg(E1000Regs.CTRL) & CTRL_RST) == 0) break;
        }

        // Disable interrupts
        self.writeReg(E1000Regs.IMC, 0xFFFFFFFF);
        _ = self.readReg(E1000Regs.ICR);

        // Reset error counter
        self.error_count = 0;
        self.last_error = null;
        self.link_up = false;
    }

    /// Check link status
    fn checkLinkStatus(self: *E1000Device) bool {
        const status = self.readReg(E1000Regs.STATUS);
        // Bit 1 indicates link up
        return (status & 0x2) != 0;
    }

    /// Wait for link to come up
    fn waitForLink(self: *E1000Device) !void {
        // Approximate 10 seconds worth of iterations
        const timeout_iterations: u64 = 10_000_000_000;
        var iterations: u64 = 0;

        while (iterations < timeout_iterations) : (iterations += 1) {
            if (self.checkLinkStatus()) {
                self.link_up = true;
                return;
            }

            if (iterations % 1000 == 0) {
                asm volatile ("pause");
            }
        }

        return error.LinkTimeout;
    }

    /// Record an error and potentially reset device
    fn recordError(self: *E1000Device, err: anyerror) anyerror {
        self.error_count += 1;
        self.last_error = err;

        // If we've hit the error threshold, reset the device
        if (self.error_count >= ERROR_THRESHOLD) {
            // Try to reset the device
            self.reset() catch {
                // Reset failed, can't recover
                return error.DeviceResetFailed;
            };

            // Re-initialize after reset
            self.initRx() catch return error.InitializationFailed;
            self.initTx() catch return error.InitializationFailed;
        }

        return err;
    }

    fn readMacAddress(self: *E1000Device) !netdev.MacAddress {
        const ral = self.readReg(E1000Regs.RAL);
        const rah = self.readReg(E1000Regs.RAH);

        var mac: [6]u8 = undefined;
        mac[0] = @truncate(ral);
        mac[1] = @truncate(ral >> 8);
        mac[2] = @truncate(ral >> 16);
        mac[3] = @truncate(ral >> 24);
        mac[4] = @truncate(rah);
        mac[5] = @truncate(rah >> 8);

        return netdev.MacAddress.init(mac);
    }

    fn initRx(self: *E1000Device) !void {
        // Setup RX descriptors
        for (self.rx_ring, 0..) |*desc, i| {
            desc.* = .{
                .buffer_addr = self.rx_buffers[i].physical,
                .length = 0,
                .checksum = 0,
                .status = 0,
                .errors = 0,
                .special = 0,
            };
        }

        // Set RX ring base address
        const rx_base = @intFromPtr(self.rx_ring.ptr);
        self.writeReg(E1000Regs.RDBAL, @truncate(rx_base));
        self.writeReg(E1000Regs.RDBAH, @truncate(rx_base >> 32));

        // Set RX ring length
        self.writeReg(E1000Regs.RDLEN, @intCast(self.rx_ring.len * @sizeOf(RxDescriptor)));

        // Set RX head and tail
        self.writeReg(E1000Regs.RDH, 0);
        self.writeReg(E1000Regs.RDT, @intCast(self.rx_ring.len - 1));

        // Enable receiver
        self.writeReg(E1000Regs.RCTL, RCTL_EN | RCTL_BAM | RCTL_BSIZE_2048 | RCTL_SECRC);
    }

    fn initTx(self: *E1000Device) !void {
        // Setup TX descriptors
        for (self.tx_ring, 0..) |*desc, i| {
            desc.* = .{
                .buffer_addr = self.tx_buffers[i].physical,
                .length = 0,
                .cso = 0,
                .cmd = 0,
                .status = TxDescriptor.STATUS_DD,
                .css = 0,
                .special = 0,
            };
        }

        // Set TX ring base address
        const tx_base = @intFromPtr(self.tx_ring.ptr);
        self.writeReg(E1000Regs.TDBAL, @truncate(tx_base));
        self.writeReg(E1000Regs.TDBAH, @truncate(tx_base >> 32));

        // Set TX ring length
        self.writeReg(E1000Regs.TDLEN, @intCast(self.tx_ring.len * @sizeOf(TxDescriptor)));

        // Set TX head and tail
        self.writeReg(E1000Regs.TDH, 0);
        self.writeReg(E1000Regs.TDT, 0);

        // Configure TIPG
        self.writeReg(E1000Regs.TIPG, 0x00702008);

        // Enable transmitter
        const tctl = TCTL_EN | TCTL_PSP | (15 << TCTL_CT_SHIFT) | (64 << TCTL_COLD_SHIFT);
        self.writeReg(E1000Regs.TCTL, tctl);
    }

    pub fn transmit(self: *E1000Device, skb: *netdev.PacketBuffer) !void {
        // Check link status first
        if (!self.link_up and !self.checkLinkStatus()) {
            return self.recordError(error.LinkDown);
        }

        self.lock.acquire();
        defer self.lock.release();

        var attempt: u8 = 0;
        var last_err: ?anyerror = null;

        while (attempt < MAX_TX_RETRIES) : (attempt += 1) {
            const tail = self.tx_tail.load(.Acquire);
            const desc = &self.tx_ring[tail % TX_RING_SIZE];

            // Wait for descriptor to be available with timeout
            const timeout_iterations: u64 = 5_000_000_000; // ~5 seconds
            var iterations: u64 = 0;
            while ((desc.status & TxDescriptor.STATUS_DD) == 0) {
                iterations += 1;
                if (iterations >= timeout_iterations) {
                    last_err = error.TransmitTimeout;
                    break;
                }
                if (iterations % 1000 == 0) {
                    asm volatile ("pause");
                }
            }

            // If we got a timeout, retry
            if (last_err) |_| {
                // Wait a bit before retry
                var delay: u32 = 0;
                while (delay < 10000) : (delay += 1) {
                    asm volatile ("pause");
                }
                continue;
            }

            // Copy packet data
            const data = skb.getData();
            const tx_buf = &self.tx_buffers[tail % TX_RING_SIZE];
            tx_buf.copyFrom(data) catch |err| {
                last_err = err;
                continue;
            };

            // Setup descriptor
            desc.length = @intCast(data.len);
            desc.cmd = TxDescriptor.CMD_EOP | TxDescriptor.CMD_IFCS | TxDescriptor.CMD_RS;
            desc.status = 0;

            // Update tail
            const new_tail = (tail + 1) % TX_RING_SIZE;
            self.tx_tail.store(new_tail, .Release);
            self.writeReg(E1000Regs.TDT, new_tail);

            // Success! Reset error counter
            self.error_count = 0;
            self.last_error = null;
            return;
        }

        // All retries failed
        return self.recordError(last_err orelse error.UnknownError);
    }

    pub fn receive(self: *E1000Device) void {
        while (true) {
            const tail = self.rx_tail.load(.Acquire);
            const desc = &self.rx_ring[tail % RX_RING_SIZE];

            // Check if descriptor is done
            if ((desc.status & RxDescriptor.STATUS_DD) == 0) break;

            // Allocate packet buffer
            const skb = netdev.PacketBuffer.alloc(self.allocator, desc.length) catch break;

            // Copy data
            const rx_buf = &self.rx_buffers[tail % RX_RING_SIZE];
            const data = skb.getData();
            rx_buf.copyTo(data[0..desc.length]) catch {
                skb.free();
                break;
            };

            // Reset descriptor
            desc.status = 0;

            // Update tail
            const new_tail = (tail + 1) % RX_RING_SIZE;
            self.rx_tail.store(new_tail, .Release);
            self.writeReg(E1000Regs.RDT, new_tail);

            // Hand packet to network stack
            self.net_device.receive(skb);
        }
    }
};

// ============================================================================
// Network Device Operations
// ============================================================================

fn e1000Open(dev: *netdev.NetDevice) !void {
    const e1000: *E1000Device = @ptrCast(@alignCast(dev.driver_data.?));

    // Set link up
    const ctrl = e1000.readReg(E1000Regs.CTRL);
    e1000.writeReg(E1000Regs.CTRL, ctrl | CTRL_SLU);
}

fn e1000Stop(dev: *netdev.NetDevice) !void {
    const e1000: *E1000Device = @ptrCast(@alignCast(dev.driver_data.?));

    // Disable receiver
    const rctl = e1000.readReg(E1000Regs.RCTL);
    e1000.writeReg(E1000Regs.RCTL, rctl & ~RCTL_EN);

    // Disable transmitter
    const tctl = e1000.readReg(E1000Regs.TCTL);
    e1000.writeReg(E1000Regs.TCTL, tctl & ~TCTL_EN);

    // Disable all interrupts
    e1000.writeReg(E1000Regs.IMC, 0xFFFFFFFF);

    // Clear any pending interrupts
    _ = e1000.readReg(E1000Regs.ICR);

    // Clear link up flag
    e1000.link_up = false;
}

fn e1000Xmit(dev: *netdev.NetDevice, skb: *netdev.PacketBuffer) !void {
    const e1000: *E1000Device = @ptrCast(@alignCast(dev.driver_data.?));
    try e1000.transmit(skb);
}

const e1000_ops = netdev.NetDeviceOps{
    .open = e1000Open,
    .stop = e1000Stop,
    .xmit = e1000Xmit,
    .set_mac = null,
    .get_stats = null,
};

// ============================================================================
// Tests
// ============================================================================

test "e1000 structures" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RxDescriptor));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TxDescriptor));
}
