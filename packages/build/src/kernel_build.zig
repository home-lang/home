// Home Programming Language - Kernel Build Target
// Freestanding kernel compilation and image generation

const Basics = @import("basics");
const std = @import("std");

// ============================================================================
// Kernel Build Configuration
// ============================================================================

pub const KernelBuildConfig = struct {
    /// Target architecture
    arch: Architecture,
    /// Optimization mode
    optimize: OptimizeMode,
    /// Enable debug symbols
    debug: bool,
    /// Kernel base address
    kernel_base: u64,
    /// Kernel entry point
    entry_point: []const u8,
    /// Output format
    format: OutputFormat,
    /// Linker script path
    linker_script: ?[]const u8,

    pub const Architecture = enum {
        x86_64,
        aarch64,
        riscv64,
    };

    pub const OptimizeMode = enum {
        Debug,
        ReleaseSafe,
        ReleaseFast,
        ReleaseSmall,
    };

    pub const OutputFormat = enum {
        ELF,
        PE,
        Raw,
        Multiboot,
        Multiboot2,
    };

    pub fn default() KernelBuildConfig {
        return .{
            .arch = .x86_64,
            .optimize = .ReleaseSafe,
            .debug = true,
            .kernel_base = 0xFFFFFFFF80000000,
            .entry_point = "_start",
            .format = .Multiboot2,
            .linker_script = null,
        };
    }
};

// ============================================================================
// Multiboot Header Generation
// ============================================================================

pub const MultibootHeader = struct {
    magic: u32,
    architecture: u32,
    header_length: u32,
    checksum: u32,
    // Tags follow

    pub const MAGIC = 0xE85250D6;
    pub const ARCHITECTURE_I386 = 0;
    pub const TAG_END = 0;
    pub const TAG_FRAMEBUFFER = 5;
    pub const TAG_MODULE_ALIGN = 6;

    pub fn generate(allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        // Header
        const magic: u32 = MAGIC;
        const arch: u32 = ARCHITECTURE_I386;
        const header_length: u32 = 16; // Basic header size

        try writer.writeInt(u32, magic, .little);
        try writer.writeInt(u32, arch, .little);
        try writer.writeInt(u32, header_length, .little);

        // Checksum: -(magic + architecture + header_length)
        const checksum: u32 = @bitCast(-((@as(i64, magic) + @as(i64, arch) + @as(i64, header_length))));
        try writer.writeInt(u32, checksum, .little);

        // Framebuffer tag
        try writer.writeInt(u16, TAG_FRAMEBUFFER, .little);
        try writer.writeInt(u16, 0, .little); // Flags
        try writer.writeInt(u32, 20, .little); // Size
        try writer.writeInt(u32, 1024, .little); // Width
        try writer.writeInt(u32, 768, .little); // Height
        try writer.writeInt(u32, 32, .little); // Depth

        // Module alignment tag
        try writer.writeInt(u16, TAG_MODULE_ALIGN, .little);
        try writer.writeInt(u16, 0, .little); // Flags
        try writer.writeInt(u32, 8, .little); // Size

        // End tag
        try writer.writeInt(u16, TAG_END, .little);
        try writer.writeInt(u16, 0, .little); // Flags
        try writer.writeInt(u32, 8, .little); // Size

        return buffer.toOwnedSlice();
    }
};

// ============================================================================
// Linker Script Generation
// ============================================================================

pub const LinkerScript = struct {
    config: KernelBuildConfig,

    pub fn init(config: KernelBuildConfig) LinkerScript {
        return .{ .config = config };
    }

    pub fn generate(self: *const LinkerScript, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        // Output format
        try writer.print("OUTPUT_FORMAT(elf64-x86-64)\n", .{});
        try writer.print("OUTPUT_ARCH(i386:x86-64)\n", .{});
        try writer.print("ENTRY({s})\n\n", .{self.config.entry_point});

        // Memory layout
        try writer.print("KERNEL_BASE = 0x{X};\n\n", .{self.config.kernel_base});

        // Sections
        try writer.writeAll(
            \\SECTIONS
            \\{
            \\    . = KERNEL_BASE;
            \\    kernel_start = .;
            \\
            \\    /* Multiboot header must be in first 8KB */
            \\    .multiboot ALIGN(4K) : AT(ADDR(.multiboot) - KERNEL_BASE)
            \\    {
            \\        KEEP(*(.multiboot))
            \\    }
            \\
            \\    /* Text section - executable code */
            \\    .text ALIGN(4K) : AT(ADDR(.text) - KERNEL_BASE)
            \\    {
            \\        *(.text.boot)
            \\        *(.text)
            \\        *(.text.*)
            \\    }
            \\
            \\    /* Read-only data */
            \\    .rodata ALIGN(4K) : AT(ADDR(.rodata) - KERNEL_BASE)
            \\    {
            \\        *(.rodata)
            \\        *(.rodata.*)
            \\    }
            \\
            \\    /* Initialized data */
            \\    .data ALIGN(4K) : AT(ADDR(.data) - KERNEL_BASE)
            \\    {
            \\        *(.data)
            \\        *(.data.*)
            \\    }
            \\
            \\    /* Uninitialized data */
            \\    .bss ALIGN(4K) : AT(ADDR(.bss) - KERNEL_BASE)
            \\    {
            \\        bss_start = .;
            \\        *(.bss)
            \\        *(.bss.*)
            \\        *(COMMON)
            \\        bss_end = .;
            \\    }
            \\
            \\    kernel_end = .;
            \\
            \\    /* Discard unwanted sections */
            \\    /DISCARD/ :
            \\    {
            \\        *(.eh_frame)
            \\        *(.note.*)
            \\        *(.comment)
            \\    }
            \\}
            \\
            \\
        );

        return buffer.toOwnedSlice();
    }
};

// ============================================================================
// Kernel Build System
// ============================================================================

pub const KernelBuilder = struct {
    config: KernelBuildConfig,
    allocator: std.mem.Allocator,
    source_files: std.ArrayList([]const u8),
    include_dirs: std.ArrayList([]const u8),
    defines: std.ArrayList(Define),

    const Define = struct {
        name: []const u8,
        value: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: KernelBuildConfig) KernelBuilder {
        return .{
            .config = config,
            .allocator = allocator,
            .source_files = std.ArrayList([]const u8).init(allocator),
            .include_dirs = std.ArrayList([]const u8).init(allocator),
            .defines = std.ArrayList(Define).init(allocator),
        };
    }

    pub fn deinit(self: *KernelBuilder) void {
        self.source_files.deinit();
        self.include_dirs.deinit();
        self.defines.deinit();
    }

    pub fn addSourceFile(self: *KernelBuilder, path: []const u8) !void {
        try self.source_files.append(path);
    }

    pub fn addIncludeDir(self: *KernelBuilder, path: []const u8) !void {
        try self.include_dirs.append(path);
    }

    pub fn addDefine(self: *KernelBuilder, name: []const u8, value: ?[]const u8) !void {
        try self.defines.append(.{ .name = name, .value = value });
    }

    pub fn getCompilerFlags(self: *const KernelBuilder, allocator: std.mem.Allocator) ![]const []const u8 {
        var flags = std.ArrayList([]const u8).init(allocator);
        errdefer flags.deinit();

        // Freestanding compilation
        try flags.append("-ffreestanding");
        try flags.append("-nostdlib");
        try flags.append("-nostartfiles");
        try flags.append("-nodefaultlibs");

        // Disable red zone (required for kernel)
        try flags.append("-mno-red-zone");

        // Disable SSE/AVX (must save/restore in kernel)
        try flags.append("-mno-sse");
        try flags.append("-mno-sse2");
        try flags.append("-mno-mmx");
        try flags.append("-mno-3dnow");

        // Position independent code
        try flags.append("-fno-pic");
        try flags.append("-fno-pie");

        // Stack protection
        try flags.append("-fno-stack-protector");

        // Optimization
        switch (self.config.optimize) {
            .Debug => try flags.append("-O0"),
            .ReleaseSafe => try flags.append("-O2"),
            .ReleaseFast => try flags.append("-O3"),
            .ReleaseSmall => try flags.append("-Os"),
        }

        // Debug symbols
        if (self.config.debug) {
            try flags.append("-g");
        }

        // Architecture-specific
        switch (self.config.arch) {
            .x86_64 => {
                try flags.append("-m64");
                try flags.append("-mcmodel=kernel");
            },
            .aarch64 => {
                try flags.append("-march=armv8-a");
            },
            .riscv64 => {
                try flags.append("-march=rv64gc");
            },
        }

        // Include directories
        for (self.include_dirs.items) |dir| {
            try flags.append(try std.fmt.allocPrint(allocator, "-I{s}", .{dir}));
        }

        // Defines
        for (self.defines.items) |define| {
            if (define.value) |value| {
                try flags.append(try std.fmt.allocPrint(allocator, "-D{s}={s}", .{ define.name, value }));
            } else {
                try flags.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define.name}));
            }
        }

        return flags.toOwnedSlice();
    }

    pub fn getLinkerFlags(self: *const KernelBuilder, allocator: std.mem.Allocator) ![]const []const u8 {
        var flags = std.ArrayList([]const u8).init(allocator);
        errdefer flags.deinit();

        // Freestanding linking
        try flags.append("-nostdlib");

        // Static linking
        try flags.append("-static");

        // Linker script
        if (self.config.linker_script) |script| {
            try flags.append(try std.fmt.allocPrint(allocator, "-T{s}", .{script}));
        }

        return flags.toOwnedSlice();
    }

    pub fn build(self: *KernelBuilder, output_path: []const u8) !void {
        _ = output_path;

        // Generate linker script if not provided
        if (self.config.linker_script == null) {
            const linker = LinkerScript.init(self.config);
            const script_content = try linker.generate(self.allocator);
            defer self.allocator.free(script_content);

            const script_path = "kernel.ld";
            const file = try std.fs.cwd().createFile(script_path, .{});
            defer file.close();

            try file.writeAll(script_content);
        }

        // Generate multiboot header if needed
        if (self.config.format == .Multiboot2) {
            const header = try MultibootHeader.generate(self.allocator);
            defer self.allocator.free(header);

            const header_file = try std.fs.cwd().createFile("multiboot.bin", .{});
            defer header_file.close();

            try header_file.writeAll(header);
        }

        // In a real implementation, this would:
        // 1. Compile all source files
        // 2. Link object files
        // 3. Generate kernel image
        // 4. Create bootable ISO if requested
    }
};

// ============================================================================
// Kernel Image Generation
// ============================================================================

pub const KernelImage = struct {
    data: []const u8,
    entry_point: u64,
    load_address: u64,

    pub fn fromElf(allocator: std.mem.Allocator, elf_data: []const u8) !KernelImage {
        // Simplified ELF parsing
        if (elf_data.len < 64) return error.InvalidElf;

        // Check ELF magic
        if (!std.mem.eql(u8, elf_data[0..4], "\x7FELF")) {
            return error.InvalidElfMagic;
        }

        // Read entry point (at offset 0x18 for 64-bit ELF)
        const entry_point = std.mem.readInt(u64, elf_data[0x18..0x20], .little);

        // Read load address from program headers
        const ph_off = std.mem.readInt(u64, elf_data[0x20..0x28], .little);
        const load_address = if (ph_off > 0 and ph_off < elf_data.len - 56) blk: {
            const ph_data = elf_data[@intCast(ph_off)..];
            const p_vaddr = std.mem.readInt(u64, ph_data[16..24], .little);
            break :blk p_vaddr;
        } else 0;

        return .{
            .data = try allocator.dupe(u8, elf_data),
            .entry_point = entry_point,
            .load_address = load_address,
        };
    }

    pub fn toRawBinary(self: KernelImage, allocator: std.mem.Allocator) ![]const u8 {
        // Extract loadable segments from ELF
        // For now, just return the data as-is
        return allocator.dupe(u8, self.data);
    }

    pub fn deinit(self: KernelImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

// ============================================================================
// ISO Generation (Bootable CD/DVD)
// ============================================================================

pub const IsoBuilder = struct {
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    grub_config: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, kernel_path: []const u8) IsoBuilder {
        return .{
            .allocator = allocator,
            .kernel_path = kernel_path,
            .grub_config = null,
        };
    }

    pub fn setGrubConfig(self: *IsoBuilder, config: []const u8) void {
        self.grub_config = config;
    }

    pub fn generateDefaultGrubConfig(self: *const IsoBuilder, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        try writer.writeAll(
            \\set timeout=0
            \\set default=0
            \\
            \\menuentry "Home OS" {
            \\    multiboot2 /boot/kernel.bin
            \\    boot
            \\}
            \\
        );

        return buffer.toOwnedSlice();
    }

    pub fn build(self: *IsoBuilder, output_path: []const u8) !void {
        _ = output_path;

        // Create iso directory structure
        try std.fs.cwd().makePath("iso/boot/grub");

        // Copy kernel
        try std.fs.cwd().copyFile(self.kernel_path, std.fs.cwd(), "iso/boot/kernel.bin", .{});

        // Generate GRUB config
        const config = if (self.grub_config) |cfg|
            cfg
        else
            try self.generateDefaultGrubConfig(self.allocator);

        defer if (self.grub_config == null) self.allocator.free(config);

        const grub_cfg_file = try std.fs.cwd().createFile("iso/boot/grub/grub.cfg", .{});
        defer grub_cfg_file.close();

        try grub_cfg_file.writeAll(config);

        // In a real implementation, this would call grub-mkrescue:
        // grub-mkrescue -o output.iso iso/
    }
};

// ============================================================================
// Tests
// ============================================================================

test "kernel build config" {
    const config = KernelBuildConfig.default();
    try std.testing.expectEqual(KernelBuildConfig.Architecture.x86_64, config.arch);
    try std.testing.expect(config.debug);
}

test "linker script generation" {
    const config = KernelBuildConfig.default();
    const linker = LinkerScript.init(config);

    const script = try linker.generate(std.testing.allocator);
    defer std.testing.allocator.free(script);

    try std.testing.expect(script.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, script, "OUTPUT_FORMAT") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, ".text") != null);
}

test "multiboot header generation" {
    const header = try MultibootHeader.generate(std.testing.allocator);
    defer std.testing.allocator.free(header);

    try std.testing.expect(header.len >= 16);

    const magic = std.mem.readInt(u32, header[0..4], .little);
    try std.testing.expectEqual(@as(u32, MultibootHeader.MAGIC), magic);
}

test "compiler flags generation" {
    const config = KernelBuildConfig.default();
    var builder = KernelBuilder.init(std.testing.allocator, config);
    defer builder.deinit();

    try builder.addDefine("KERNEL_VERSION", "\"1.0.0\"");

    const flags = try builder.getCompilerFlags(std.testing.allocator);
    defer {
        for (flags) |flag| {
            std.testing.allocator.free(flag);
        }
        std.testing.allocator.free(flags);
    }

    try std.testing.expect(flags.len > 0);

    // Check for freestanding flag
    var found_freestanding = false;
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, "-ffreestanding")) {
            found_freestanding = true;
            break;
        }
    }
    try std.testing.expect(found_freestanding);
}
