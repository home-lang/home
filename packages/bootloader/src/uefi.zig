// UEFI Boot Protocol Implementation
// Interfaces with UEFI firmware

const std = @import("std");

/// UEFI Handle (opaque pointer)
pub const Handle = *anyopaque;

/// UEFI Status codes
pub const Status = enum(usize) {
    success = 0,
    load_error = 1,
    invalid_parameter = 2,
    unsupported = 3,
    bad_buffer_size = 4,
    buffer_too_small = 5,
    not_ready = 6,
    device_error = 7,
    write_protected = 8,
    out_of_resources = 9,
    volume_corrupted = 10,
    volume_full = 11,
    no_media = 12,
    media_changed = 13,
    not_found = 14,
    access_denied = 15,
    no_response = 16,
    no_mapping = 17,
    timeout = 18,
    not_started = 19,
    already_started = 20,
    aborted = 21,
    security_violation = 26,
};

/// UEFI GUID
pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn eql(self: Guid, other: Guid) bool {
        return self.data1 == other.data1 and
            self.data2 == other.data2 and
            self.data3 == other.data3 and
            std.mem.eql(u8, &self.data4, &other.data4);
    }
};

/// UEFI Memory Type
pub const MemoryType = enum(u32) {
    reserved = 0,
    loader_code = 1,
    loader_data = 2,
    boot_services_code = 3,
    boot_services_data = 4,
    runtime_services_code = 5,
    runtime_services_data = 6,
    conventional = 7,
    unusable = 8,
    acpi_reclaim = 9,
    acpi_nvs = 10,
    memory_mapped_io = 11,
    memory_mapped_io_port_space = 12,
    pal_code = 13,
    persistent = 14,
};

/// UEFI Memory Descriptor
pub const MemoryDescriptor = extern struct {
    type: MemoryType,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: u64,
};

/// UEFI Boot Services (simplified)
pub const BootServices = extern struct {
    hdr: TableHeader,

    // Memory allocation
    allocate_pages: *const fn (AllocateType, MemoryType, usize, *u64) callconv(.C) Status,
    free_pages: *const fn (u64, usize) callconv(.C) Status,
    get_memory_map: *const fn (*usize, *MemoryDescriptor, *usize, *usize, *u32) callconv(.C) Status,
    allocate_pool: *const fn (MemoryType, usize, **anyopaque) callconv(.C) Status,
    free_pool: *const fn (*anyopaque) callconv(.C) Status,

    // Protocol handler services (placeholder)
    _reserved: [32]*anyopaque,

    // Image services
    load_image: *const fn (bool, Handle, ?*anyopaque, ?*anyopaque, usize, *Handle) callconv(.C) Status,
    start_image: *const fn (Handle, ?*usize, ?**u16) callconv(.C) Status,
    exit: *const fn (Handle, Status, usize, ?*u16) callconv(.C) noreturn,

    pub const AllocateType = enum(u32) {
        any_pages = 0,
        max_address = 1,
        address = 2,
    };
};

/// UEFI Runtime Services (simplified)
pub const RuntimeServices = extern struct {
    hdr: TableHeader,

    // Time services
    get_time: *const fn (*Time, ?*TimeCapabilities) callconv(.C) Status,
    set_time: *const fn (*Time) callconv(.C) Status,

    // Variable services
    get_variable: *const fn (*u16, *Guid, ?*u32, *usize, *anyopaque) callconv(.C) Status,
    get_next_variable_name: *const fn (*usize, *u16, *Guid) callconv(.C) Status,
    set_variable: *const fn (*u16, *Guid, u32, usize, *anyopaque) callconv(.C) Status,

    // Reset services
    reset_system: *const fn (ResetType, Status, usize, ?*anyopaque) callconv(.C) noreturn,

    pub const ResetType = enum(u32) {
        cold = 0,
        warm = 1,
        shutdown = 2,
    };
};

/// UEFI Table Header
pub const TableHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    crc32: u32,
    reserved: u32,
};

/// UEFI System Table
pub const SystemTable = extern struct {
    hdr: TableHeader,
    firmware_vendor: [*:0]u16,
    firmware_revision: u32,
    console_in_handle: Handle,
    con_in: *anyopaque,
    console_out_handle: Handle,
    con_out: *SimpleTextOutput,
    standard_error_handle: Handle,
    std_err: *SimpleTextOutput,
    runtime_services: *RuntimeServices,
    boot_services: *BootServices,
    number_of_table_entries: usize,
    configuration_table: [*]ConfigurationTable,
};

/// UEFI Simple Text Output Protocol
pub const SimpleTextOutput = extern struct {
    reset: *const fn (*SimpleTextOutput, bool) callconv(.C) Status,
    output_string: *const fn (*SimpleTextOutput, [*:0]const u16) callconv(.C) Status,
    test_string: *const fn (*SimpleTextOutput, [*:0]const u16) callconv(.C) Status,
    query_mode: *const fn (*SimpleTextOutput, usize, *usize, *usize) callconv(.C) Status,
    set_mode: *const fn (*SimpleTextOutput, usize) callconv(.C) Status,
    set_attribute: *const fn (*SimpleTextOutput, usize) callconv(.C) Status,
    clear_screen: *const fn (*SimpleTextOutput) callconv(.C) Status,
    set_cursor_position: *const fn (*SimpleTextOutput, usize, usize) callconv(.C) Status,
    enable_cursor: *const fn (*SimpleTextOutput, bool) callconv(.C) Status,
    mode: *SimpleTextOutputMode,
};

/// Simple Text Output Mode
pub const SimpleTextOutputMode = extern struct {
    max_mode: i32,
    mode: i32,
    attribute: i32,
    cursor_column: i32,
    cursor_row: i32,
    cursor_visible: bool,
};

/// UEFI Time
pub const Time = extern struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    pad1: u8,
    nanosecond: u32,
    timezone: i16,
    daylight: u8,
    pad2: u8,
};

/// Time Capabilities
pub const TimeCapabilities = extern struct {
    resolution: u32,
    accuracy: u32,
    sets_to_zero: bool,
};

/// Configuration Table
pub const ConfigurationTable = extern struct {
    vendor_guid: Guid,
    vendor_table: *anyopaque,
};

/// UEFI helper functions
pub const UEFIHelper = struct {
    /// Convert ASCII string to UEFI UTF-16 string
    pub fn asciiToUTF16(allocator: std.mem.Allocator, ascii: []const u8) ![]u16 {
        const utf16 = try allocator.alloc(u16, ascii.len + 1);
        for (ascii, 0..) |byte, i| {
            utf16[i] = byte;
        }
        utf16[ascii.len] = 0; // Null terminator
        return utf16;
    }

    /// Print string to UEFI console
    pub fn print(con_out: *SimpleTextOutput, str: []const u8, allocator: std.mem.Allocator) !void {
        const utf16 = try asciiToUTF16(allocator, str);
        defer allocator.free(utf16);

        _ = con_out.output_string(con_out, @ptrCast(utf16.ptr));
    }

    /// Clear screen
    pub fn clearScreen(con_out: *SimpleTextOutput) void {
        _ = con_out.clear_screen(con_out);
    }
};

test "GUID equality" {
    const testing = std.testing;

    const guid1 = Guid{
        .data1 = 0x12345678,
        .data2 = 0x9ABC,
        .data3 = 0xDEF0,
        .data4 = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
    };

    const guid2 = Guid{
        .data1 = 0x12345678,
        .data2 = 0x9ABC,
        .data3 = 0xDEF0,
        .data4 = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
    };

    const guid3 = Guid{
        .data1 = 0x12345679,
        .data2 = 0x9ABC,
        .data3 = 0xDEF0,
        .data4 = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
    };

    try testing.expect(guid1.eql(guid2));
    try testing.expect(!guid1.eql(guid3));
}

test "ASCII to UTF-16 conversion" {
    const testing = std.testing;

    const ascii = "Hello, UEFI!";
    const utf16 = try UEFIHelper.asciiToUTF16(testing.allocator, ascii);
    defer testing.allocator.free(utf16);

    try testing.expectEqual(@as(usize, ascii.len + 1), utf16.len);
    try testing.expectEqual(@as(u16, 0), utf16[utf16.len - 1]);
    try testing.expectEqual(@as(u16, 'H'), utf16[0]);
}
