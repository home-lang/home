// Home Programming Language - USB Mass Storage Class Driver
// USB flash drives, external hard drives, etc.

const Basics = @import("basics");
const usb = @import("usb.zig");
const block = @import("../block.zig");
const sync = @import("sync");

// ============================================================================
// Mass Storage Subclass and Protocol
// ============================================================================

pub const MassStorageSubclass = enum(u8) {
    SCSI = 0x06, // SCSI transparent command set
    _,
};

pub const MassStorageProtocol = enum(u8) {
    CBI = 0x00, // Control/Bulk/Interrupt
    CB = 0x01, // Control/Bulk
    BBB = 0x50, // Bulk-Only Transport
    UAS = 0x62, // USB Attached SCSI
    _,
};

// ============================================================================
// Bulk-Only Transport (BBB)
// ============================================================================

pub const CommandBlockWrapper = extern struct {
    d_cbw_signature: u32,
    d_cbw_tag: u32,
    d_cbw_data_transfer_length: u32,
    bm_cbw_flags: u8,
    b_cbw_lun: u8,
    b_cbw_cb_length: u8,
    cbwcb: [16]u8,

    pub const SIGNATURE = 0x43425355; // "USBC"
    pub const FLAG_DATA_IN = 0x80;

    pub fn init(tag: u32, data_length: u32, flags: u8, lun: u8, cb_length: u8) CommandBlockWrapper {
        return .{
            .d_cbw_signature = SIGNATURE,
            .d_cbw_tag = tag,
            .d_cbw_data_transfer_length = data_length,
            .bm_cbw_flags = flags,
            .b_cbw_lun = lun,
            .b_cbw_cb_length = cb_length,
            .cbwcb = [_]u8{0} ** 16,
        };
    }
};

pub const CommandStatusWrapper = extern struct {
    d_csw_signature: u32,
    d_csw_tag: u32,
    d_csw_data_residue: u32,
    b_csw_status: u8,

    pub const SIGNATURE = 0x53425355; // "USBS"

    pub const STATUS_PASSED = 0x00;
    pub const STATUS_FAILED = 0x01;
    pub const STATUS_PHASE_ERROR = 0x02;

    pub fn isValid(self: *const CommandStatusWrapper, expected_tag: u32) bool {
        return self.d_csw_signature == SIGNATURE and self.d_csw_tag == expected_tag;
    }

    pub fn isPassed(self: *const CommandStatusWrapper) bool {
        return self.b_csw_status == STATUS_PASSED;
    }
};

// ============================================================================
// SCSI Commands
// ============================================================================

pub const ScsiOpcode = enum(u8) {
    TestUnitReady = 0x00,
    RequestSense = 0x03,
    Inquiry = 0x12,
    ReadCapacity10 = 0x25,
    Read10 = 0x28,
    Write10 = 0x2A,
    ReadCapacity16 = 0x9E,
    Read16 = 0x88,
    Write16 = 0x8A,
    _,
};

pub const ScsiInquiryData = extern struct {
    peripheral: u8,
    removable: u8,
    version: u8,
    response_data_format: u8,
    additional_length: u8,
    sccs: u8,
    bque: u8,
    cmd_que: u8,
    vendor_id: [8]u8,
    product_id: [16]u8,
    product_revision: [4]u8,
};

pub const ScsiCapacity10 = extern struct {
    last_lba: u32,
    block_size: u32,

    pub fn getLastLba(self: *const ScsiCapacity10) u32 {
        return @byteSwap(self.last_lba);
    }

    pub fn getBlockSize(self: *const ScsiCapacity10) u32 {
        return @byteSwap(self.block_size);
    }
};

// ============================================================================
// USB Mass Storage Device
// ============================================================================

pub const UsbMassStorage = struct {
    device: *usb.UsbDevice,
    bulk_in_endpoint: u8,
    bulk_out_endpoint: u8,
    lun: u8,
    tag_counter: u32,
    block_size: u32,
    block_count: u64,
    block_device: block.BlockDevice,
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    const vtable = block.BlockDevice.VTable{
        .read = read,
        .write = write,
        .flush = flush,
        .getBlockSize = getBlockSize,
        .getBlockCount = getBlockCount,
    };

    pub fn init(allocator: Basics.Allocator, device: *usb.UsbDevice, bulk_in: u8, bulk_out: u8) !*UsbMassStorage {
        const storage = try allocator.create(UsbMassStorage);
        errdefer allocator.destroy(storage);

        storage.* = .{
            .device = device,
            .bulk_in_endpoint = bulk_in,
            .bulk_out_endpoint = bulk_out,
            .lun = 0,
            .tag_counter = 1,
            .block_size = 512,
            .block_count = 0,
            .block_device = .{
                .name = "usb-storage",
                .vtable = &vtable,
            },
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };

        try storage.initialize();

        return storage;
    }

    pub fn deinit(self: *UsbMassStorage) void {
        self.allocator.destroy(self);
    }

    fn initialize(self: *UsbMassStorage) !void {
        // Read capacity
        var capacity_data: ScsiCapacity10 = undefined;
        try self.readCapacity10(&capacity_data);

        self.block_count = capacity_data.getLastLba() + 1;
        self.block_size = capacity_data.getBlockSize();
    }

    fn sendCommand(self: *UsbMassStorage, cbw: *CommandBlockWrapper, data_buffer: ?[]u8, data_in: bool) !CommandStatusWrapper {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Send CBW
        var cbw_urb = usb.Urb.init(self.device, self.bulk_out_endpoint, .Bulk, .Out, Basics.mem.asBytes(cbw));
        try self.device.controller.submitUrb(&cbw_urb);

        while (cbw_urb.status == .Pending) {
            // TODO: Proper sync
        }

        if (cbw_urb.status != .Completed) {
            return error.CommandFailed;
        }

        // Data phase (if present)
        if (data_buffer) |buffer| {
            const direction: usb.EndpointDirection = if (data_in) .In else .Out;
            const endpoint = if (data_in) self.bulk_in_endpoint else self.bulk_out_endpoint;

            var data_urb = usb.Urb.init(self.device, endpoint, .Bulk, direction, buffer);
            try self.device.controller.submitUrb(&data_urb);

            while (data_urb.status == .Pending) {
                // TODO: Proper sync
            }

            if (data_urb.status != .Completed) {
                return error.DataPhaseFailed;
            }
        }

        // Receive CSW
        var csw: CommandStatusWrapper = undefined;
        var csw_urb = usb.Urb.init(self.device, self.bulk_in_endpoint, .Bulk, .In, Basics.mem.asBytes(&csw));
        try self.device.controller.submitUrb(&csw_urb);

        while (csw_urb.status == .Pending) {
            // TODO: Proper sync
        }

        if (csw_urb.status != .Completed) {
            return error.StatusPhaseFailed;
        }

        if (!csw.isValid(cbw.d_cbw_tag)) {
            return error.InvalidCSW;
        }

        return csw;
    }

    pub fn inquiry(self: *UsbMassStorage, data: *ScsiInquiryData) !void {
        var cbw = CommandBlockWrapper.init(
            self.tag_counter,
            @sizeOf(ScsiInquiryData),
            CommandBlockWrapper.FLAG_DATA_IN,
            self.lun,
            6,
        );
        self.tag_counter +%= 1;

        cbw.cbwcb[0] = @intFromEnum(ScsiOpcode.Inquiry);
        cbw.cbwcb[4] = @sizeOf(ScsiInquiryData);

        var buffer: [@sizeOf(ScsiInquiryData)]u8 = undefined;
        const csw = try self.sendCommand(&cbw, &buffer, true);

        if (!csw.isPassed()) {
            return error.InquiryFailed;
        }

        data.* = @as(*const ScsiInquiryData, @ptrCast(@alignCast(&buffer))).*;
    }

    pub fn testUnitReady(self: *UsbMassStorage) !bool {
        var cbw = CommandBlockWrapper.init(
            self.tag_counter,
            0,
            0,
            self.lun,
            6,
        );
        self.tag_counter +%= 1;

        cbw.cbwcb[0] = @intFromEnum(ScsiOpcode.TestUnitReady);

        const csw = try self.sendCommand(&cbw, null, false);
        return csw.isPassed();
    }

    pub fn readCapacity10(self: *UsbMassStorage, capacity: *ScsiCapacity10) !void {
        var cbw = CommandBlockWrapper.init(
            self.tag_counter,
            @sizeOf(ScsiCapacity10),
            CommandBlockWrapper.FLAG_DATA_IN,
            self.lun,
            10,
        );
        self.tag_counter +%= 1;

        cbw.cbwcb[0] = @intFromEnum(ScsiOpcode.ReadCapacity10);

        var buffer: [@sizeOf(ScsiCapacity10)]u8 = undefined;
        const csw = try self.sendCommand(&cbw, &buffer, true);

        if (!csw.isPassed()) {
            return error.ReadCapacityFailed;
        }

        capacity.* = @as(*const ScsiCapacity10, @ptrCast(@alignCast(&buffer))).*;
    }

    pub fn readBlocks(self: *UsbMassStorage, lba: u32, num_blocks: u16, buffer: []u8) !void {
        const transfer_size = num_blocks * self.block_size;
        if (buffer.len < transfer_size) {
            return error.BufferTooSmall;
        }

        var cbw = CommandBlockWrapper.init(
            self.tag_counter,
            transfer_size,
            CommandBlockWrapper.FLAG_DATA_IN,
            self.lun,
            10,
        );
        self.tag_counter +%= 1;

        cbw.cbwcb[0] = @intFromEnum(ScsiOpcode.Read10);
        cbw.cbwcb[2] = @truncate((lba >> 24) & 0xFF);
        cbw.cbwcb[3] = @truncate((lba >> 16) & 0xFF);
        cbw.cbwcb[4] = @truncate((lba >> 8) & 0xFF);
        cbw.cbwcb[5] = @truncate(lba & 0xFF);
        cbw.cbwcb[7] = @truncate((num_blocks >> 8) & 0xFF);
        cbw.cbwcb[8] = @truncate(num_blocks & 0xFF);

        const csw = try self.sendCommand(&cbw, buffer[0..transfer_size], true);

        if (!csw.isPassed()) {
            return error.ReadFailed;
        }
    }

    pub fn writeBlocks(self: *UsbMassStorage, lba: u32, num_blocks: u16, buffer: []const u8) !void {
        const transfer_size = num_blocks * self.block_size;
        if (buffer.len < transfer_size) {
            return error.BufferTooSmall;
        }

        var cbw = CommandBlockWrapper.init(
            self.tag_counter,
            transfer_size,
            0, // OUT
            self.lun,
            10,
        );
        self.tag_counter +%= 1;

        cbw.cbwcb[0] = @intFromEnum(ScsiOpcode.Write10);
        cbw.cbwcb[2] = @truncate((lba >> 24) & 0xFF);
        cbw.cbwcb[3] = @truncate((lba >> 16) & 0xFF);
        cbw.cbwcb[4] = @truncate((lba >> 8) & 0xFF);
        cbw.cbwcb[5] = @truncate(lba & 0xFF);
        cbw.cbwcb[7] = @truncate((num_blocks >> 8) & 0xFF);
        cbw.cbwcb[8] = @truncate(num_blocks & 0xFF);

        // Cast away const for URB (URB system needs refactoring)
        const mutable_buffer = @constCast(buffer[0..transfer_size]);
        const csw = try self.sendCommand(&cbw, mutable_buffer, false);

        if (!csw.isPassed()) {
            return error.WriteFailed;
        }
    }

    // Block device interface implementation
    fn read(device: *block.BlockDevice, lba: u64, buffer: []u8) !usize {
        const self: *UsbMassStorage = @fieldParentPtr("block_device", device);

        const num_blocks: u16 = @intCast(@min(buffer.len / self.block_size, 65535));
        try self.readBlocks(@intCast(lba), num_blocks, buffer);

        return num_blocks * self.block_size;
    }

    fn write(device: *block.BlockDevice, lba: u64, buffer: []const u8) !usize {
        const self: *UsbMassStorage = @fieldParentPtr("block_device", device);

        const num_blocks: u16 = @intCast(@min(buffer.len / self.block_size, 65535));
        try self.writeBlocks(@intCast(lba), num_blocks, buffer);

        return num_blocks * self.block_size;
    }

    fn flush(device: *block.BlockDevice) !void {
        _ = device;
        // No-op for USB mass storage
    }

    fn getBlockSize(device: *block.BlockDevice) u32 {
        const self: *UsbMassStorage = @fieldParentPtr("block_device", device);
        return self.block_size;
    }

    fn getBlockCount(device: *block.BlockDevice) u64 {
        const self: *UsbMassStorage = @fieldParentPtr("block_device", device);
        return self.block_count;
    }
};

// ============================================================================
// Mass Storage Initialization
// ============================================================================

pub fn initMassStorage(allocator: Basics.Allocator, device: *usb.UsbDevice, bulk_in: u8, bulk_out: u8) !*UsbMassStorage {
    const storage = try UsbMassStorage.init(allocator, device, bulk_in, bulk_out);
    errdefer storage.deinit();

    // Test if device is ready
    const ready = try storage.testUnitReady();
    if (!ready) {
        // Device not ready (maybe no media inserted)
        return error.DeviceNotReady;
    }

    // Get device info
    var inquiry_data: ScsiInquiryData = undefined;
    try storage.inquiry(&inquiry_data);

    // TODO: Register as block device
    return storage;
}

// ============================================================================
// Tests
// ============================================================================

test "CBW structure" {
    const cbw = CommandBlockWrapper.init(1, 512, CommandBlockWrapper.FLAG_DATA_IN, 0, 10);

    try Basics.testing.expectEqual(@as(u32, CommandBlockWrapper.SIGNATURE), cbw.d_cbw_signature);
    try Basics.testing.expectEqual(@as(u32, 1), cbw.d_cbw_tag);
    try Basics.testing.expectEqual(@as(u32, 512), cbw.d_cbw_data_transfer_length);
}

test "CSW validation" {
    const csw = CommandStatusWrapper{
        .d_csw_signature = CommandStatusWrapper.SIGNATURE,
        .d_csw_tag = 42,
        .d_csw_data_residue = 0,
        .b_csw_status = CommandStatusWrapper.STATUS_PASSED,
    };

    try Basics.testing.expect(csw.isValid(42));
    try Basics.testing.expect(!csw.isValid(43));
    try Basics.testing.expect(csw.isPassed());
}

test "SCSI capacity" {
    const capacity = ScsiCapacity10{
        .last_lba = @byteSwap(@as(u32, 1000)),
        .block_size = @byteSwap(@as(u32, 512)),
    };

    try Basics.testing.expectEqual(@as(u32, 1000), capacity.getLastLba());
    try Basics.testing.expectEqual(@as(u32, 512), capacity.getBlockSize());
}
