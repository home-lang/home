// Home Programming Language - AHCI Driver
// Advanced Host Controller Interface for SATA storage

const std = @import("std");
const pci = @import("pci.zig");
const block = @import("block.zig");
const dma = @import("dma.zig");
const memory = @import("memory.zig");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// AHCI HBA Memory Registers
// ============================================================================

pub const HbaMemory = extern struct {
    // Generic Host Control
    capabilities: u32,
    global_host_control: u32,
    interrupt_status: u32,
    ports_implemented: u32,
    version: u32,
    ccc_control: u32,
    ccc_ports: u32,
    em_location: u32,
    em_control: u32,
    capabilities2: u32,
    bohc: u32,
    reserved: [116]u8,
    vendor: [96]u8,
    ports: [32]HbaPort,

    pub const CAP_S64A: u32 = 1 << 31; // 64-bit addressing
    pub const CAP_NCQ: u32 = 1 << 30; // Native Command Queuing
    pub const CAP_SNCQ: u32 = 1 << 29; // NCQ streaming
    pub const CAP_NP_MASK: u32 = 0x1F; // Number of ports

    pub const GHC_AE: u32 = 1 << 31; // AHCI Enable
    pub const GHC_IE: u32 = 1 << 1; // Interrupt Enable
    pub const GHC_HR: u32 = 1 << 0; // HBA Reset
};

pub const HbaPort = extern struct {
    command_list_base: u32,
    command_list_base_upper: u32,
    fis_base: u32,
    fis_base_upper: u32,
    interrupt_status: u32,
    interrupt_enable: u32,
    command_and_status: u32,
    reserved0: u32,
    task_file_data: u32,
    signature: u32,
    sata_status: u32,
    sata_control: u32,
    sata_error: u32,
    sata_active: u32,
    command_issue: u32,
    sata_notification: u32,
    fis_switch_control: u32,
    reserved1: [11]u32,
    vendor: [4]u32,

    pub const CMD_ST: u32 = 1 << 0; // Start
    pub const CMD_FRE: u32 = 1 << 4; // FIS Receive Enable
    pub const CMD_FR: u32 = 1 << 14; // FIS Receive Running
    pub const CMD_CR: u32 = 1 << 15; // Command List Running

    pub const SSTS_DET_MASK: u32 = 0x0F;
    pub const SSTS_DET_PRESENT: u32 = 0x03;

    pub const SIG_ATA: u32 = 0x00000101;
    pub const SIG_ATAPI: u32 = 0xEB140101;
    pub const SIG_SEMB: u32 = 0xC33C0101;
    pub const SIG_PM: u32 = 0x96690101;
};

// ============================================================================
// FIS (Frame Information Structure) Types
// ============================================================================

pub const FisType = enum(u8) {
    RegH2D = 0x27, // Register FIS - host to device
    RegD2H = 0x34, // Register FIS - device to host
    DmaActivate = 0x39, // DMA activate FIS
    DmaSetup = 0x41, // DMA setup FIS
    Data = 0x46, // Data FIS
    Bist = 0x58, // BIST activate FIS
    PioSetup = 0x5F, // PIO setup FIS
    DevBits = 0xA1, // Set device bits FIS
};

pub const FisRegH2D = extern struct {
    fis_type: u8,
    pm_port: u8, // Port multiplier, bit 7 = command/control
    command: u8,
    features_low: u8,
    lba0: u8,
    lba1: u8,
    lba2: u8,
    device: u8,
    lba3: u8,
    lba4: u8,
    lba5: u8,
    features_high: u8,
    count_low: u8,
    count_high: u8,
    icc: u8,
    control: u8,
    reserved: [4]u8,

    pub fn init(command: u8, lba: u64, count: u16) FisRegH2D {
        return .{
            .fis_type = @intFromEnum(FisType.RegH2D),
            .pm_port = 1 << 7, // Command bit
            .command = command,
            .features_low = 0,
            .lba0 = @truncate(lba),
            .lba1 = @truncate(lba >> 8),
            .lba2 = @truncate(lba >> 16),
            .device = 1 << 6, // LBA mode
            .lba3 = @truncate(lba >> 24),
            .lba4 = @truncate(lba >> 32),
            .lba5 = @truncate(lba >> 40),
            .features_high = 0,
            .count_low = @truncate(count),
            .count_high = @truncate(count >> 8),
            .icc = 0,
            .control = 0,
            .reserved = [_]u8{0} ** 4,
        };
    }
};

// ============================================================================
// ATA Commands
// ============================================================================

pub const AtaCommand = enum(u8) {
    ReadDma = 0x25, // READ DMA EXT
    WriteDma = 0x35, // WRITE DMA EXT
    FlushCache = 0xE7, // FLUSH CACHE (28-bit)
    FlushCacheExt = 0xEA, // FLUSH CACHE EXT (48-bit)
    Identify = 0xEC, // IDENTIFY DEVICE
    _,
};

// ============================================================================
// Command Header and Table
// ============================================================================

pub const CommandHeader = extern struct {
    flags: u16,
    prdtl: u16, // Physical Region Descriptor Table Length
    prdbc: u32, // Physical Region Descriptor Byte Count
    ctba: u32, // Command Table Base Address
    ctba_upper: u32,
    reserved: [4]u32,

    pub fn init(fis_len: u16, write: bool, prdtl: u16) CommandHeader {
        var flags: u16 = fis_len & 0x1F;
        if (write) flags |= 1 << 6;
        return .{
            .flags = flags,
            .prdtl = prdtl,
            .prdbc = 0,
            .ctba = 0,
            .ctba_upper = 0,
            .reserved = [_]u32{0} ** 4,
        };
    }
};

pub const PrdtEntry = extern struct {
    dba: u32, // Data Base Address
    dba_upper: u32,
    reserved: u32,
    dbc: u32, // Byte count (22 bits), interrupt on completion (bit 31)

    pub fn init(addr: u64, size: u32) PrdtEntry {
        return .{
            .dba = @truncate(addr),
            .dba_upper = @truncate(addr >> 32),
            .reserved = 0,
            .dbc = (size - 1) & 0x3FFFFF, // Size - 1, max 4MB
        };
    }
};

pub const CommandTable = extern struct {
    cfis: [64]u8, // Command FIS
    acmd: [16]u8, // ATAPI command
    reserved: [48]u8,
    prdt: [1]PrdtEntry, // Physical Region Descriptor Table (variable length)
};

// ============================================================================
// AHCI Port
// ============================================================================

pub const AhciPort = struct {
    port_num: u8,
    port_regs: *volatile HbaPort,
    device_type: DeviceType,
    command_list: []align(1024) CommandHeader,
    command_tables: []align(128) CommandTable,
    fis_base: []align(256) u8,
    dma_buffer: dma.DmaBuffer,
    lock: sync.Spinlock,
    allocator: std.mem.Allocator,
    error_count: u32 = 0,  // Track consecutive errors
    last_error: ?anyerror = null,  // Last error encountered

    pub const DeviceType = enum {
        None,
        SATA,
        SATAPI,
        SEMB,
        PM,
    };

    // Error handling constants
    pub const COMMAND_TIMEOUT_MS: u64 = 30_000; // 30 seconds
    pub const MAX_RETRIES: u8 = 3;
    pub const ERROR_THRESHOLD: u32 = 10; // Reset port after 10 consecutive errors

    pub fn init(allocator: std.mem.Allocator, port_num: u8, port_regs: *volatile HbaPort) !*AhciPort {
        const port = try allocator.create(AhciPort);
        errdefer allocator.destroy(port);

        // Allocate command list (32 entries)
        const cmd_list = try allocator.alignedAlloc(CommandHeader, 1024, 32);
        errdefer allocator.free(cmd_list);

        // Allocate command tables
        const cmd_tables = try allocator.alignedAlloc(CommandTable, 128, 32);
        errdefer allocator.free(cmd_tables);

        // Allocate FIS receive area (256 bytes)
        const fis_base = try allocator.alignedAlloc(u8, 256, 256);
        errdefer allocator.free(fis_base);

        // Allocate DMA buffer
        const dma_buf = try dma.DmaBuffer.allocate(allocator, 8192);
        errdefer dma_buf.free();

        port.* = .{
            .port_num = port_num,
            .port_regs = port_regs,
            .device_type = .None,
            .command_list = cmd_list,
            .command_tables = cmd_tables,
            .fis_base = fis_base,
            .dma_buffer = dma_buf,
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };

        try port.probe();
        return port;
    }

    pub fn deinit(self: *AhciPort) void {
        self.stop();
        self.dma_buffer.free();
        self.allocator.free(self.fis_base);
        self.allocator.free(self.command_tables);
        self.allocator.free(self.command_list);
        self.allocator.destroy(self);
    }

    fn probe(self: *AhciPort) !void {
        const ssts = self.port_regs.sata_status;
        const det = ssts & HbaPort.SSTS_DET_MASK;

        if (det != HbaPort.SSTS_DET_PRESENT) {
            self.device_type = .None;
            return;
        }

        // Determine device type from signature
        const sig = self.port_regs.signature;
        self.device_type = switch (sig) {
            HbaPort.SIG_ATA => .SATA,
            HbaPort.SIG_ATAPI => .SATAPI,
            HbaPort.SIG_SEMB => .SEMB,
            HbaPort.SIG_PM => .PM,
            else => .None,
        };
    }

    /// Reset the port on fatal errors
    pub fn reset(self: *AhciPort) !void {
        // Stop the port
        self.stop();

        // Clear error register
        self.port_regs.sata_error = 0xFFFFFFFF;
        self.port_regs.interrupt_status = 0xFFFFFFFF;

        // Perform COMRESET (Communication Reset)
        // This is a SATA-specific reset sequence
        const sctl = self.port_regs.sata_control;
        self.port_regs.sata_control = (sctl & ~0xF) | 0x1; // DET = 1 (Initialize)

        // Wait 1ms for reset
        // TODO: Use proper timer delay instead of busy wait
        var delay: u32 = 0;
        while (delay < 100000) : (delay += 1) {
            asm volatile ("pause");
        }

        self.port_regs.sata_control = sctl & ~0xF; // DET = 0 (No action)

        // Wait for device to re-establish link
        delay = 0;
        while (delay < 100000) : (delay += 1) {
            const ssts = self.port_regs.sata_status;
            if ((ssts & HbaPort.SSTS_DET_MASK) == HbaPort.SSTS_DET_PRESENT) {
                break;
            }
            asm volatile ("pause");
        }

        // Re-probe device
        try self.probe();

        // Restart the port
        try self.start();

        // Reset error counter on successful reset
        self.error_count = 0;
        self.last_error = null;
    }

    /// Wait for command completion with timeout
    fn waitForCommand(self: *AhciPort, slot: u8) !void {
        // TODO: Use actual timer instead of iteration count
        // Approximate 30 seconds at typical CPU speeds
        const timeout_iterations: u64 = 30_000_000_000; // ~30s worth of iterations
        var iterations: u64 = 0;

        const slot_bit = @as(u32, 1) << @intCast(slot);

        while (iterations < timeout_iterations) : (iterations += 1) {
            if ((self.port_regs.command_issue & slot_bit) == 0) {
                // Command completed successfully
                return;
            }

            // Check for errors
            const is = self.port_regs.interrupt_status;
            if ((is & 0x40000000) != 0) { // Task file error
                return error.TaskFileError;
            }
            if ((is & 0x20000000) != 0) { // Interface fatal error
                return error.FatalError;
            }
            if ((is & 0x10000000) != 0) { // Interface non-fatal error
                return error.InterfaceError;
            }

            // Small delay to avoid spinning too fast
            if (iterations % 1000 == 0) {
                asm volatile ("pause");
            }
        }

        return error.CommandTimeout;
    }

    /// Record an error and potentially trigger port reset
    fn recordError(self: *AhciPort, err: anyerror) anyerror {
        self.error_count += 1;
        self.last_error = err;

        // If we've hit the error threshold, reset the port
        if (self.error_count >= ERROR_THRESHOLD) {
            // Try to reset the port
            self.reset() catch {
                // Reset failed, can't recover
                return error.PortResetFailed;
            };
        }

        return err;
    }

    /// Execute command with retry logic
    fn executeWithRetry(self: *AhciPort, slot: u8) !void {
        var attempt: u8 = 0;
        var last_err: ?anyerror = null;

        while (attempt < MAX_RETRIES) : (attempt += 1) {
            // Issue command
            self.port_regs.command_issue = @as(u32, 1) << @intCast(slot);

            // Wait for completion
            const result = self.waitForCommand(slot);

            if (result) |_| {
                // Success! Reset error counter
                self.error_count = 0;
                self.last_error = null;
                return;
            } else |err| {
                last_err = err;

                // Clear error status for retry
                self.port_regs.sata_error = 0xFFFFFFFF;
                self.port_regs.interrupt_status = 0xFFFFFFFF;

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

    pub fn start(self: *AhciPort) !void {
        // Wait for CR to clear
        while ((self.port_regs.command_and_status & HbaPort.CMD_CR) != 0) {}

        // Set FRE and ST
        self.port_regs.command_and_status |= HbaPort.CMD_FRE;
        self.port_regs.command_and_status |= HbaPort.CMD_ST;

        // Set command list and FIS base addresses
        const cmd_list_addr = @intFromPtr(self.command_list.ptr);
        self.port_regs.command_list_base = @truncate(cmd_list_addr);
        self.port_regs.command_list_base_upper = @truncate(cmd_list_addr >> 32);

        const fis_addr = @intFromPtr(self.fis_base.ptr);
        self.port_regs.fis_base = @truncate(fis_addr);
        self.port_regs.fis_base_upper = @truncate(fis_addr >> 32);
    }

    pub fn stop(self: *AhciPort) void {
        // Clear ST
        self.port_regs.command_and_status &= ~HbaPort.CMD_ST;

        // Wait for CR to clear
        while ((self.port_regs.command_and_status & HbaPort.CMD_CR) != 0) {}

        // Clear FRE
        self.port_regs.command_and_status &= ~HbaPort.CMD_FRE;

        // Wait for FR to clear
        while ((self.port_regs.command_and_status & HbaPort.CMD_FR) != 0) {}
    }

    pub fn read(self: *AhciPort, lba: u64, count: u32, buffer: []u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        if (buffer.len < count * 512) return error.BufferTooSmall;

        const slot = try self.findCommandSlot();
        const cmd_header = &self.command_list[slot];
        const cmd_table = &self.command_tables[slot];

        // Setup command header
        cmd_header.* = CommandHeader.init(
            @sizeOf(FisRegH2D) / 4,
            false,
            1, // One PRDT entry
        );

        const cmd_table_addr = @intFromPtr(cmd_table);
        cmd_header.ctba = @truncate(cmd_table_addr);
        cmd_header.ctba_upper = @truncate(cmd_table_addr >> 32);

        // Setup PRDT
        cmd_table.prdt[0] = PrdtEntry.init(self.dma_buffer.physical, count * 512);

        // Setup Command FIS
        const fis: *FisRegH2D = @ptrCast(@alignCast(&cmd_table.cfis));
        fis.* = FisRegH2D.init(@intFromEnum(AtaCommand.ReadDma), lba, @intCast(count));

        // Execute command with retry
        try self.executeWithRetry(slot);

        // Copy from DMA buffer
        try self.dma_buffer.copyTo(buffer[0 .. count * 512]);
    }

    pub fn write(self: *AhciPort, lba: u64, count: u32, buffer: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        if (buffer.len < count * 512) return error.BufferTooSmall;

        // Copy to DMA buffer
        try self.dma_buffer.copyFrom(buffer[0 .. count * 512]);

        const slot = try self.findCommandSlot();
        const cmd_header = &self.command_list[slot];
        const cmd_table = &self.command_tables[slot];

        // Setup command header
        cmd_header.* = CommandHeader.init(
            @sizeOf(FisRegH2D) / 4,
            true, // Write
            1,
        );

        const cmd_table_addr = @intFromPtr(cmd_table);
        cmd_header.ctba = @truncate(cmd_table_addr);
        cmd_header.ctba_upper = @truncate(cmd_table_addr >> 32);

        // Setup PRDT
        cmd_table.prdt[0] = PrdtEntry.init(self.dma_buffer.physical, count * 512);

        // Setup Command FIS
        const fis: *FisRegH2D = @ptrCast(@alignCast(&cmd_table.cfis));
        fis.* = FisRegH2D.init(@intFromEnum(AtaCommand.WriteDma), lba, @intCast(count));

        // Execute command with retry
        try self.executeWithRetry(slot);
    }

    fn findCommandSlot(self: *AhciPort) !u8 {
        const slots = self.port_regs.sata_active | self.port_regs.command_issue;
        for (0..32) |i| {
            if ((slots & (@as(u32, 1) << @intCast(i))) == 0) {
                return @intCast(i);
            }
        }
        return error.NoFreeSlots;
    }

    /// Flush cached data to disk
    pub fn flush(self: *AhciPort) !void {
        self.lock.acquire();
        defer self.lock.release();

        const slot = try self.findCommandSlot();
        const cmd_header = &self.command_list[slot];
        const cmd_table = &self.command_tables[slot];

        // Setup command header (no data transfer)
        cmd_header.* = CommandHeader.init(
            @sizeOf(FisRegH2D) / 4,
            false,
            0, // No PRDT entries for flush
        );

        const cmd_table_addr = @intFromPtr(cmd_table);
        cmd_header.ctba = @truncate(cmd_table_addr);
        cmd_header.ctba_upper = @truncate(cmd_table_addr >> 32);

        // Setup Command FIS - use FLUSH CACHE EXT for 48-bit LBA support
        const fis: *FisRegH2D = @ptrCast(@alignCast(&cmd_table.cfis));
        fis.* = .{
            .fis_type = @intFromEnum(FisType.RegH2D),
            .pm_port = 1 << 7, // Command bit
            .command = @intFromEnum(AtaCommand.FlushCacheExt),
            .features_low = 0,
            .lba0 = 0,
            .lba1 = 0,
            .lba2 = 0,
            .device = 0,
            .lba3 = 0,
            .lba4 = 0,
            .lba5 = 0,
            .features_high = 0,
            .count_low = 0,
            .count_high = 0,
            .icc = 0,
            .control = 0,
            .reserved = [_]u8{0} ** 4,
        };

        // Execute command with retry (flush can take time)
        try self.executeWithRetry(slot);
    }

    /// Identify device - returns device info
    pub fn identify(self: *AhciPort, buffer: []u8) !void {
        if (buffer.len < 512) return error.BufferTooSmall;

        self.lock.acquire();
        defer self.lock.release();

        const slot = try self.findCommandSlot();
        const cmd_header = &self.command_list[slot];
        const cmd_table = &self.command_tables[slot];

        // Setup command header
        cmd_header.* = CommandHeader.init(
            @sizeOf(FisRegH2D) / 4,
            false, // Read from device
            1, // One PRDT entry
        );

        const cmd_table_addr = @intFromPtr(cmd_table);
        cmd_header.ctba = @truncate(cmd_table_addr);
        cmd_header.ctba_upper = @truncate(cmd_table_addr >> 32);

        // Setup PRDT - 512 bytes for identify data
        cmd_table.prdt[0] = PrdtEntry.init(self.dma_buffer.physical, 512);

        // Setup Command FIS
        const fis: *FisRegH2D = @ptrCast(@alignCast(&cmd_table.cfis));
        fis.* = .{
            .fis_type = @intFromEnum(FisType.RegH2D),
            .pm_port = 1 << 7, // Command bit
            .command = @intFromEnum(AtaCommand.Identify),
            .features_low = 0,
            .lba0 = 0,
            .lba1 = 0,
            .lba2 = 0,
            .device = 0,
            .lba3 = 0,
            .lba4 = 0,
            .lba5 = 0,
            .features_high = 0,
            .count_low = 0,
            .count_high = 0,
            .icc = 0,
            .control = 0,
            .reserved = [_]u8{0} ** 4,
        };

        // Execute command
        try self.executeWithRetry(slot);

        // Copy from DMA buffer
        try self.dma_buffer.copyTo(buffer[0..512]);
    }
};

// ============================================================================
// AHCI Controller
// ============================================================================

pub const AhciController = struct {
    pci_device: *pci.PciDevice,
    abar: *volatile HbaMemory,
    ports: [32]?*AhciPort,
    port_count: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pci_device: *pci.PciDevice) !*AhciController {
        const controller = try allocator.create(AhciController);
        errdefer allocator.destroy(controller);

        // Get ABAR (BAR5)
        const abar_bar = pci_device.getBar(5);
        const abar_addr = switch (abar_bar) {
            .Memory => |mem| mem.address,
            else => return error.InvalidBar,
        };

        const abar: *volatile HbaMemory = @ptrFromInt(abar_addr);

        controller.* = .{
            .pci_device = pci_device,
            .abar = abar,
            .ports = [_]?*AhciPort{null} ** 32,
            .port_count = 0,
            .allocator = allocator,
        };

        // Enable bus mastering
        pci_device.enableBusMastering();
        pci_device.enableMemorySpace();

        // Enable AHCI
        abar.global_host_control |= HbaMemory.GHC_AE;

        // Probe ports
        const pi = abar.ports_implemented;
        for (0..32) |i| {
            if ((pi & (@as(u32, 1) << @intCast(i))) != 0) {
                const port = try AhciPort.init(allocator, @intCast(i), &abar.ports[i]);
                if (port.device_type != .None) {
                    controller.ports[i] = port;
                    controller.port_count += 1;
                    try port.start();
                } else {
                    port.deinit();
                }
            }
        }

        return controller;
    }

    pub fn deinit(self: *AhciController) void {
        for (self.ports) |maybe_port| {
            if (maybe_port) |port| {
                port.deinit();
            }
        }
        self.allocator.destroy(self);
    }

    pub fn getPort(self: *AhciController, port_num: u8) ?*AhciPort {
        if (port_num >= 32) return null;
        return self.ports[port_num];
    }
};

// ============================================================================
// Block Device Integration
// ============================================================================

fn ahciRead(device: *block.BlockDevice, sector: u64, count: u32, buffer: []u8) !void {
    const port: *AhciPort = @ptrCast(@alignCast(device.driver_data.?));
    try port.read(sector, count, buffer);
}

fn ahciWrite(device: *block.BlockDevice, sector: u64, count: u32, data: []const u8) !void {
    const port: *AhciPort = @ptrCast(@alignCast(device.driver_data.?));
    try port.write(sector, count, data);
}

fn ahciFlush(device: *block.BlockDevice) !void {
    const port: *AhciPort = @ptrCast(@alignCast(device.driver_data.?));
    try port.flush();
}

const ahci_ops = block.BlockDeviceOps{
    .read = ahciRead,
    .write = ahciWrite,
    .flush = ahciFlush,
    .trim = null,
    .ioctl = null,
};

pub fn createBlockDevice(allocator: std.mem.Allocator, port: *AhciPort) !*block.BlockDevice {
    const device = try allocator.create(block.BlockDevice);

    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "sd{c}", .{@as(u8, 'a') + port.port_num});

    device.* = block.BlockDevice.init(
        name,
        .HardDisk,
        512,
        1024 * 1024 * 1024 / 512, // 1GB placeholder
        &ahci_ops,
    );

    device.driver_data = port;
    return device;
}

// ============================================================================
// Tests
// ============================================================================

test "AHCI structures" {
    // HbaPort should be 128 bytes (0x80) according to AHCI spec
    // 17 u32 fields + 11 u32 reserved + 4 u32 vendor = 32 u32 = 128 bytes
    try std.testing.expectEqual(@as(usize, 0x80), @sizeOf(HbaPort));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(FisRegH2D));
}
