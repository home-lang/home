// Home Programming Language - BCM2835/BCM2711 VideoCore Mailbox Driver
// For Raspberry Pi 3/4 - Communication with GPU/firmware

const Basics = @import("basics");

// ============================================================================
// Mailbox Register Layout
// ============================================================================

pub const MailboxRegs = extern struct {
    read: volatile u32, // 0x00 - Read register
    _reserved1: [3]u32, // 0x04-0x0C
    peek: volatile u32, // 0x10 - Peek register
    sender: volatile u32, // 0x14 - Sender ID
    status: volatile u32, // 0x18 - Status register
    config: volatile u32, // 0x1C - Configuration register
    write: volatile u32, // 0x20 - Write register
};

// Mailbox base addresses
pub const BCM2835_MAILBOX_BASE = 0x3F00B880; // Raspberry Pi 3
pub const BCM2711_MAILBOX_BASE = 0xFE00B880; // Raspberry Pi 4

// Status register bits
pub const MAILBOX_FULL = 0x80000000;
pub const MAILBOX_EMPTY = 0x40000000;

// ============================================================================
// Mailbox Channels
// ============================================================================

pub const MailboxChannel = enum(u4) {
    PowerManagement = 0,
    FrameBuffer = 1,
    VirtualUART = 2,
    VCHIQ = 3,
    LEDs = 4,
    Buttons = 5,
    TouchScreen = 6,
    Count = 7,
    PropertyTagsARMToVC = 8,
    PropertyTagsVCToARM = 9,
};

// ============================================================================
// Property Tags
// ============================================================================

pub const PropertyTag = enum(u32) {
    // Hardware tags
    GetFirmwareRevision = 0x00000001,
    GetBoardModel = 0x00010001,
    GetBoardRevision = 0x00010002,
    GetBoardMACAddress = 0x00010003,
    GetBoardSerial = 0x00010004,
    GetARMMemory = 0x00010005,
    GetVCMemory = 0x00010006,

    // Clock tags
    GetClockState = 0x00030001,
    GetClockRate = 0x00030002,
    GetMaxClockRate = 0x00030004,
    GetMinClockRate = 0x00030007,
    SetClockState = 0x00038001,
    SetClockRate = 0x00038002,

    // Voltage tags
    GetVoltage = 0x00030003,
    GetMaxVoltage = 0x00030005,
    GetMinVoltage = 0x00030008,
    SetVoltage = 0x00038003,

    // Temperature tags
    GetTemperature = 0x00030006,
    GetMaxTemperature = 0x0003000A,

    // Memory tags
    AllocateMemory = 0x0003000C,
    LockMemory = 0x0003000D,
    UnlockMemory = 0x0003000E,
    ReleaseMemory = 0x0003000F,

    // Framebuffer tags
    AllocateFramebuffer = 0x00040001,
    ReleaseFramebuffer = 0x00048001,
    GetPhysicalSize = 0x00040003,
    SetPhysicalSize = 0x00048003,
    GetVirtualSize = 0x00040004,
    SetVirtualSize = 0x00048004,
    GetDepth = 0x00040005,
    SetDepth = 0x00048005,
    GetPixelOrder = 0x00040006,
    SetPixelOrder = 0x00048006,
    GetAlphaMode = 0x00040007,
    SetAlphaMode = 0x00048007,
    GetPitch = 0x00040008,
    GetVirtualOffset = 0x00040009,
    SetVirtualOffset = 0x00048009,
    GetOverscan = 0x0004000A,
    SetOverscan = 0x0004800A,
    GetPalette = 0x0004000B,
    SetPalette = 0x0004800B,

    // Power management
    GetPowerState = 0x00020001,
    SetPowerState = 0x00028001,

    // End marker
    End = 0x00000000,
};

// ============================================================================
// Property Message Structures
// ============================================================================

pub const PropertyMessageHeader = extern struct {
    size: u32, // Total size in bytes
    code: u32, // Request/response code
};

pub const PropertyTagHeader = extern struct {
    tag: u32, // Property tag ID
    buffer_size: u32, // Size of value buffer
    request_response: u32, // Request: 0, Response: bit 31 set + value length
};

// Request/response codes
pub const REQUEST_CODE = 0x00000000;
pub const RESPONSE_SUCCESS = 0x80000000;
pub const RESPONSE_ERROR = 0x80000001;

// ============================================================================
// Clock IDs
// ============================================================================

pub const ClockId = enum(u32) {
    EMMC = 1,
    UART = 2,
    ARM = 3,
    CORE = 4,
    V3D = 5,
    H264 = 6,
    ISP = 7,
    SDRAM = 8,
    PIXEL = 9,
    PWM = 10,
};

// ============================================================================
// Mailbox Driver
// ============================================================================

pub const MailboxDriver = struct {
    regs: *volatile MailboxRegs,

    pub fn init(base_addr: u64) MailboxDriver {
        return .{
            .regs = @ptrFromInt(base_addr),
        };
    }

    /// Wait until mailbox is not full
    fn waitNotFull(self: *MailboxDriver) void {
        while ((self.regs.status & MAILBOX_FULL) != 0) {
            asm volatile ("nop");
        }
    }

    /// Wait until mailbox is not empty
    fn waitNotEmpty(self: *MailboxDriver) void {
        while ((self.regs.status & MAILBOX_EMPTY) != 0) {
            asm volatile ("nop");
        }
    }

    /// Write to mailbox
    pub fn write(self: *MailboxDriver, channel: MailboxChannel, data: u32) void {
        // Data must be aligned to 16 bytes (bottom 4 bits are channel)
        const value = (data & 0xFFFFFFF0) | @intFromEnum(channel);

        self.waitNotFull();
        self.regs.write = value;
    }

    /// Read from mailbox
    pub fn read(self: *MailboxDriver, channel: MailboxChannel) u32 {
        while (true) {
            self.waitNotEmpty();
            const value = self.regs.read;
            const msg_channel: u4 = @truncate(value & 0xF);

            if (msg_channel == @intFromEnum(channel)) {
                return value & 0xFFFFFFF0;
            }
        }
    }

    /// Call mailbox with automatic read/write
    pub fn call(self: *MailboxDriver, channel: MailboxChannel, data: u32) u32 {
        self.write(channel, data);
        return self.read(channel);
    }

    /// Send property message (most common operation)
    pub fn sendPropertyMessage(self: *MailboxDriver, buffer: []align(16) u8) !void {
        const buffer_addr: u32 = @truncate(@intFromPtr(buffer.ptr) & 0x3FFFFFFF); // Physical address

        // Ensure data cache is flushed
        asm volatile ("dc cvac, %[addr]"
            :
            : [addr] "r" (@intFromPtr(buffer.ptr)),
        );
        asm volatile ("dsb sy");

        // Write to mailbox
        self.write(.PropertyTagsARMToVC, buffer_addr);

        // Read response
        _ = self.read(.PropertyTagsARMToVC);

        // Invalidate cache for response
        asm volatile ("dc ivac, %[addr]"
            :
            : [addr] "r" (@intFromPtr(buffer.ptr)),
        );
        asm volatile ("dsb sy");

        // Check response code
        const header: *PropertyMessageHeader = @ptrCast(@alignCast(buffer.ptr));
        if (header.code != RESPONSE_SUCCESS) {
            return error.MailboxError;
        }
    }
};

// ============================================================================
// High-Level Property Interface
// ============================================================================

pub const PropertyInterface = struct {
    mailbox: *MailboxDriver,
    buffer: []align(16) u8,

    pub fn init(mailbox: *MailboxDriver, buffer: []align(16) u8) PropertyInterface {
        return .{
            .mailbox = mailbox,
            .buffer = buffer,
        };
    }

    /// Get firmware revision
    pub fn getFirmwareRevision(self: *PropertyInterface) !u32 {
        const buffer = self.buffer;

        // Build message
        var offset: usize = 0;

        // Header
        const header: *PropertyMessageHeader = @ptrCast(@alignCast(&buffer[offset]));
        header.size = 32;
        header.code = REQUEST_CODE;
        offset += @sizeOf(PropertyMessageHeader);

        // Tag
        const tag: *PropertyTagHeader = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.GetFirmwareRevision);
        tag.buffer_size = 4;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        // Value (space for response)
        offset += 4;

        // End tag
        const end: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        end.* = @intFromEnum(PropertyTag.End);

        // Send message
        try self.mailbox.sendPropertyMessage(buffer[0..32]);

        // Extract response
        const response: *u32 = @ptrCast(@alignCast(&buffer[@sizeOf(PropertyMessageHeader) + @sizeOf(PropertyTagHeader)]));
        return response.*;
    }

    /// Get board model
    pub fn getBoardModel(self: *PropertyInterface) !u32 {
        const buffer = self.buffer;
        var offset: usize = 0;

        const header: *PropertyMessageHeader = @ptrCast(@alignCast(&buffer[offset]));
        header.size = 32;
        header.code = REQUEST_CODE;
        offset += @sizeOf(PropertyMessageHeader);

        const tag: *PropertyTagHeader = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.GetBoardModel);
        tag.buffer_size = 4;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        offset += 4;

        const end: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        end.* = @intFromEnum(PropertyTag.End);

        try self.mailbox.sendPropertyMessage(buffer[0..32]);

        const response: *u32 = @ptrCast(@alignCast(&buffer[@sizeOf(PropertyMessageHeader) + @sizeOf(PropertyTagHeader)]));
        return response.*;
    }

    /// Get ARM memory (base and size)
    pub fn getARMMemory(self: *PropertyInterface) !struct { base: u32, size: u32 } {
        const buffer = self.buffer;
        var offset: usize = 0;

        const header: *PropertyMessageHeader = @ptrCast(@alignCast(&buffer[offset]));
        header.size = 40;
        header.code = REQUEST_CODE;
        offset += @sizeOf(PropertyMessageHeader);

        const tag: *PropertyTagHeader = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.GetARMMemory);
        tag.buffer_size = 8;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        offset += 8; // Space for base + size

        const end: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        end.* = @intFromEnum(PropertyTag.End);

        try self.mailbox.sendPropertyMessage(buffer[0..40]);

        const base: *u32 = @ptrCast(@alignCast(&buffer[@sizeOf(PropertyMessageHeader) + @sizeOf(PropertyTagHeader)]));
        const size: *u32 = @ptrCast(@alignCast(&buffer[@sizeOf(PropertyMessageHeader) + @sizeOf(PropertyTagHeader) + 4]));

        return .{ .base = base.*, .size = size.* };
    }

    /// Get clock rate
    pub fn getClockRate(self: *PropertyInterface, clock_id: ClockId) !u32 {
        const buffer = self.buffer;
        var offset: usize = 0;

        const header: *PropertyMessageHeader = @ptrCast(@alignCast(&buffer[offset]));
        header.size = 40;
        header.code = REQUEST_CODE;
        offset += @sizeOf(PropertyMessageHeader);

        const tag: *PropertyTagHeader = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.GetClockRate);
        tag.buffer_size = 8;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        // Request value: clock ID
        const clock_id_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        clock_id_ptr.* = @intFromEnum(clock_id);
        offset += 4;

        offset += 4; // Space for rate response

        const end: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        end.* = @intFromEnum(PropertyTag.End);

        try self.mailbox.sendPropertyMessage(buffer[0..40]);

        const rate: *u32 = @ptrCast(@alignCast(&buffer[@sizeOf(PropertyMessageHeader) + @sizeOf(PropertyTagHeader) + 4]));
        return rate.*;
    }

    /// Set clock rate
    pub fn setClockRate(self: *PropertyInterface, clock_id: ClockId, rate: u32, skip_turbo: bool) !u32 {
        const buffer = self.buffer;
        var offset: usize = 0;

        const header: *PropertyMessageHeader = @ptrCast(@alignCast(&buffer[offset]));
        header.size = 48;
        header.code = REQUEST_CODE;
        offset += @sizeOf(PropertyMessageHeader);

        const tag: *PropertyTagHeader = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.SetClockRate);
        tag.buffer_size = 12;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        const clock_id_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        clock_id_ptr.* = @intFromEnum(clock_id);
        offset += 4;

        const rate_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        rate_ptr.* = rate;
        offset += 4;

        const skip_turbo_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        skip_turbo_ptr.* = if (skip_turbo) 1 else 0;
        offset += 4;

        const end: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        end.* = @intFromEnum(PropertyTag.End);

        try self.mailbox.sendPropertyMessage(buffer[0..48]);

        const actual_rate: *u32 = @ptrCast(@alignCast(&buffer[@sizeOf(PropertyMessageHeader) + @sizeOf(PropertyTagHeader) + 4]));
        return actual_rate.*;
    }

    /// Allocate framebuffer
    pub fn allocateFramebuffer(self: *PropertyInterface, width: u32, height: u32, depth: u32) !struct {
        base: u32,
        size: u32,
    } {
        const buffer = self.buffer;
        var offset: usize = 0;

        const header: *PropertyMessageHeader = @ptrCast(@alignCast(&buffer[offset]));
        header.size = 256; // Large enough for multiple tags
        header.code = REQUEST_CODE;
        offset += @sizeOf(PropertyMessageHeader);

        // Set physical size
        var tag: *PropertyTagHeader = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.SetPhysicalSize);
        tag.buffer_size = 8;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        var width_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        width_ptr.* = width;
        offset += 4;

        var height_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        height_ptr.* = height;
        offset += 4;

        // Set virtual size
        tag = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.SetVirtualSize);
        tag.buffer_size = 8;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        width_ptr = @ptrCast(@alignCast(&buffer[offset]));
        width_ptr.* = width;
        offset += 4;

        height_ptr = @ptrCast(@alignCast(&buffer[offset]));
        height_ptr.* = height;
        offset += 4;

        // Set depth
        tag = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.SetDepth);
        tag.buffer_size = 4;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        var depth_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        depth_ptr.* = depth;
        offset += 4;

        // Allocate buffer
        tag = @ptrCast(@alignCast(&buffer[offset]));
        tag.tag = @intFromEnum(PropertyTag.AllocateFramebuffer);
        tag.buffer_size = 8;
        tag.request_response = 0;
        offset += @sizeOf(PropertyTagHeader);

        var alignment_ptr: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        alignment_ptr.* = 16; // 16-byte alignment
        offset += 4;

        offset += 4; // Space for response

        const end: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        end.* = @intFromEnum(PropertyTag.End);

        try self.mailbox.sendPropertyMessage(buffer[0..256]);

        // Find allocate framebuffer response
        offset = @sizeOf(PropertyMessageHeader);

        // Skip first three tags to get to allocate response
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            offset += @sizeOf(PropertyTagHeader);
            const tag_header: *PropertyTagHeader = @ptrCast(@alignCast(&buffer[offset - @sizeOf(PropertyTagHeader)]));
            offset += tag_header.buffer_size;
        }

        offset += @sizeOf(PropertyTagHeader);
        const base: *u32 = @ptrCast(@alignCast(&buffer[offset]));
        const size: *u32 = @ptrCast(@alignCast(&buffer[offset + 4]));

        return .{ .base = base.* & 0x3FFFFFFF, .size = size.* };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Initialize mailbox for Raspberry Pi 3
pub fn initRaspberryPi3() MailboxDriver {
    return MailboxDriver.init(BCM2835_MAILBOX_BASE);
}

/// Initialize mailbox for Raspberry Pi 4
pub fn initRaspberryPi4() MailboxDriver {
    return MailboxDriver.init(BCM2711_MAILBOX_BASE);
}

// ============================================================================
// Tests
// ============================================================================

test "Mailbox register layout" {
    try Basics.testing.expectEqual(@as(usize, 0x00), @offsetOf(MailboxRegs, "read"));
    try Basics.testing.expectEqual(@as(usize, 0x18), @offsetOf(MailboxRegs, "status"));
    try Basics.testing.expectEqual(@as(usize, 0x20), @offsetOf(MailboxRegs, "write"));
}

test "Mailbox addresses" {
    try Basics.testing.expectEqual(@as(u64, 0x3F00B880), BCM2835_MAILBOX_BASE);
    try Basics.testing.expectEqual(@as(u64, 0xFE00B880), BCM2711_MAILBOX_BASE);
}

test "Property message alignment" {
    try Basics.testing.expectEqual(@as(usize, 8), @sizeOf(PropertyMessageHeader));
    try Basics.testing.expectEqual(@as(usize, 12), @sizeOf(PropertyTagHeader));
}
