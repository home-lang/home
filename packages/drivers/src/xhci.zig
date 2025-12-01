// Home Programming Language - xHCI USB 3.0 Host Controller Driver
// Universal Serial Bus 3.0 host controller interface

const Basics = @import("basics");
const pci = @import("pci.zig");
const memory = @import("memory");
const SpinLock = @import("spinlock").SpinLock;

// ============================================================================
// xHCI Register Structures
// ============================================================================

/// xHCI Capability Registers
pub const XhciCapRegs = packed struct {
    /// Capability register length
    caplength: u8,
    /// Reserved
    reserved: u8,
    /// Interface version
    hciversion: u16,
    /// Structural parameters 1
    hcsparams1: u32,
    /// Structural parameters 2
    hcsparams2: u32,
    /// Structural parameters 3
    hcsparams3: u32,
    /// Capability parameters 1
    hccparams1: u32,
    /// Doorbell offset
    dboff: u32,
    /// Runtime register space offset
    rtsoff: u32,
    /// Capability parameters 2
    hccparams2: u32,
};

/// xHCI Operational Registers
pub const XhciOpRegs = packed struct {
    /// USB command register
    usbcmd: u32,
    /// USB status register
    usbsts: u32,
    /// Page size register
    pagesize: u32,
    /// Reserved
    reserved1: [2]u32,
    /// Device notification control
    dnctrl: u32,
    /// Command ring control (low)
    crcr_lo: u32,
    /// Command ring control (high)
    crcr_hi: u32,
    /// Reserved
    reserved2: [4]u32,
    /// Device context base address array pointer (low)
    dcbaap_lo: u32,
    /// Device context base address array pointer (high)
    dcbaap_hi: u32,
    /// Configure register
    config: u32,
};

/// xHCI Runtime Registers
pub const XhciRuntimeRegs = packed struct {
    /// Microframe index
    mfindex: u32,
    /// Reserved
    reserved: [7]u32,
    /// Interrupter register sets (up to 1024, we support 1)
    irs: [1]InterrupterRegs,

    pub const InterrupterRegs = packed struct {
        /// Interrupt management
        iman: u32,
        /// Interrupt moderation
        imod: u32,
        /// Event ring segment table size
        erstsz: u32,
        /// Reserved
        reserved: u32,
        /// Event ring segment table base address (low)
        erstba_lo: u32,
        /// Event ring segment table base address (high)
        erstba_hi: u32,
        /// Event ring dequeue pointer (low)
        erdp_lo: u32,
        /// Event ring dequeue pointer (high)
        erdp_hi: u32,
    };
};

/// Port register set (one per port)
pub const XhciPortRegs = packed struct {
    /// Port status and control
    portsc: u32,
    /// Port PM status and control
    portpmsc: u32,
    /// Port link info
    portli: u32,
    /// Port hardware LPM control
    porthlpmc: u32,
};

// ============================================================================
// Transfer Request Block (TRB) Structures
// ============================================================================

/// Generic TRB structure
pub const Trb = packed struct {
    /// Parameter (varies by TRB type)
    parameter: u64,
    /// Status (varies by TRB type)
    status: u32,
    /// Control fields
    control: u32,

    pub fn getType(self: *const Trb) u6 {
        return @intCast((self.control >> 10) & 0x3F);
    }

    pub fn getCyclebit(self: *const Trb) bool {
        return (self.control & 1) != 0;
    }

    pub fn setCyclebit(self: *Trb, cycle: bool) void {
        if (cycle) {
            self.control |= 1;
        } else {
            self.control &= ~@as(u32, 1);
        }
    }
};

/// TRB Types
pub const TrbType = enum(u6) {
    // Transfer TRBs
    Normal = 1,
    SetupStage = 2,
    DataStage = 3,
    StatusStage = 4,
    Isoch = 5,
    Link = 6,
    EventData = 7,
    NoOp = 8,

    // Command TRBs
    EnableSlot = 9,
    DisableSlot = 10,
    AddressDevice = 11,
    ConfigureEndpoint = 12,
    EvaluateContext = 13,
    ResetEndpoint = 14,
    StopEndpoint = 15,
    SetTRDequeuePointer = 16,
    ResetDevice = 17,
    NoOpCommand = 23,

    // Event TRBs
    TransferEvent = 32,
    CommandCompletion = 33,
    PortStatusChange = 34,
    BandwidthRequest = 35,
    Doorbell = 36,
    HostController = 37,
    DeviceNotification = 38,
    MFIndexWrap = 39,
};

// ============================================================================
// Device Context Structures
// ============================================================================

/// Slot Context
pub const SlotContext = packed struct {
    /// Route string, speed, MTT, hub, context entries
    dw0: u32,
    /// Max exit latency, root hub port number, num ports
    dw1: u32,
    /// TT hub slot ID, TT port number, TTT, interrupter target
    dw2: u32,
    /// USB device address, slot state
    dw3: u32,
    /// Reserved
    reserved: [4]u32,
};

/// Endpoint Context
pub const EndpointContext = packed struct {
    /// EP state, mult, max primary streams, LSA, interval
    dw0: u32,
    /// Error count, EP type, HID, max burst size, max packet size
    dw1: u32,
    /// TR dequeue pointer (low) + DCS
    dw2: u32,
    /// TR dequeue pointer (high)
    dw3: u32,
    /// Average TRB length, max ESIT payload
    dw4: u32,
    /// Reserved
    reserved: [3]u32,
};

/// Input Control Context
pub const InputControlContext = packed struct {
    /// Drop context flags
    drop_flags: u32,
    /// Add context flags
    add_flags: u32,
    /// Reserved
    reserved: [5]u32,
    /// Configuration value, interface number, alternate setting
    config: u32,
};

/// Device Context (includes slot + 31 endpoints)
pub const DeviceContext = struct {
    slot: SlotContext,
    endpoints: [31]EndpointContext,

    pub fn init() DeviceContext {
        return Basics.mem.zeroes(DeviceContext);
    }
};

/// Input Context (includes input control + slot + 31 endpoints)
pub const InputContext = struct {
    control: InputControlContext,
    slot: SlotContext,
    endpoints: [31]EndpointContext,

    pub fn init() InputContext {
        return Basics.mem.zeroes(InputContext);
    }
};

// ============================================================================
// Ring Buffer Management
// ============================================================================

/// TRB Ring Buffer
pub const TrbRing = struct {
    /// Ring buffer storage
    trbs: []Trb,
    /// Enqueue pointer (where we write next)
    enqueue_ptr: usize,
    /// Dequeue pointer (where we read next)
    dequeue_ptr: usize,
    /// Producer cycle state
    cycle_state: bool,
    /// Physical address of ring
    phys_addr: u64,

    pub fn init(allocator: Basics.Allocator, num_trbs: usize) !TrbRing {
        const trbs = try allocator.alloc(Trb, num_trbs);
        @memset(trbs, Basics.mem.zeroes(Trb));

        // TODO: Get physical address from virtual address
        const phys_addr: u64 = @intFromPtr(trbs.ptr);

        return .{
            .trbs = trbs,
            .enqueue_ptr = 0,
            .dequeue_ptr = 0,
            .cycle_state = true,
            .phys_addr = phys_addr,
        };
    }

    pub fn deinit(self: *TrbRing, allocator: Basics.Allocator) void {
        allocator.free(self.trbs);
    }

    /// Enqueue a TRB to the ring
    pub fn enqueueTrb(self: *TrbRing, trb: Trb) !void {
        if (self.enqueue_ptr >= self.trbs.len) {
            return error.RingFull;
        }

        var new_trb = trb;
        new_trb.setCyclebit(self.cycle_state);
        self.trbs[self.enqueue_ptr] = new_trb;

        self.enqueue_ptr += 1;
        if (self.enqueue_ptr >= self.trbs.len - 1) {
            // Wrap around with link TRB
            var link_trb = Basics.mem.zeroes(Trb);
            link_trb.parameter = self.phys_addr;
            link_trb.control = (@intFromEnum(TrbType.Link) << 10) | @as(u32, if (self.cycle_state) 1 else 0);
            self.trbs[self.enqueue_ptr] = link_trb;

            self.enqueue_ptr = 0;
            self.cycle_state = !self.cycle_state;
        }
    }

    /// Get physical address of enqueue pointer
    pub fn getEnqueuePhysAddr(self: *const TrbRing) u64 {
        return self.phys_addr + @as(u64, self.enqueue_ptr) * @sizeOf(Trb);
    }

    /// Get physical address of dequeue pointer
    pub fn getDequeuePhysAddr(self: *const TrbRing) u64 {
        return self.phys_addr + @as(u64, self.dequeue_ptr) * @sizeOf(Trb);
    }
};

/// Event Ring Segment Table Entry
pub const EventRingSegmentTableEntry = packed struct {
    /// Ring segment base address (low)
    base_lo: u32,
    /// Ring segment base address (high)
    base_hi: u32,
    /// Ring segment size
    size: u32,
    /// Reserved
    reserved: u32,
};

// ============================================================================
// xHCI Controller
// ============================================================================

const MAX_SLOTS = 32;
const MAX_PORTS = 16;
const COMMAND_RING_SIZE = 256;
const EVENT_RING_SIZE = 256;

pub const XhciController = struct {
    /// PCI device
    pci_dev: *pci.PciDevice,
    /// Capability registers
    cap_regs: *volatile XhciCapRegs,
    /// Operational registers
    op_regs: *volatile XhciOpRegs,
    /// Runtime registers
    runtime_regs: *volatile XhciRuntimeRegs,
    /// Doorbell array
    doorbells: [*]volatile u32,
    /// Port register sets
    port_regs: []volatile XhciPortRegs,

    /// Command ring
    command_ring: TrbRing,
    /// Event ring
    event_ring: TrbRing,
    /// Event ring segment table
    erst: []EventRingSegmentTableEntry,

    /// Device context base address array
    dcbaa: []?*DeviceContext,
    /// Device contexts (one per slot)
    device_contexts: [MAX_SLOTS]?*DeviceContext,

    /// Lock for controller access
    lock: SpinLock,
    /// Allocator
    allocator: Basics.Allocator,

    /// Number of device slots
    max_slots: u8,
    /// Number of ports
    num_ports: u8,

    /// Initialize xHCI controller
    pub fn init(allocator: Basics.Allocator, pci_dev: *pci.PciDevice) !*XhciController {
        const ctrl = try allocator.create(XhciController);
        errdefer allocator.destroy(ctrl);

        ctrl.pci_dev = pci_dev;
        ctrl.allocator = allocator;
        ctrl.lock = SpinLock.init();

        // Map MMIO region from BAR0
        const bar0 = try pci_dev.readConfig(0x10);
        const mmio_base = bar0 & 0xFFFFFFF0;

        // Map capability registers
        // TODO: Proper MMIO mapping with virtual memory
        ctrl.cap_regs = @ptrFromInt(mmio_base);

        // Calculate operational registers offset
        const op_offset = ctrl.cap_regs.caplength;
        ctrl.op_regs = @ptrFromInt(mmio_base + op_offset);

        // Calculate runtime registers offset
        const runtime_offset = ctrl.cap_regs.rtsoff & 0xFFFFFFE0;
        ctrl.runtime_regs = @ptrFromInt(mmio_base + runtime_offset);

        // Calculate doorbell offset
        const doorbell_offset = ctrl.cap_regs.dboff & 0xFFFFFFFC;
        ctrl.doorbells = @ptrFromInt(mmio_base + doorbell_offset);

        // Get number of ports and slots
        const hcsparams1 = ctrl.cap_regs.hcsparams1;
        ctrl.max_slots = @intCast((hcsparams1 >> 0) & 0xFF);
        ctrl.num_ports = @intCast((hcsparams1 >> 24) & 0xFF);

        // Map port registers (starts right after operational registers)
        const port_regs_base = mmio_base + op_offset + @sizeOf(XhciOpRegs);
        const port_regs_ptr: [*]volatile XhciPortRegs = @ptrFromInt(port_regs_base);
        ctrl.port_regs = port_regs_ptr[0..ctrl.num_ports];

        // Initialize rings
        ctrl.command_ring = try TrbRing.init(allocator, COMMAND_RING_SIZE);
        errdefer ctrl.command_ring.deinit(allocator);

        ctrl.event_ring = try TrbRing.init(allocator, EVENT_RING_SIZE);
        errdefer ctrl.event_ring.deinit(allocator);

        // Allocate event ring segment table
        ctrl.erst = try allocator.alloc(EventRingSegmentTableEntry, 1);
        errdefer allocator.free(ctrl.erst);

        ctrl.erst[0] = .{
            .base_lo = @intCast(ctrl.event_ring.phys_addr & 0xFFFFFFFF),
            .base_hi = @intCast(ctrl.event_ring.phys_addr >> 32),
            .size = EVENT_RING_SIZE,
            .reserved = 0,
        };

        // Allocate device context base address array
        ctrl.dcbaa = try allocator.alloc(?*DeviceContext, MAX_SLOTS + 1);
        errdefer allocator.free(ctrl.dcbaa);
        @memset(ctrl.dcbaa, null);

        @memset(&ctrl.device_contexts, null);

        // Reset and initialize controller
        try ctrl.reset();
        try ctrl.initializeController();

        return ctrl;
    }

    pub fn deinit(self: *XhciController) void {
        self.command_ring.deinit(self.allocator);
        self.event_ring.deinit(self.allocator);
        self.allocator.free(self.erst);
        self.allocator.free(self.dcbaa);

        for (self.device_contexts) |maybe_ctx| {
            if (maybe_ctx) |ctx| {
                self.allocator.destroy(ctx);
            }
        }

        self.allocator.destroy(self);
    }

    /// Reset the controller
    fn reset(self: *XhciController) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Stop the controller
        self.op_regs.usbcmd &= ~@as(u32, 1); // Clear Run/Stop bit

        // Wait for halt
        var timeout: u32 = 1000;
        while (timeout > 0) : (timeout -= 1) {
            if ((self.op_regs.usbsts & 1) != 0) break; // HCHalted bit
            // TODO: proper delay
        }
        if (timeout == 0) return error.ControllerTimeout;

        // Reset controller
        self.op_regs.usbcmd |= (1 << 1); // Set Controller Reset bit

        // Wait for reset complete
        timeout = 1000;
        while (timeout > 0) : (timeout -= 1) {
            if ((self.op_regs.usbcmd & (1 << 1)) == 0) break;
            // TODO: proper delay
        }
        if (timeout == 0) return error.ResetTimeout;

        // Wait for controller ready
        timeout = 1000;
        while (timeout > 0) : (timeout -= 1) {
            if ((self.op_regs.usbsts & (1 << 11)) == 0) break; // CNR bit
            // TODO: proper delay
        }
        if (timeout == 0) return error.ControllerNotReady;
    }

    /// Initialize controller after reset
    fn initializeController(self: *XhciController) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Set max device slots enabled
        var config = self.op_regs.config;
        config &= ~@as(u32, 0xFF);
        config |= @as(u32, self.max_slots);
        self.op_regs.config = config;

        // Set device context base address array pointer
        const dcbaa_phys = @intFromPtr(self.dcbaa.ptr);
        self.op_regs.dcbaap_lo = @intCast(dcbaa_phys & 0xFFFFFFFF);
        self.op_regs.dcbaap_hi = @intCast(dcbaa_phys >> 32);

        // Set command ring pointer
        const crcr = self.command_ring.phys_addr | 1; // Set RCS bit
        self.op_regs.crcr_lo = @intCast(crcr & 0xFFFFFFFF);
        self.op_regs.crcr_hi = @intCast(crcr >> 32);

        // Initialize primary interrupter
        var irs = &self.runtime_regs.irs[0];

        // Set event ring segment table size
        irs.erstsz = 1;

        // Set event ring segment table base address
        const erst_phys = @intFromPtr(self.erst.ptr);
        irs.erstba_lo = @intCast(erst_phys & 0xFFFFFFFF);
        irs.erstba_hi = @intCast(erst_phys >> 32);

        // Set event ring dequeue pointer
        irs.erdp_lo = @intCast(self.event_ring.phys_addr & 0xFFFFFFFF);
        irs.erdp_hi = @intCast(self.event_ring.phys_addr >> 32);

        // Enable interrupter
        irs.iman |= 0x2; // IE bit

        // Start the controller
        self.op_regs.usbcmd |= 1; // Set Run/Stop bit

        // Wait for controller running
        var timeout: u32 = 1000;
        while (timeout > 0) : (timeout -= 1) {
            if ((self.op_regs.usbsts & 1) == 0) break; // HCHalted cleared
            // TODO: proper delay
        }
        if (timeout == 0) return error.StartTimeout;
    }

    /// Issue a command TRB
    fn issueCommand(self: *XhciController, trb: Trb) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.command_ring.enqueueTrb(trb);

        // Ring doorbell for command ring (doorbell 0)
        self.doorbells[0] = 0;
    }

    /// Ring doorbell for a device slot
    fn ringDoorbell(self: *XhciController, slot_id: u8, target: u8) void {
        self.doorbells[slot_id] = @as(u32, target);
    }

    /// Enable a device slot
    pub fn enableSlot(self: *XhciController) !u8 {
        var trb = Basics.mem.zeroes(Trb);
        trb.control = (@intFromEnum(TrbType.EnableSlot) << 10);

        try self.issueCommand(trb);

        // TODO: Wait for command completion event and return slot ID
        return 1;
    }

    /// Address a device
    pub fn addressDevice(self: *XhciController, slot_id: u8, input_ctx_phys: u64, bsr: bool) !void {
        var trb = Basics.mem.zeroes(Trb);
        trb.parameter = input_ctx_phys;
        trb.control = (@intFromEnum(TrbType.AddressDevice) << 10) | (@as(u32, slot_id) << 24);
        if (bsr) trb.control |= (1 << 9); // Block Set Address Request

        try self.issueCommand(trb);
    }

    /// Configure endpoint
    pub fn configureEndpoint(self: *XhciController, slot_id: u8, input_ctx_phys: u64) !void {
        var trb = Basics.mem.zeroes(Trb);
        trb.parameter = input_ctx_phys;
        trb.control = (@intFromEnum(TrbType.ConfigureEndpoint) << 10) | (@as(u32, slot_id) << 24);

        try self.issueCommand(trb);
    }

    /// Reset a device
    pub fn resetDevice(self: *XhciController, slot_id: u8) !void {
        var trb = Basics.mem.zeroes(Trb);
        trb.control = (@intFromEnum(TrbType.ResetDevice) << 10) | (@as(u32, slot_id) << 24);

        try self.issueCommand(trb);
    }

    /// Check port status and enumerate connected devices
    pub fn enumerateDevices(self: *XhciController) !void {
        for (self.port_regs, 0..) |*port, port_num| {
            const portsc = port.portsc;

            // Check if device connected (Current Connect Status)
            if ((portsc & (1 << 0)) != 0) {
                Basics.debug.print("xHCI: Device connected on port {}\n", .{port_num});

                // Check if port enabled
                if ((portsc & (1 << 1)) != 0) {
                    try self.enumeratePort(@intCast(port_num));
                } else {
                    // Reset port to enable it
                    port.portsc = portsc | (1 << 4); // Port Reset

                    // Wait for reset complete
                    var timeout: u32 = 1000;
                    while (timeout > 0) : (timeout -= 1) {
                        if ((port.portsc & (1 << 21)) != 0) break; // Port Reset Change
                        // TODO: proper delay
                    }

                    // Clear reset change bit
                    port.portsc = port.portsc | (1 << 21);

                    // Now enumerate
                    try self.enumeratePort(@intCast(port_num));
                }
            }
        }
    }

    /// Enumerate a specific port
    fn enumeratePort(self: *XhciController, port_num: u8) !void {
        // Enable slot
        const slot_id = try self.enableSlot();

        Basics.debug.print("xHCI: Assigned slot {} to port {}\n", .{ slot_id, port_num });

        // Allocate device context
        const dev_ctx = try self.allocator.create(DeviceContext);
        dev_ctx.* = DeviceContext.init();
        self.device_contexts[slot_id] = dev_ctx;
        self.dcbaa[slot_id] = dev_ctx;

        // Allocate input context
        var input_ctx = InputContext.init();

        // Set up slot context
        input_ctx.control.add_flags = 0x3; // Add slot context and EP0

        input_ctx.slot.dw0 = 1 << 27; // Context entries = 1 (slot + EP0)
        input_ctx.slot.dw1 = (@as(u32, port_num + 1) << 16); // Root hub port number

        // Set up endpoint 0 context (control endpoint)
        input_ctx.endpoints[0].dw0 = 0; // EP state = disabled
        input_ctx.endpoints[0].dw1 = (4 << 3) | (0 << 16) | (8 << 16); // EP type = control, max packet = 8
        // TODO: Set TR dequeue pointer to transfer ring

        // Address device
        const input_ctx_phys = @intFromPtr(&input_ctx);
        try self.addressDevice(slot_id, input_ctx_phys, false);

        Basics.debug.print("xHCI: Device on slot {} addressed\n", .{slot_id});
    }

    /// Process event ring
    pub fn processEvents(self: *XhciController) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const event_ring = &self.event_ring;
        const cycle = event_ring.cycle_state;

        while (event_ring.dequeue_ptr < event_ring.trbs.len) {
            const trb = &event_ring.trbs[event_ring.dequeue_ptr];

            // Check if TRB is valid (cycle bit matches)
            if (trb.getCyclebit() != cycle) break;

            const trb_type = trb.getType();
            switch (@as(TrbType, @enumFromInt(trb_type))) {
                .TransferEvent => {
                    // Handle transfer completion
                    Basics.debug.print("xHCI: Transfer event received\n", .{});
                },
                .CommandCompletion => {
                    // Handle command completion
                    Basics.debug.print("xHCI: Command completion event\n", .{});
                },
                .PortStatusChange => {
                    // Handle port status change
                    const port_id = (trb.parameter >> 24) & 0xFF;
                    Basics.debug.print("xHCI: Port {} status changed\n", .{port_id});
                },
                else => {
                    Basics.debug.print("xHCI: Unknown event type {}\n", .{trb_type});
                },
            }

            event_ring.dequeue_ptr += 1;
        }

        // Update event ring dequeue pointer in hardware
        const irs = &self.runtime_regs.irs[0];
        const erdp = event_ring.getDequeuePhysAddr() | (1 << 3); // Set EHB (Event Handler Busy)
        irs.erdp_lo = @intCast(erdp & 0xFFFFFFFF);
        irs.erdp_hi = @intCast(erdp >> 32);
    }

    /// Handle interrupt
    pub fn handleInterrupt(self: *XhciController) !void {
        const irs = &self.runtime_regs.irs[0];

        // Check if interrupt pending
        if ((irs.iman & 1) != 0) {
            // Clear interrupt pending
            irs.iman |= 1;

            // Process events
            try self.processEvents();
        }
    }
};

// ============================================================================
// USB Request Helpers
// ============================================================================

/// USB Device Request (Setup packet)
pub const UsbDeviceRequest = packed struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
};

/// Standard USB requests
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
};

/// USB Descriptor Types
pub const UsbDescriptorType = enum(u8) {
    Device = 1,
    Configuration = 2,
    String = 3,
    Interface = 4,
    Endpoint = 5,
};

// ============================================================================
// Tests
// ============================================================================

test "xhci - register sizes" {
    const testing = Basics.testing;

    // Verify register structure sizes
    try testing.expectEqual(@as(usize, 44), @sizeOf(XhciCapRegs));
    try testing.expectEqual(@as(usize, 64), @sizeOf(XhciOpRegs));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Trb));
}

test "xhci - trb operations" {
    const testing = Basics.testing;

    var trb = Basics.mem.zeroes(Trb);
    trb.control = (@intFromEnum(TrbType.Normal) << 10);

    try testing.expectEqual(@as(u6, 1), trb.getType());
    try testing.expectEqual(false, trb.getCyclebit());

    trb.setCyclebit(true);
    try testing.expectEqual(true, trb.getCyclebit());
}

test "xhci - ring buffer" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    var ring = try TrbRing.init(allocator, 16);
    defer ring.deinit(allocator);

    // Enqueue a few TRBs
    var trb = Basics.mem.zeroes(Trb);
    trb.control = (@intFromEnum(TrbType.Normal) << 10);

    try ring.enqueueTrb(trb);
    try ring.enqueueTrb(trb);
    try ring.enqueueTrb(trb);

    try testing.expectEqual(@as(usize, 3), ring.enqueue_ptr);
    try testing.expectEqual(true, ring.cycle_state);
}
