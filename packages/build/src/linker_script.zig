// Home Programming Language - Custom Linker Script Support
// Memory layout and linker script generation for embedded/OS development

const std = @import("std");

// ============================================================================
// Memory Region Definition
// ============================================================================

pub const MemoryRegion = struct {
    name: []const u8,
    origin: u64, // Start address
    length: u64, // Size in bytes
    attributes: MemoryAttributes,

    pub const MemoryAttributes = packed struct(u8) {
        readable: bool = true,
        writable: bool = true,
        executable: bool = false,
        allocatable: bool = true,
        initialized: bool = false,
        _padding: u3 = 0,
    };

    pub fn init(name: []const u8, origin: u64, length: u64, attributes: MemoryAttributes) MemoryRegion {
        return .{
            .name = name,
            .origin = origin,
            .length = length,
            .attributes = attributes,
        };
    }

    pub fn format(self: MemoryRegion, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} (origin=0x{x}, length=0x{x})", .{ self.name, self.origin, self.length });
    }
};

// ============================================================================
// Section Definition
// ============================================================================

pub const Section = struct {
    name: []const u8,
    type_: SectionType,
    address: ?u64 = null, // Fixed address (optional)
    align_: u32 = 1, // Alignment requirement
    region: ?[]const u8 = null, // Target memory region
    load_region: ?[]const u8 = null, // LMA region (for initialized data in ROM)
    keep: bool = false, // Prevent garbage collection
    fill: ?u8 = null, // Fill pattern for gaps
    input_sections: std.ArrayList([]const u8),
    flags: SectionFlags,
    allocator: std.mem.Allocator,

    pub const SectionType = enum {
        Text, // Code
        Data, // Initialized data
        Bss, // Uninitialized data
        RoData, // Read-only data
        Stack,
        Heap,
        Custom,
    };

    pub const SectionFlags = packed struct(u8) {
        allocate: bool = true,
        write: bool = false,
        execute: bool = false,
        merge: bool = false,
        strings: bool = false,
        _padding: u3 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, type_: SectionType) Section {
        return .{
            .name = name,
            .type_ = type_,
            .input_sections = .{},
            .flags = flagsFromType(type_),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Section) void {
        self.input_sections.deinit(self.allocator);
    }

    fn flagsFromType(type_: SectionType) SectionFlags {
        return switch (type_) {
            .Text => .{ .allocate = true, .execute = true },
            .Data => .{ .allocate = true, .write = true },
            .Bss => .{ .allocate = true, .write = true },
            .RoData => .{ .allocate = true },
            .Stack => .{ .allocate = true, .write = true },
            .Heap => .{ .allocate = true, .write = true },
            .Custom => .{},
        };
    }

    pub fn addInputSection(self: *Section, pattern: []const u8) !void {
        try self.input_sections.append(self.allocator, pattern);
    }
};

// ============================================================================
// Symbol Definition
// ============================================================================

pub const Symbol = struct {
    name: []const u8,
    value: SymbolValue,
    binding: Binding = .Global,

    pub const SymbolValue = union(enum) {
        Address: u64,
        Expression: []const u8,
        SectionStart: []const u8,
        SectionEnd: []const u8,
        SectionSize: []const u8,
    };

    pub const Binding = enum {
        Local,
        Global,
        Weak,
    };
};

// ============================================================================
// Linker Script Configuration
// ============================================================================

pub const LinkerScript = struct {
    allocator: std.mem.Allocator,
    /// Entry point symbol
    entry: []const u8,
    /// Memory regions
    memory: std.ArrayList(MemoryRegion),
    /// Sections
    sections: std.ArrayList(Section),
    /// Symbols to define
    symbols: std.ArrayList(Symbol),
    /// Output format
    output_format: []const u8,
    /// Architecture
    architecture: []const u8,

    pub fn init(allocator: std.mem.Allocator) LinkerScript {
        return .{
            .allocator = allocator,
            .entry = "_start",
            .memory = .{},
            .sections = .{},
            .symbols = .{},
            .output_format = "elf64-x86-64",
            .architecture = "i386:x86-64",
        };
    }

    pub fn deinit(self: *LinkerScript) void {
        self.memory.deinit(self.allocator);
        for (self.sections.items) |*section| {
            section.deinit();
        }
        self.sections.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }

    /// Add memory region
    pub fn addMemory(self: *LinkerScript, region: MemoryRegion) !void {
        try self.memory.append(self.allocator, region);
    }

    /// Add section
    pub fn addSection(self: *LinkerScript, section: Section) !void {
        try self.sections.append(self.allocator, section);
    }

    /// Add symbol definition
    pub fn addSymbol(self: *LinkerScript, symbol: Symbol) !void {
        try self.symbols.append(self.allocator, symbol);
    }

    /// Generate GNU LD linker script
    pub fn generateGnuLd(self: *LinkerScript, writer: anytype) !void {
        // Output format and architecture
        try writer.print("OUTPUT_FORMAT({s})\n", .{self.output_format});
        try writer.print("OUTPUT_ARCH({s})\n", .{self.architecture});
        try writer.print("ENTRY({s})\n\n", .{self.entry});

        // Memory regions
        if (self.memory.items.len > 0) {
            try writer.writeAll("MEMORY\n{\n");
            for (self.memory.items) |region| {
                try writer.print("  {s} ", .{region.name});

                // Attributes
                try writer.writeAll("(");
                if (region.attributes.readable) try writer.writeAll("r");
                if (region.attributes.writable) try writer.writeAll("w");
                if (region.attributes.executable) try writer.writeAll("x");
                if (region.attributes.allocatable) try writer.writeAll("a");
                if (region.attributes.initialized) try writer.writeAll("i");
                try writer.writeAll(") ");

                try writer.print(": ORIGIN = 0x{X:0>8}, LENGTH = 0x{X:0>8}\n", .{ region.origin, region.length });
            }
            try writer.writeAll("}\n\n");
        }

        // Sections
        try writer.writeAll("SECTIONS\n{\n");

        for (self.sections.items) |section| {
            try self.generateSection(section, writer);
        }

        try writer.writeAll("}\n");
    }

    fn generateSection(self: *LinkerScript, section: Section, writer: anytype) !void {
        _ = self;

        // Section header
        try writer.print("  {s} ", .{section.name});

        // Address
        if (section.address) |addr| {
            try writer.print("0x{X:0>8} ", .{addr});
        }

        // Alignment
        if (section.align_ > 1) {
            try writer.print("ALIGN({d}) ", .{section.align_});
        }

        // Region
        if (section.region) |region| {
            try writer.print(">  {s} ", .{region});
            if (section.load_region) |load_region| {
                try writer.print("AT> {s} ", .{load_region});
            }
        }

        try writer.writeAll(":\n  {\n");

        // Keep directive
        if (section.keep) {
            try writer.writeAll("    KEEP(");
        }

        // Input sections
        for (section.input_sections.items) |pattern| {
            try writer.print("    *({s})\n", .{pattern});
        }

        if (section.keep) {
            try writer.writeAll("    )\n");
        }

        // Fill
        if (section.fill) |fill_byte| {
            try writer.print("    FILL(0x{X:0>2})\n", .{fill_byte});
        }

        try writer.writeAll("  }\n\n");
    }

    /// Generate LLD linker script
    pub fn generateLld(self: *LinkerScript, writer: anytype) !void {
        // LLD has similar syntax to GNU LD
        try self.generateGnuLd(writer);
    }

    /// Parse GNU LD linker script
    pub fn parseGnuLd(allocator: std.mem.Allocator, script: []const u8) !LinkerScript {
        var result = LinkerScript.init(allocator);
        errdefer result.deinit();

        // Simple parser - in production would use proper lexer/parser
        var lines = std.mem.split(u8, script, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse ENTRY
            if (std.mem.startsWith(u8, trimmed, "ENTRY(")) {
                // Extract entry point from: ENTRY(symbol_name)
                if (std.mem.indexOf(u8, trimmed, "(")) |paren_start| {
                    if (std.mem.indexOf(u8, trimmed[paren_start + 1 ..], ")")) |paren_end_rel| {
                        const entry_symbol = std.mem.trim(u8, trimmed[paren_start + 1 .. paren_start + 1 + paren_end_rel], " \t");
                        if (entry_symbol.len > 0) {
                            result.entry_point = try allocator.dupe(u8, entry_symbol);
                        }
                    }
                }
            }

            // Parse MEMORY
            // Parse SECTIONS
            // etc.
        }

        return result;
    }

    /// Validate linker script
    pub fn validate(self: *LinkerScript) !void {
        // Check for overlapping memory regions
        for (self.memory.items, 0..) |region1, i| {
            for (self.memory.items[i + 1 ..]) |region2| {
                const end1 = region1.origin + region1.length;
                const end2 = region2.origin + region2.length;

                if (region1.origin < end2 and region2.origin < end1) {
                    std.debug.print("Warning: Memory regions '{s}' and '{s}' overlap\n", .{ region1.name, region2.name });
                }
            }
        }

        // Check section regions exist
        for (self.sections.items) |section| {
            if (section.region) |region_name| {
                var found = false;
                for (self.memory.items) |region| {
                    if (std.mem.eql(u8, region.name, region_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    return error.InvalidMemoryRegion;
                }
            }
        }
    }
};

// ============================================================================
// Common Target Configurations
// ============================================================================

pub const TargetConfig = struct {
    /// ARM Cortex-M bare metal
    pub fn armCortexM(allocator: std.mem.Allocator, flash_size: u64, ram_size: u64) !LinkerScript {
        var script = LinkerScript.init(allocator);
        script.entry = "Reset_Handler";
        script.output_format = "elf32-littlearm";
        script.architecture = "arm";

        // Flash memory (code + constants)
        try script.addMemory(MemoryRegion.init(
            "FLASH",
            0x08000000,
            flash_size,
            .{ .readable = true, .executable = true, .allocatable = true },
        ));

        // RAM (data + stack + heap)
        try script.addMemory(MemoryRegion.init(
            "RAM",
            0x20000000,
            ram_size,
            .{ .readable = true, .writable = true, .allocatable = true },
        ));

        // Vector table
        var vectors = Section.init(allocator, ".isr_vector", .Custom);
        vectors.address = 0x08000000;
        vectors.region = "FLASH";
        vectors.keep = true;
        try vectors.addInputSection(".isr_vector");
        try script.addSection(vectors);

        // Code
        var text = Section.init(allocator, ".text", .Text);
        text.region = "FLASH";
        try text.addInputSection(".text*");
        try script.addSection(text);

        // Read-only data
        var rodata = Section.init(allocator, ".rodata", .RoData);
        rodata.region = "FLASH";
        try rodata.addInputSection(".rodata*");
        try script.addSection(rodata);

        // Initialized data (VMA in RAM, LMA in FLASH)
        var data = Section.init(allocator, ".data", .Data);
        data.region = "RAM";
        data.load_region = "FLASH";
        try data.addInputSection(".data*");
        try script.addSection(data);

        // Uninitialized data
        var bss = Section.init(allocator, ".bss", .Bss);
        bss.region = "RAM";
        bss.fill = 0;
        try bss.addInputSection(".bss*");
        try bss.addInputSection("COMMON");
        try script.addSection(bss);

        // Stack
        try script.addSymbol(.{
            .name = "_stack_start",
            .value = .{ .Expression = "ORIGIN(RAM) + LENGTH(RAM)" },
        });

        return script;
    }

    /// x86-64 kernel
    pub fn x86_64Kernel(allocator: std.mem.Allocator, kernel_base: u64) !LinkerScript {
        var script = LinkerScript.init(allocator);
        script.entry = "_start";

        // Kernel code/data
        try script.addMemory(MemoryRegion.init(
            "KERNEL",
            kernel_base,
            64 * 1024 * 1024, // 64MB
            .{ .readable = true, .writable = true, .executable = true, .allocatable = true },
        ));

        // Boot section (multiboot2)
        var boot = Section.init(allocator, ".boot", .Custom);
        boot.address = kernel_base;
        boot.region = "KERNEL";
        boot.keep = true;
        try boot.addInputSection(".multiboot");
        try boot.addInputSection(".boot*");
        try script.addSection(boot);

        // Text
        var text = Section.init(allocator, ".text", .Text);
        text.align_ = 4096;
        text.region = "KERNEL";
        try text.addInputSection(".text*");
        try script.addSection(text);

        // RO data
        var rodata = Section.init(allocator, ".rodata", .RoData);
        rodata.align_ = 4096;
        rodata.region = "KERNEL";
        try rodata.addInputSection(".rodata*");
        try script.addSection(rodata);

        // Data
        var data = Section.init(allocator, ".data", .Data);
        data.align_ = 4096;
        data.region = "KERNEL";
        try data.addInputSection(".data*");
        try script.addSection(data);

        // BSS
        var bss = Section.init(allocator, ".bss", .Bss);
        bss.align_ = 4096;
        bss.region = "KERNEL";
        try bss.addInputSection(".bss*");
        try bss.addInputSection("COMMON");
        try script.addSection(bss);

        // Kernel symbols
        try script.addSymbol(.{ .name = "_kernel_start", .value = .{ .Address = kernel_base } });
        try script.addSymbol(.{ .name = "_kernel_end", .value = .{ .SectionEnd = ".bss" } });
        try script.addSymbol(.{ .name = "_kernel_size", .value = .{ .SectionSize = ".bss" } });

        return script;
    }

    /// RISC-V bare metal
    pub fn riscvBareMetal(allocator: std.mem.Allocator, ram_base: u64, ram_size: u64) !LinkerScript {
        var script = LinkerScript.init(allocator);
        script.entry = "_start";
        script.output_format = "elf32-littleriscv";
        script.architecture = "riscv";

        // Single RAM region
        try script.addMemory(MemoryRegion.init(
            "RAM",
            ram_base,
            ram_size,
            .{ .readable = true, .writable = true, .executable = true, .allocatable = true },
        ));

        // Text
        var text = Section.init(allocator, ".text", .Text);
        text.address = ram_base;
        text.region = "RAM";
        try text.addInputSection(".text.init");
        try text.addInputSection(".text*");
        try script.addSection(text);

        // RO data
        var rodata = Section.init(allocator, ".rodata", .RoData);
        rodata.region = "RAM";
        try rodata.addInputSection(".rodata*");
        try script.addSection(rodata);

        // Data
        var data = Section.init(allocator, ".data", .Data);
        data.region = "RAM";
        try data.addInputSection(".data*");
        try script.addSection(data);

        // BSS
        var bss = Section.init(allocator, ".bss", .Bss);
        bss.region = "RAM";
        try bss.addInputSection(".bss*");
        try bss.addInputSection("COMMON");
        try script.addSection(bss);

        // Stack at end of RAM
        try script.addSymbol(.{
            .name = "_sp",
            .value = .{ .Expression = "ORIGIN(RAM) + LENGTH(RAM)" },
        });

        return script;
    }
};

// ============================================================================
// Linker Invocation
// ============================================================================

pub const LinkerType = enum {
    GnuLd,
    Lld,
    Mold,
    Gold,
};

pub const LinkerConfig = struct {
    type_: LinkerType = .Lld,
    script_path: ?[]const u8 = null,
    output_path: []const u8,
    object_files: []const []const u8,
    libraries: []const []const u8 = &[_][]const u8{},
    library_paths: []const []const u8 = &[_][]const u8{},
    dynamic: bool = false,
    strip: bool = false,
    gc_sections: bool = true,
    verbose: bool = false,
};

pub const Linker = struct {
    allocator: std.mem.Allocator,
    config: LinkerConfig,

    pub fn init(allocator: std.mem.Allocator, config: LinkerConfig) Linker {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Build linker command
    pub fn buildCommand(self: *Linker) ![]const []const u8 {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        // Linker executable
        const linker_exe = switch (self.config.type_) {
            .GnuLd => "ld",
            .Lld => "ld.lld",
            .Mold => "mold",
            .Gold => "ld.gold",
        };
        try args.append(linker_exe);

        // Output file
        try args.append("-o");
        try args.append(self.config.output_path);

        // Linker script
        if (self.config.script_path) |script| {
            try args.append("-T");
            try args.append(script);
        }

        // Object files
        for (self.config.object_files) |obj| {
            try args.append(obj);
        }

        // Library paths
        for (self.config.library_paths) |path| {
            try args.append(try std.fmt.allocPrint(self.allocator, "-L{s}", .{path}));
        }

        // Libraries
        for (self.config.libraries) |lib| {
            try args.append(try std.fmt.allocPrint(self.allocator, "-l{s}", .{lib}));
        }

        // Options
        if (self.config.gc_sections) {
            try args.append("--gc-sections");
        }

        if (self.config.strip) {
            try args.append("--strip-all");
        }

        if (self.config.dynamic) {
            try args.append("-dynamic");
        } else {
            try args.append("-static");
        }

        if (self.config.verbose) {
            try args.append("--verbose");
        }

        return try args.toOwnedSlice();
    }

    /// Execute linker
    pub fn link(self: *Linker) !void {
        const argv = try self.buildCommand();
        defer {
            for (argv) |arg| {
                if (std.mem.startsWith(u8, arg, "-L") or std.mem.startsWith(u8, arg, "-l")) {
                    self.allocator.free(arg);
                }
            }
            self.allocator.free(argv);
        }

        if (self.config.verbose) {
            std.debug.print("Linking: {s}\n", .{argv});
        }

        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        const term = try child.spawnAndWait();
        if (term.Exited != 0) {
            return error.LinkFailed;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "memory region creation" {
    const region = MemoryRegion.init("FLASH", 0x08000000, 128 * 1024, .{
        .readable = true,
        .executable = true,
        .writable = false,
    });

    try std.testing.expectEqual(@as(u64, 0x08000000), region.origin);
    try std.testing.expectEqual(@as(u64, 128 * 1024), region.length);
    try std.testing.expect(region.attributes.readable);
    try std.testing.expect(!region.attributes.writable);
}

test "linker script generation" {
    const allocator = std.testing.allocator;

    var script = LinkerScript.init(allocator);
    defer script.deinit();

    try script.addMemory(MemoryRegion.init("RAM", 0x20000000, 64 * 1024, .{}));

    var text = Section.init(allocator, ".text", .Text);
    text.region = "RAM";
    try text.addInputSection(".text*");
    try script.addSection(text);

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    try script.generateGnuLd(output.writer(allocator));

    const result = output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "MEMORY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "SECTIONS") != null);
}

test "ARM Cortex-M target" {
    const allocator = std.testing.allocator;

    var script = try TargetConfig.armCortexM(allocator, 128 * 1024, 32 * 1024);
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 2), script.memory.items.len);
    try std.testing.expect(std.mem.eql(u8, script.entry, "Reset_Handler"));
}
