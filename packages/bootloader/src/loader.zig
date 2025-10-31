// Kernel Loader
// Loads and prepares kernel for execution

const std = @import("std");
const bootloader = @import("bootloader.zig");

/// ELF header (simplified)
pub const ElfHeader = extern struct {
    magic: [4]u8, // 0x7F, 'E', 'L', 'F'
    class: u8, // 1 = 32-bit, 2 = 64-bit
    data: u8, // 1 = little endian, 2 = big endian
    version: u8,
    os_abi: u8,
    abi_version: u8,
    padding: [7]u8,
    type: u16,
    machine: u16,
    version2: u32,
    entry: u64,
    phoff: u64, // Program header offset
    shoff: u64, // Section header offset
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,

    pub fn isValid(self: *const ElfHeader) bool {
        return self.magic[0] == 0x7F and
            self.magic[1] == 'E' and
            self.magic[2] == 'L' and
            self.magic[3] == 'F';
    }

    pub fn is64Bit(self: *const ElfHeader) bool {
        return self.class == 2;
    }

    pub fn isLittleEndian(self: *const ElfHeader) bool {
        return self.data == 1;
    }
};

/// ELF Program Header
pub const ElfProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alignment: u64,

    pub const Type = enum(u32) {
        null = 0,
        load = 1,
        dynamic = 2,
        interp = 3,
        note = 4,
    };

    pub fn isLoadable(self: *const ElfProgramHeader) bool {
        return self.type == @intFromEnum(Type.load);
    }
};

/// Loaded kernel information
pub const LoadedKernel = struct {
    entry_point: u64,
    load_address: u64,
    size: usize,
    segments: std.ArrayList(Segment),
    allocator: std.mem.Allocator,

    pub const Segment = struct {
        virtual_addr: u64,
        physical_addr: u64,
        size: usize,
        flags: u32,
    };

    pub fn init(allocator: std.mem.Allocator) LoadedKernel {
        return .{
            .entry_point = 0,
            .load_address = 0,
            .size = 0,
            .segments = std.ArrayList(Segment){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LoadedKernel) void {
        self.segments.deinit(self.allocator);
    }

    pub fn addSegment(self: *LoadedKernel, segment: Segment) !void {
        try self.segments.append(self.allocator, segment);
    }
};

/// Kernel loader
pub const KernelLoader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KernelLoader {
        return .{
            .allocator = allocator,
        };
    }

    /// Load kernel from file
    pub fn loadKernel(self: *KernelLoader, kernel_data: []const u8) !LoadedKernel {
        var loaded = LoadedKernel.init(self.allocator);
        errdefer loaded.deinit();

        // Parse ELF header
        if (kernel_data.len < @sizeOf(ElfHeader)) {
            return error.InvalidKernel;
        }

        const elf_header: *const ElfHeader = @ptrCast(@alignCast(kernel_data.ptr));

        if (!elf_header.isValid()) {
            return error.InvalidELF;
        }

        if (!elf_header.is64Bit()) {
            return error.Only64BitSupported;
        }

        loaded.entry_point = elf_header.entry;

        // Parse program headers
        const ph_offset = elf_header.phoff;
        const ph_count = elf_header.phnum;
        const ph_size = elf_header.phentsize;

        var i: usize = 0;
        while (i < ph_count) : (i += 1) {
            const ph_ptr = kernel_data.ptr + ph_offset + (i * ph_size);
            const ph: *const ElfProgramHeader = @ptrCast(@alignCast(ph_ptr));

            if (ph.isLoadable()) {
                const segment = LoadedKernel.Segment{
                    .virtual_addr = ph.vaddr,
                    .physical_addr = ph.paddr,
                    .size = ph.memsz,
                    .flags = ph.flags,
                };

                try loaded.addSegment(segment);

                // Track total size
                if (ph.vaddr + ph.memsz > loaded.size) {
                    loaded.size = ph.vaddr + ph.memsz;
                }
            }
        }

        return loaded;
    }

    /// Verify kernel signature (for secure boot)
    pub fn verifySignature(self: *KernelLoader, kernel_data: []const u8, signature: []const u8) !bool {
        _ = self;
        _ = kernel_data;
        _ = signature;

        // In production, would verify cryptographic signature
        // For now, always return true
        return true;
    }
};

/// Boot protocol handoff
pub const BootProtocol = struct {
    /// Linux boot protocol parameters
    pub const LinuxBootParams = extern struct {
        // Video parameters
        screen_info: [64]u8,

        // APM BIOS info
        apm_bios_info: [20]u8,

        // Drive info
        drive_info: [32]u8,

        // System description table
        sys_desc_table: [16]u8,

        // Memory map
        e820_entries: u8,
        e820_map: [128]E820Entry,

        pub const E820Entry = extern struct {
            addr: u64,
            size: u64,
            type: u32,
        };
    };

    /// Multiboot information structure
    pub const MultibootInfo = extern struct {
        flags: u32,
        mem_lower: u32,
        mem_upper: u32,
        boot_device: u32,
        cmdline: u32,
        mods_count: u32,
        mods_addr: u32,
        syms: [16]u8,
        mmap_length: u32,
        mmap_addr: u32,
    };

    /// Setup boot parameters
    pub fn setupBootParams(
        allocator: std.mem.Allocator,
        kernel: *const LoadedKernel,
        cmdline: []const u8,
    ) !*LinuxBootParams {
        const params = try allocator.create(LinuxBootParams);
        @memset(std.mem.asBytes(params), 0);

        // In production, would populate with actual hardware info
        _ = kernel;
        _ = cmdline;

        return params;
    }
};

test "ELF header validation" {
    const testing = std.testing;

    // Create a valid ELF header
    var header = ElfHeader{
        .magic = [_]u8{ 0x7F, 'E', 'L', 'F' },
        .class = 2, // 64-bit
        .data = 1, // Little endian
        .version = 1,
        .os_abi = 0,
        .abi_version = 0,
        .padding = [_]u8{0} ** 7,
        .type = 2,
        .machine = 0x3E, // x86-64
        .version2 = 1,
        .entry = 0x1000,
        .phoff = 64,
        .shoff = 0,
        .flags = 0,
        .ehsize = 64,
        .phentsize = 56,
        .phnum = 1,
        .shentsize = 64,
        .shnum = 0,
        .shstrndx = 0,
    };

    try testing.expect(header.isValid());
    try testing.expect(header.is64Bit());
    try testing.expect(header.isLittleEndian());

    // Invalid magic
    header.magic[0] = 0x00;
    try testing.expect(!header.isValid());
}

test "loaded kernel" {
    const testing = std.testing;

    var kernel = LoadedKernel.init(testing.allocator);
    defer kernel.deinit();

    kernel.entry_point = 0x100000;
    kernel.load_address = 0x100000;

    const segment = LoadedKernel.Segment{
        .virtual_addr = 0x100000,
        .physical_addr = 0x100000,
        .size = 0x1000,
        .flags = 0x7,
    };

    try kernel.addSegment(segment);

    try testing.expectEqual(@as(u64, 0x100000), kernel.entry_point);
    try testing.expectEqual(@as(usize, 1), kernel.segments.items.len);
}

test "kernel loader initialization" {
    const testing = std.testing;

    var loader = KernelLoader.init(testing.allocator);

    // Create minimal valid ELF
    var kernel_data: [1024]u8 = undefined;
    @memset(&kernel_data, 0);

    const header: *ElfHeader = @ptrCast(@alignCast(&kernel_data));
    header.magic = [_]u8{ 0x7F, 'E', 'L', 'F' };
    header.class = 2;
    header.data = 1;
    header.version = 1;
    header.entry = 0x1000;
    header.phoff = 64;
    header.phnum = 0;
    header.phentsize = 56;

    var loaded = try loader.loadKernel(&kernel_data);
    defer loaded.deinit();

    try testing.expectEqual(@as(u64, 0x1000), loaded.entry_point);
}
