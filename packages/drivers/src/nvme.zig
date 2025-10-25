// Home Programming Language - NVMe Driver
// NVM Express driver for modern SSDs

const Basics = @import("basics");
const pci = @import("pci.zig");
const dma = @import("dma.zig");
const sync = @import("sync.zig");
const block = @import("block.zig");

// ============================================================================
// NVMe Controller Registers
// ============================================================================

pub const NvmeRegs = extern struct {
    cap: u64, // Controller Capabilities
    vs: u32, // Version
    intms: u32, // Interrupt Mask Set
    intmc: u32, // Interrupt Mask Clear
    cc: u32, // Controller Configuration
    reserved1: u32,
    csts: u32, // Controller Status
    nssr: u32, // NVM Subsystem Reset
    aqa: u32, // Admin Queue Attributes
    asq: u64, // Admin Submission Queue Base Address
    acq: u64, // Admin Completion Queue Base Address
};

// Controller Capabilities bits
pub const CAP_MQES_MASK = 0xFFFF; // Maximum Queue Entries Supported
pub const CAP_CSS_NVM = 1 << 37; // NVM Command Set Supported

// Controller Configuration bits
pub const CC_ENABLE = 1 << 0;
pub const CC_CSS_NVM = 0 << 4;
pub const CC_MPS_SHIFT = 7;
pub const CC_IOSQES_SHIFT = 16;
pub const CC_IOCQES_SHIFT = 20;

// Controller Status bits
pub const CSTS_RDY = 1 << 0;
pub const CSTS_CFS = 1 << 1; // Controller Fatal Status

// Admin Command Opcodes
pub const ADMIN_CREATE_IO_SQ = 0x01;
pub const ADMIN_CREATE_IO_CQ = 0x05;
pub const ADMIN_IDENTIFY = 0x06;
pub const ADMIN_SET_FEATURES = 0x09;

// I/O Command Opcodes
pub const IO_READ = 0x02;
pub const IO_WRITE = 0x01;
pub const IO_FLUSH = 0x00;

// ============================================================================
// NVMe Command Structures
// ============================================================================

pub const NvmeCommand = extern struct {
    opcode: u8,
    flags: u8,
    command_id: u16,
    nsid: u32, // Namespace ID
    reserved: [2]u64,
    metadata: u64,
    prp1: u64, // Physical Region Page 1
    prp2: u64, // Physical Region Page 2
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,

    pub fn init(opcode: u8, nsid: u32) NvmeCommand {
        return Basics.mem.zeroes(NvmeCommand){
            .opcode = opcode,
            .nsid = nsid,
        };
    }
};

pub const NvmeCompletion = extern struct {
    result: u32,
    reserved: u32,
    sq_head: u16, // Submission Queue Head
    sq_id: u16, // Submission Queue ID
    command_id: u16,
    status: u16,

    pub fn isError(self: NvmeCompletion) bool {
        return (self.status & 0xFFFE) != 0;
    }

    pub fn getStatus(self: NvmeCompletion) u16 {
        return (self.status >> 1) & 0x7FF;
    }
};

// ============================================================================
// NVMe Queue
// ============================================================================

pub const NvmeQueue = struct {
    submission: []NvmeCommand,
    completion: []volatile NvmeCompletion,
    doorbell_base: u64,
    sq_tail: u16,
    cq_head: u16,
    queue_id: u16,
    phase: u8,
    lock: sync.Spinlock,
    allocator: Basics.Allocator,

    pub fn init(
        allocator: Basics.Allocator,
        doorbell_base: u64,
        queue_id: u16,
        queue_depth: u16,
    ) !*NvmeQueue {
        const queue = try allocator.create(NvmeQueue);
        errdefer allocator.destroy(queue);

        // Allocate submission queue
        const sq_buffer = try dma.allocateBuffer(
            allocator,
            @sizeOf(NvmeCommand) * queue_depth,
            4096,
        );
        errdefer dma.freeBuffer(sq_buffer);

        // Allocate completion queue
        const cq_buffer = try dma.allocateBuffer(
            allocator,
            @sizeOf(NvmeCompletion) * queue_depth,
            4096,
        );
        errdefer dma.freeBuffer(cq_buffer);

        queue.* = .{
            .submission = @as([*]NvmeCommand, @ptrFromInt(sq_buffer.virtual_addr))[0..queue_depth],
            .completion = @as([*]volatile NvmeCompletion, @ptrFromInt(cq_buffer.virtual_addr))[0..queue_depth],
            .doorbell_base = doorbell_base,
            .sq_tail = 0,
            .cq_head = 0,
            .queue_id = queue_id,
            .phase = 1,
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };

        return queue;
    }

    pub fn deinit(self: *NvmeQueue) void {
        // TODO: Free DMA buffers
        self.allocator.destroy(self);
    }

    pub fn submitCommand(self: *NvmeQueue, cmd: NvmeCommand) u16 {
        self.lock.acquire();
        defer self.lock.release();

        const command_id = self.sq_tail;
        self.submission[self.sq_tail] = cmd;
        self.sq_tail = (self.sq_tail + 1) % @as(u16, @intCast(self.submission.len));

        // Ring submission doorbell
        self.ringSubmissionDoorbell();

        return command_id;
    }

    pub fn pollCompletion(self: *NvmeQueue, command_id: u16) ?NvmeCompletion {
        const entry = &self.completion[self.cq_head];
        const status_phase = @as(u8, @intCast((entry.status >> 8) & 1));

        if (status_phase != self.phase) {
            return null; // Not ready
        }

        if (entry.command_id != command_id) {
            return null; // Not our command
        }

        const result = entry.*;
        self.cq_head = (self.cq_head + 1) % @as(u16, @intCast(self.completion.len));

        // Check if we wrapped around
        if (self.cq_head == 0) {
            self.phase ^= 1;
        }

        // Ring completion doorbell
        self.ringCompletionDoorbell();

        return result;
    }

    fn ringSubmissionDoorbell(self: *NvmeQueue) void {
        const doorbell_addr = self.doorbell_base + (@as(u64, self.queue_id) * 2 * 4);
        const doorbell: *volatile u32 = @ptrFromInt(doorbell_addr);
        doorbell.* = self.sq_tail;
    }

    fn ringCompletionDoorbell(self: *NvmeQueue) void {
        const doorbell_addr = self.doorbell_base + ((@as(u64, self.queue_id) * 2 + 1) * 4);
        const doorbell: *volatile u32 = @ptrFromInt(doorbell_addr);
        doorbell.* = self.cq_head;
    }
};

// ============================================================================
// NVMe Namespace
// ============================================================================

pub const NvmeNamespace = struct {
    id: u32,
    block_size: u32,
    block_count: u64,
    controller: *NvmeController,

    pub fn read(self: *NvmeNamespace, lba: u64, count: u32, buffer: []u8) !void {
        if (buffer.len < count * self.block_size) {
            return error.BufferTooSmall;
        }

        const dma_buf = try dma.allocateBuffer(
            self.controller.allocator,
            count * self.block_size,
            4096,
        );
        defer dma.freeBuffer(dma_buf);

        var cmd = NvmeCommand.init(IO_READ, self.id);
        cmd.prp1 = dma_buf.physical_addr;
        cmd.cdw10 = @intCast(lba & 0xFFFFFFFF);
        cmd.cdw11 = @intCast(lba >> 32);
        cmd.cdw12 = count - 1; // 0-based

        // Execute with retry
        _ = try self.controller.executeCommandWithRetry(self.controller.io_queue, cmd);

        // Copy data from DMA buffer
        const src: [*]const u8 = @ptrFromInt(dma_buf.virtual_addr);
        @memcpy(buffer[0 .. count * self.block_size], src[0 .. count * self.block_size]);
    }

    pub fn write(self: *NvmeNamespace, lba: u64, count: u32, buffer: []const u8) !void {
        if (buffer.len < count * self.block_size) {
            return error.BufferTooSmall;
        }

        const dma_buf = try dma.allocateBuffer(
            self.controller.allocator,
            count * self.block_size,
            4096,
        );
        defer dma.freeBuffer(dma_buf);

        // Copy data to DMA buffer
        const dest: [*]u8 = @ptrFromInt(dma_buf.virtual_addr);
        @memcpy(dest[0 .. count * self.block_size], buffer[0 .. count * self.block_size]);

        var cmd = NvmeCommand.init(IO_WRITE, self.id);
        cmd.prp1 = dma_buf.physical_addr;
        cmd.cdw10 = @intCast(lba & 0xFFFFFFFF);
        cmd.cdw11 = @intCast(lba >> 32);
        cmd.cdw12 = count - 1; // 0-based

        // Execute with retry
        _ = try self.controller.executeCommandWithRetry(self.controller.io_queue, cmd);
    }
};

// ============================================================================
// NVMe Controller
// ============================================================================

pub const NvmeController = struct {
    pci_device: *pci.PciDevice,
    regs: *volatile NvmeRegs,
    admin_queue: *NvmeQueue,
    io_queue: *NvmeQueue,
    namespaces: Basics.ArrayList(*NvmeNamespace),
    allocator: Basics.Allocator,
    error_count: u32 = 0,
    last_error: ?anyerror = null,

    // Error handling constants
    pub const COMMAND_TIMEOUT_MS: u64 = 30_000; // 30 seconds
    pub const MAX_RETRIES: u8 = 3;
    pub const ERROR_THRESHOLD: u32 = 10;

    pub fn init(allocator: Basics.Allocator, pci_device: *pci.PciDevice) !*NvmeController {
        const controller = try allocator.create(NvmeController);
        errdefer allocator.destroy(controller);

        // Enable PCI bus mastering
        try pci_device.enableBusMastering();

        // Map BAR0 (controller registers)
        const bar0 = pci_device.getBar(0);
        const regs: *volatile NvmeRegs = @ptrFromInt(bar0);

        controller.* = .{
            .pci_device = pci_device,
            .regs = regs,
            .admin_queue = undefined,
            .io_queue = undefined,
            .namespaces = Basics.ArrayList(*NvmeNamespace).init(allocator),
            .allocator = allocator,
        };

        try controller.reset();
        try controller.initializeQueues();
        try controller.identifyNamespaces();

        return controller;
    }

    pub fn deinit(self: *NvmeController) void {
        for (self.namespaces.items) |ns| {
            self.allocator.destroy(ns);
        }
        self.namespaces.deinit();
        self.admin_queue.deinit();
        self.io_queue.deinit();
        self.allocator.destroy(self);
    }

    fn reset(self: *NvmeController) !void {
        // Disable controller
        self.regs.cc &= ~CC_ENABLE;

        // Wait for controller to be ready (CSTS.RDY = 0)
        var timeout: u32 = 0;
        while ((self.regs.csts & CSTS_RDY) != 0) : (timeout += 1) {
            if (timeout > 1000000) return error.Timeout;
        }

        // Check for fatal status
        if ((self.regs.csts & CSTS_CFS) != 0) {
            return error.ControllerFatalStatus;
        }

        // Reset error counter on successful reset
        self.error_count = 0;
        self.last_error = null;
    }

    /// Record an error and potentially trigger controller reset
    fn recordError(self: *NvmeController, err: anyerror) anyerror {
        self.error_count += 1;
        self.last_error = err;

        // If we've hit the error threshold, reset the controller
        if (self.error_count >= ERROR_THRESHOLD) {
            // Try to reset the controller
            self.reset() catch {
                // Reset failed, can't recover
                return error.ControllerResetFailed;
            };

            // Re-initialize after reset
            self.initializeQueues() catch {
                return error.InitializationFailed;
            };
        }

        return err;
    }

    /// Wait for command completion with timeout
    fn waitForCompletion(self: *NvmeController, queue: *NvmeQueue, command_id: u16) !NvmeCompletion {
        // Approximate 30 seconds worth of iterations
        const timeout_iterations: u64 = 30_000_000_000;
        var iterations: u64 = 0;

        while (iterations < timeout_iterations) : (iterations += 1) {
            if (queue.pollCompletion(command_id)) |completion| {
                // Check for errors
                if (completion.isError()) {
                    const status = completion.getStatus();
                    // Classify the error
                    if (status >= 0x200) { // Media errors
                        return error.MediaError;
                    } else if (status >= 0x100) { // Command-specific errors
                        return error.CommandError;
                    } else { // Generic errors
                        return error.IoError;
                    }
                }
                return completion;
            }

            // Small delay to avoid spinning too fast
            if (iterations % 1000 == 0) {
                asm volatile ("pause");
            }
        }

        return error.CommandTimeout;
    }

    /// Execute command with retry logic
    fn executeCommandWithRetry(self: *NvmeController, queue: *NvmeQueue, cmd: NvmeCommand) !NvmeCompletion {
        var attempt: u8 = 0;
        var last_err: ?anyerror = null;

        while (attempt < MAX_RETRIES) : (attempt += 1) {
            // Submit command
            const command_id = queue.submitCommand(cmd);

            // Wait for completion
            const result = self.waitForCompletion(queue, command_id);

            if (result) |completion| {
                // Success! Reset error counter
                self.error_count = 0;
                self.last_error = null;
                return completion;
            } else |err| {
                last_err = err;

                // Wait a bit before retry
                var delay: u32 = 0;
                while (delay < 10000) : (delay += 1) {
                    asm volatile ("pause");
                }
            }
        }

        // All retries failed, record the error
        return self.recordError(last_err orelse error.UnknownError);
    }

    fn initializeQueues(self: *NvmeController) !void {
        const queue_depth: u16 = 64;
        const doorbell_stride = @as(u64, (self.regs.cap >> 32) & 0xF);
        const doorbell_base = @intFromPtr(self.regs) + 0x1000;

        // Create admin queue
        self.admin_queue = try NvmeQueue.init(
            self.allocator,
            doorbell_base,
            0,
            queue_depth,
        );

        // Set admin queue addresses
        self.regs.aqa = (queue_depth - 1) | ((@as(u32, queue_depth - 1)) << 16);
        self.regs.asq = @intFromPtr(self.admin_queue.submission.ptr);
        self.regs.acq = @intFromPtr(self.admin_queue.completion.ptr);

        // Configure and enable controller
        self.regs.cc = CC_ENABLE | CC_CSS_NVM | (6 << CC_MPS_SHIFT) | (6 << CC_IOSQES_SHIFT) | (4 << CC_IOCQES_SHIFT);

        // Wait for controller to be ready
        var timeout: u32 = 0;
        while ((self.regs.csts & CSTS_RDY) == 0) : (timeout += 1) {
            if (timeout > 1000000) return error.Timeout;
        }

        // Create I/O completion queue
        try self.createIoCompletionQueue(1, queue_depth);

        // Create I/O submission queue
        try self.createIoSubmissionQueue(1, 1, queue_depth);

        // Create I/O queue wrapper
        self.io_queue = try NvmeQueue.init(
            self.allocator,
            doorbell_base,
            1,
            queue_depth,
        );
    }

    fn createIoCompletionQueue(self: *NvmeController, queue_id: u16, queue_size: u16) !void {
        var cmd = NvmeCommand.init(ADMIN_CREATE_IO_CQ, 0);
        cmd.prp1 = @intFromPtr(self.io_queue.completion.ptr);
        cmd.cdw10 = (@as(u32, queue_size - 1) << 16) | queue_id;
        cmd.cdw11 = 0x01; // Physically contiguous

        const command_id = self.admin_queue.submitCommand(cmd);

        while (self.admin_queue.pollCompletion(command_id)) |completion| {
            if (completion.isError()) {
                return error.CreateQueueFailed;
            }
            return;
        }

        return error.Timeout;
    }

    fn createIoSubmissionQueue(self: *NvmeController, queue_id: u16, cq_id: u16, queue_size: u16) !void {
        var cmd = NvmeCommand.init(ADMIN_CREATE_IO_SQ, 0);
        cmd.prp1 = @intFromPtr(self.io_queue.submission.ptr);
        cmd.cdw10 = (@as(u32, queue_size - 1) << 16) | queue_id;
        cmd.cdw11 = (@as(u32, cq_id) << 16) | 0x01; // Physically contiguous

        const command_id = self.admin_queue.submitCommand(cmd);

        while (self.admin_queue.pollCompletion(command_id)) |completion| {
            if (completion.isError()) {
                return error.CreateQueueFailed;
            }
            return;
        }

        return error.Timeout;
    }

    fn identifyNamespaces(self: *NvmeController) !void {
        // TODO: Implement identify command and namespace discovery
        // For now, create a single namespace
        const ns = try self.allocator.create(NvmeNamespace);
        ns.* = .{
            .id = 1,
            .block_size = 512,
            .block_count = 1024 * 1024 * 2, // 1GB
            .controller = self,
        };

        try self.namespaces.append(ns);
    }

    pub fn getNamespace(self: *NvmeController, id: u32) ?*NvmeNamespace {
        for (self.namespaces.items) |ns| {
            if (ns.id == id) return ns;
        }
        return null;
    }
};

// ============================================================================
// Block Device Integration
// ============================================================================

const NvmeBlockDevice = struct {
    namespace: *NvmeNamespace,

    pub fn read(ctx: *anyopaque, lba: u64, count: u32, buffer: []u8) !usize {
        const self = @as(*NvmeBlockDevice, @ptrCast(@alignCast(ctx)));
        try self.namespace.read(lba, count, buffer);
        return count * self.namespace.block_size;
    }

    pub fn write(ctx: *anyopaque, lba: u64, count: u32, buffer: []const u8) !usize {
        const self = @as(*NvmeBlockDevice, @ptrCast(@alignCast(ctx)));
        try self.namespace.write(lba, count, buffer);
        return count * self.namespace.block_size;
    }
};

pub fn registerBlockDevice(allocator: Basics.Allocator, ns: *NvmeNamespace) !*block.BlockDevice {
    const nvme_dev = try allocator.create(NvmeBlockDevice);
    nvme_dev.* = .{ .namespace = ns };

    const dev = try block.BlockDevice.init(
        allocator,
        ns.block_size,
        ns.block_count,
    );

    dev.ops = .{
        .read = NvmeBlockDevice.read,
        .write = NvmeBlockDevice.write,
        .context = nvme_dev,
    };

    return dev;
}

// ============================================================================
// Tests
// ============================================================================

test "nvme command structure" {
    const cmd = NvmeCommand.init(IO_READ, 1);
    try Basics.testing.expectEqual(IO_READ, cmd.opcode);
    try Basics.testing.expectEqual(@as(u32, 1), cmd.nsid);
}

test "nvme completion status" {
    var completion: NvmeCompletion = undefined;
    completion.status = 0x0000; // Success
    try Basics.testing.expect(!completion.isError());
}
