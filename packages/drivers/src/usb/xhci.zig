// Home Programming Language - XHCI (USB 3.0) Controller Driver
// eXtensible Host Controller Interface

const Basics = @import("basics");
const usb = @import("usb.zig");
const pci = @import("pci");
const dma = @import("dma");
const sync = @import("sync");

// ============================================================================
// XHCI Capability Registers
// ============================================================================

pub const XhciCapRegs = extern struct {
    cap_length: u8,
    reserved: u8,
    hci_version: u16,
    hcs_params1: u32,
    hcs_params2: u32,
    hcs_params3: u32,
    hcc_params1: u32,
    db_off: u32,
    rts_off: u32,
    hcc_params2: u32,

    pub fn getMaxSlots(self: *const XhciCapRegs) u8 {
        return @truncate(self.hcs_params1 & 0xFF);
    }

    pub fn getMaxPorts(self: *const XhciCapRegs) u8 {
        return @truncate((self.hcs_params1 >> 24) & 0xFF);
    }

    pub fn getMaxInterrupters(self: *const XhciCapRegs) u16 {
        return @truncate((self.hcs_params1 >> 8) & 0x7FF);
    }
};

// ============================================================================
// XHCI Operational Registers
// ============================================================================

pub const XhciOpRegs = extern struct {
    usb_cmd: u32,
    usb_sts: u32,
    page_size: u32,
    reserved1: [2]u32,
    dn_ctrl: u32,
    crcr: u64,
    reserved2: [4]u32,
    dcbaap: u64,
    config: u32,

    // USB Command Register bits
    pub const CMD_RUN = 1 << 0;
    pub const CMD_RESET = 1 << 1;
    pub const CMD_INTE = 1 << 2;
    pub const CMD_HSEE = 1 << 3;

    // USB Status Register bits
    pub const STS_HCH = 1 << 0;
    pub const STS_HSE = 1 << 2;
    pub const STS_EINT = 1 << 3;
    pub const STS_CNR = 1 << 11;

    pub fn start(self: *volatile XhciOpRegs) void {
        self.usb_cmd |= CMD_RUN;
    }

    pub fn stop(self: *volatile XhciOpRegs) void {
        self.usb_cmd &= ~CMD_RUN;
    }

    pub fn reset(self: *volatile XhciOpRegs) void {
        self.usb_cmd |= CMD_RESET;
    }

    pub fn isHalted(self: *volatile XhciOpRegs) bool {
        return (self.usb_sts & STS_HCH) != 0;
    }

    pub fn isReady(self: *volatile XhciOpRegs) bool {
        return (self.usb_sts & STS_CNR) == 0;
    }
};

// ============================================================================
// XHCI Port Registers
// ============================================================================

pub const XhciPortRegs = extern struct {
    portsc: u32,
    portpmsc: u32,
    portli: u32,
    porthlpmc: u32,

    // Port Status and Control bits
    pub const PORTSC_CCS = 1 << 0; // Current Connect Status
    pub const PORTSC_PED = 1 << 1; // Port Enabled/Disabled
    pub const PORTSC_PR = 1 << 4; // Port Reset
    pub const PORTSC_PLS_MASK = 0xF << 5; // Port Link State
    pub const PORTSC_PP = 1 << 9; // Port Power
    pub const PORTSC_SPEED_MASK = 0xF << 10; // Port Speed
    pub const PORTSC_CSC = 1 << 17; // Connect Status Change
    pub const PORTSC_WRC = 1 << 19; // Warm Port Reset Change
    pub const PORTSC_PRC = 1 << 21; // Port Reset Change

    pub fn isConnected(self: *volatile XhciPortRegs) bool {
        return (self.portsc & PORTSC_CCS) != 0;
    }

    pub fn isEnabled(self: *volatile XhciPortRegs) bool {
        return (self.portsc & PORTSC_PED) != 0;
    }

    pub fn getSpeed(self: *volatile XhciPortRegs) u4 {
        return @truncate((self.portsc >> 10) & 0xF);
    }

    pub fn reset(self: *volatile XhciPortRegs) void {
        self.portsc |= PORTSC_PR;
    }

    pub fn clearStatusChange(self: *volatile XhciPortRegs) void {
        self.portsc |= PORTSC_CSC | PORTSC_PRC | PORTSC_WRC;
    }
};

// ============================================================================
// XHCI Transfer Request Block (TRB)
// ============================================================================

pub const TrbType = enum(u6) {
    Normal = 1,
    Setup = 2,
    Data = 3,
    Status = 4,
    Link = 6,
    EventData = 7,
    NoOp = 8,
    EnableSlot = 9,
    DisableSlot = 10,
    AddressDevice = 11,
    ConfigureEndpoint = 12,
    EvaluateContext = 13,
    ResetEndpoint = 14,
    StopEndpoint = 15,
    SetTRDequeue = 16,
    ResetDevice = 17,
    TransferEvent = 32,
    CommandComplete = 33,
    PortStatusChange = 34,
    _,
};

pub const Trb = extern struct {
    parameter: u64,
    status: u32,
    control: u32,

    pub fn init(trb_type: TrbType, parameter: u64, status: u32, control: u32) Trb {
        return .{
            .parameter = parameter,
            .status = status,
            .control = (control & ~@as(u32, 0xFC00)) | (@as(u32, @intFromEnum(trb_type)) << 10),
        };
    }

    pub fn getType(self: *const Trb) TrbType {
        return @enumFromInt(@as(u6, @truncate((self.control >> 10) & 0x3F)));
    }

    pub fn getCycle(self: *const Trb) bool {
        return (self.control & 1) != 0;
    }

    pub fn setCycle(self: *Trb, cycle: bool) void {
        if (cycle) {
            self.control |= 1;
        } else {
            self.control &= ~@as(u32, 1);
        }
    }
};

// ============================================================================
// XHCI Ring
// ============================================================================

pub const XhciRing = struct {
    trbs: []align(64) Trb,
    enqueue_index: usize,
    dequeue_index: usize,
    cycle_state: bool,
    physical_addr: u64,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, num_trbs: usize) !*XhciRing {
        const ring = try allocator.create(XhciRing);
        errdefer allocator.destroy(ring);

        // Allocate physically contiguous memory for TRBs
        const trbs = try allocator.alignedAlloc(Trb, 64, num_trbs);
        errdefer allocator.free(trbs);

        @memset(trbs, Trb{ .parameter = 0, .status = 0, .control = 0 });

        // Get physical address (simplified - should use DMA API)
        const physical_addr = @intFromPtr(trbs.ptr);

        ring.* = .{
            .trbs = trbs,
            .enqueue_index = 0,
            .dequeue_index = 0,
            .cycle_state = true,
            .physical_addr = physical_addr,
            .allocator = allocator,
        };

        return ring;
    }

    pub fn deinit(self: *XhciRing) void {
        self.allocator.free(self.trbs);
        self.allocator.destroy(self);
    }

    pub fn enqueue(self: *XhciRing, trb: Trb) !void {
        if (self.enqueue_index >= self.trbs.len - 1) {
            // Add link TRB
            var link = Trb.init(.Link, self.physical_addr, 0, 0);
            link.setCycle(self.cycle_state);
            self.trbs[self.enqueue_index] = link;

            self.enqueue_index = 0;
            self.cycle_state = !self.cycle_state;
        }

        var new_trb = trb;
        new_trb.setCycle(self.cycle_state);
        self.trbs[self.enqueue_index] = new_trb;
        self.enqueue_index += 1;
    }

    pub fn dequeue(self: *XhciRing) ?Trb {
        if (self.dequeue_index >= self.trbs.len) {
            self.dequeue_index = 0;
        }

        const trb = self.trbs[self.dequeue_index];
        if (trb.getCycle() != self.cycle_state) {
            return null; // No more completed TRBs
        }

        self.dequeue_index += 1;
        return trb;
    }
};

// ============================================================================
// XHCI Event Ring
// ============================================================================

pub const XhciEventRing = struct {
    segments: []align(64) Trb,
    erst: []align(64) EventRingSegmentTableEntry,
    dequeue_index: usize,
    cycle_state: bool,
    physical_addr: u64,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, num_trbs: usize) !*XhciEventRing {
        const ring = try allocator.create(XhciEventRing);
        errdefer allocator.destroy(ring);

        const segments = try allocator.alignedAlloc(Trb, 64, num_trbs);
        errdefer allocator.free(segments);

        const erst = try allocator.alignedAlloc(EventRingSegmentTableEntry, 64, 1);
        errdefer allocator.free(erst);

        @memset(segments, Trb{ .parameter = 0, .status = 0, .control = 0 });

        const physical_addr = @intFromPtr(segments.ptr);

        erst[0] = .{
            .ring_segment_base_address = physical_addr,
            .ring_segment_size = @intCast(num_trbs),
            .reserved = 0,
        };

        ring.* = .{
            .segments = segments,
            .erst = erst,
            .dequeue_index = 0,
            .cycle_state = true,
            .physical_addr = physical_addr,
            .allocator = allocator,
        };

        return ring;
    }

    pub fn deinit(self: *XhciEventRing) void {
        self.allocator.free(self.erst);
        self.allocator.free(self.segments);
        self.allocator.destroy(self);
    }

    pub fn dequeue(self: *XhciEventRing) ?Trb {
        if (self.dequeue_index >= self.segments.len) {
            self.dequeue_index = 0;
            self.cycle_state = !self.cycle_state;
        }

        const trb = self.segments[self.dequeue_index];
        if (trb.getCycle() != self.cycle_state) {
            return null;
        }

        self.dequeue_index += 1;
        return trb;
    }
};

pub const EventRingSegmentTableEntry = extern struct {
    ring_segment_base_address: u64,
    ring_segment_size: u16,
    reserved: u48,
};

// ============================================================================
// XHCI Controller
// ============================================================================

pub const XhciController = struct {
    cap_regs: *volatile XhciCapRegs,
    op_regs: *volatile XhciOpRegs,
    port_regs: []volatile XhciPortRegs,
    doorbell_array: [*]volatile u32,
    runtime_regs: [*]volatile u8,

    command_ring: *XhciRing,
    event_ring: *XhciEventRing,
    transfer_rings: Basics.ArrayList(*XhciRing),

    device_context_array: []?*DeviceContext,
    dcbaa_physical: u64,

    max_slots: u8,
    max_ports: u8,

    usb_controller: usb.UsbController,
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    const vtable = usb.UsbController.VTable{
        .submitUrb = submitUrb,
        .cancelUrb = cancelUrb,
        .reset = reset,
    };

    pub fn init(allocator: Basics.Allocator, pci_device: *pci.PciDevice) !*XhciController {
        const controller = try allocator.create(XhciController);
        errdefer allocator.destroy(controller);

        // Map MMIO registers
        const bar0 = pci_device.readBar(0);
        const base_addr = bar0 & ~@as(u64, 0xF);
        const cap_regs: *volatile XhciCapRegs = @ptrFromInt(base_addr);

        // Calculate register offsets
        const op_offset = cap_regs.cap_length;
        const op_regs: *volatile XhciOpRegs = @ptrFromInt(base_addr + op_offset);

        const max_ports = cap_regs.getMaxPorts();
        const port_regs_base: [*]volatile XhciPortRegs = @ptrFromInt(base_addr + op_offset + 0x400);
        const port_regs = port_regs_base[0..max_ports];

        const doorbell_offset = cap_regs.db_off;
        const doorbell_array: [*]volatile u32 = @ptrFromInt(base_addr + doorbell_offset);

        const runtime_offset = cap_regs.rts_off;
        const runtime_regs: [*]volatile u8 = @ptrFromInt(base_addr + runtime_offset);

        // Initialize rings
        const command_ring = try XhciRing.init(allocator, 256);
        errdefer command_ring.deinit();

        const event_ring = try XhciEventRing.init(allocator, 256);
        errdefer event_ring.deinit();

        const max_slots = cap_regs.getMaxSlots();

        // Allocate device context base address array
        const dcbaa = try allocator.alloc(?*DeviceContext, max_slots + 1);
        errdefer allocator.free(dcbaa);
        @memset(dcbaa, null);

        const dcbaa_physical = @intFromPtr(dcbaa.ptr);

        controller.* = .{
            .cap_regs = cap_regs,
            .op_regs = op_regs,
            .port_regs = port_regs,
            .doorbell_array = doorbell_array,
            .runtime_regs = runtime_regs,
            .command_ring = command_ring,
            .event_ring = event_ring,
            .transfer_rings = Basics.ArrayList(*XhciRing).init(allocator),
            .device_context_array = dcbaa,
            .dcbaa_physical = dcbaa_physical,
            .max_slots = max_slots,
            .max_ports = max_ports,
            .usb_controller = .{
                .name = "XHCI",
                .vtable = &vtable,
            },
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };

        try controller.resetController();
        try controller.startController();

        return controller;
    }

    pub fn deinit(self: *XhciController) void {
        self.command_ring.deinit();
        self.event_ring.deinit();

        for (self.transfer_rings.items) |ring| {
            ring.deinit();
        }
        self.transfer_rings.deinit();

        self.allocator.free(self.device_context_array);
        self.allocator.destroy(self);
    }

    fn resetController(self: *XhciController) !void {
        // Stop the controller
        self.op_regs.stop();

        // Wait for halt
        var timeout: u32 = 1000;
        while (!self.op_regs.isHalted() and timeout > 0) : (timeout -= 1) {
            // TODO: Sleep 1ms
        }

        if (!self.op_regs.isHalted()) {
            return error.ControllerNotHalted;
        }

        // Reset
        self.op_regs.reset();

        // Wait for reset complete
        timeout = 1000;
        while ((self.op_regs.usb_cmd & XhciOpRegs.CMD_RESET) != 0 and timeout > 0) : (timeout -= 1) {
            // TODO: Sleep 1ms
        }

        if ((self.op_regs.usb_cmd & XhciOpRegs.CMD_RESET) != 0) {
            return error.ResetFailed;
        }

        // Wait for controller ready
        timeout = 1000;
        while (!self.op_regs.isReady() and timeout > 0) : (timeout -= 1) {
            // TODO: Sleep 1ms
        }

        if (!self.op_regs.isReady()) {
            return error.ControllerNotReady;
        }
    }

    fn startController(self: *XhciController) !void {
        // Set max device slots
        self.op_regs.config = self.max_slots;

        // Set DCBAAP
        self.op_regs.dcbaap = self.dcbaa_physical;

        // Set command ring pointer
        self.op_regs.crcr = self.command_ring.physical_addr | 1; // Ring Cycle State = 1

        // Initialize interrupt registers
        const interrupter: *volatile InterrupterRegs = @ptrCast(@alignCast(self.runtime_regs + 0x20));
        interrupter.erstsz = 1; // One segment
        interrupter.erdp = self.event_ring.physical_addr;
        interrupter.erstba = @intFromPtr(self.event_ring.erst.ptr);
        interrupter.iman |= 0x02; // Enable interrupt

        // Start controller
        self.op_regs.start();

        // Wait for run
        var timeout: u32 = 1000;
        while (self.op_regs.isHalted() and timeout > 0) : (timeout -= 1) {
            // TODO: Sleep 1ms
        }

        if (self.op_regs.isHalted()) {
            return error.StartFailed;
        }
    }

    pub fn scanPorts(self: *XhciController) !void {
        for (self.port_regs, 0..) |*port, i| {
            if (port.isConnected()) {
                // Clear status change bits
                port.clearStatusChange();

                // Reset port
                port.reset();

                // Wait for reset complete
                var timeout: u32 = 100;
                while ((port.portsc & XhciPortRegs.PORTSC_PR) != 0 and timeout > 0) : (timeout -= 1) {
                    // TODO: Sleep 10ms
                }

                if (port.isEnabled()) {
                    const speed = port.getSpeed();
                    const usb_speed = switch (speed) {
                        1 => usb.UsbSpeed.Full,
                        2 => usb.UsbSpeed.Low,
                        3 => usb.UsbSpeed.High,
                        4 => usb.UsbSpeed.Super,
                        else => usb.UsbSpeed.Full,
                    };

                    // TODO: Enumerate device
                    _ = i;
                    _ = usb_speed;
                }
            }
        }
    }

    fn submitUrb(controller: *usb.UsbController, urb: *usb.Urb) !void {
        const self: *XhciController = @fieldParentPtr("usb_controller", controller);
        self.mutex.lock();
        defer self.mutex.unlock();

        // TODO: Build TRB chain and submit to transfer ring
        _ = urb;
    }

    fn cancelUrb(controller: *usb.UsbController, urb: *usb.Urb) !void {
        _ = controller;
        _ = urb;
        // TODO: Cancel URB
    }

    fn reset(controller: *usb.UsbController) !void {
        const self: *XhciController = @fieldParentPtr("usb_controller", controller);
        try self.resetController();
        try self.startController();
    }
};

const InterrupterRegs = extern struct {
    iman: u32,
    imod: u32,
    erstsz: u32,
    reserved: u32,
    erstba: u64,
    erdp: u64,
};

const DeviceContext = extern struct {
    slot_context: [8]u32,
    endpoint_contexts: [31][8]u32,
};

// ============================================================================
// Tests
// ============================================================================

test "TRB structure" {
    const trb = Trb.init(.Normal, 0x1000, 0, 0);
    try Basics.testing.expectEqual(TrbType.Normal, trb.getType());
    try Basics.testing.expectEqual(@as(u64, 0x1000), trb.parameter);
}

test "XHCI register sizes" {
    try Basics.testing.expectEqual(@as(usize, 64), @sizeOf(Trb));
}
