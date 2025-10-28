// Home Programming Language - Linker Script Management
// High-level API for creating and managing linker scripts

const std = @import("std");
const linker = @import("linker.zig");
const memory = @import("memory.zig");
const section = @import("section.zig");
const symbol = @import("symbol.zig");
const validator = @import("validator.zig");
const generator = @import("generator.zig");

pub const LinkerScript = struct {
    name: []const u8,
    regions: std.ArrayList(memory.MemoryRegion),
    sections: std.ArrayList(section.Section),
    symbols: std.ArrayList(symbol.Symbol),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) LinkerScript {
        return .{
            .name = name,
            .regions = std.ArrayList(memory.MemoryRegion){},
            .sections = std.ArrayList(section.Section){},
            .symbols = std.ArrayList(symbol.Symbol){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LinkerScript) void {
        self.regions.deinit(self.allocator);
        self.sections.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }

    // Memory region management
    pub fn addRegion(self: *LinkerScript, region: memory.MemoryRegion) !void {
        try self.regions.append(self.allocator, region);
    }

    pub fn addKernelRegion(self: *LinkerScript, base: u64, size: u64) !void {
        try self.addRegion(memory.MemoryRegion.init(
            "kernel",
            base,
            size,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
                .cacheable = true,
            },
        ));
    }

    pub fn addUserRegion(self: *LinkerScript, base: u64, size: u64) !void {
        try self.addRegion(memory.MemoryRegion.init(
            "user",
            base,
            size,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
                .cacheable = true,
            },
        ));
    }

    // Section management
    pub fn addSection(self: *LinkerScript, sect: section.Section) !void {
        try self.sections.append(self.allocator, sect);
    }

    pub fn addStandardSections(self: *LinkerScript, region_name: []const u8, base_vma: u64) !void {
        const std_sections = section.StandardSections.kernel_sections();
        var vma = base_vma;

        for (std_sections) |sect| {
            vma = sect.alignment.alignAddress(vma);
            try self.addSection(sect.withVma(vma).withRegion(region_name));
            vma += 4096; // Assume minimum 4KB per section
        }
    }

    // Symbol management
    pub fn addSymbol(self: *LinkerScript, sym: symbol.Symbol) !void {
        try self.symbols.append(self.allocator, sym);
    }

    pub fn addStandardSymbols(self: *LinkerScript) !void {
        const syms = try symbol.KernelSymbols.standard_symbols(self.allocator);
        defer self.allocator.free(syms);

        for (syms) |sym| {
            try self.addSymbol(sym);
        }
    }

    // Validation
    pub fn validate(self: *LinkerScript) !validator.ValidationResult {
        var val = validator.Validator.init(self.allocator);
        defer val.deinit();

        return try val.validate(
            self.regions.items,
            self.sections.items,
            self.symbols.items,
        );
    }

    // Generation
    pub fn generate(self: *LinkerScript, writer: anytype, options: generator.GeneratorOptions) !void {
        var gen = generator.Generator.init(self.allocator, options);
        try gen.generate(
            writer,
            self.regions.items,
            self.sections.items,
            self.symbols.items,
        );
    }

    pub fn generateToFile(self: *LinkerScript, path: []const u8, options: generator.GeneratorOptions) !void {
        var gen = generator.Generator.init(self.allocator, options);
        try gen.generateToFile(
            path,
            self.regions.items,
            self.sections.items,
            self.symbols.items,
        );
    }

    pub fn generateToString(self: *LinkerScript, options: generator.GeneratorOptions) ![]const u8 {
        var gen = generator.Generator.init(self.allocator, options);
        return try gen.generateToString(
            self.regions.items,
            self.sections.items,
            self.symbols.items,
        );
    }

    // Preset configurations
    pub fn fromKernelLayout(
        allocator: std.mem.Allocator,
        name: []const u8,
        layout: linker.MemoryLayout,
        base_addr: u64,
    ) !LinkerScript {
        var script = LinkerScript.init(allocator, name);
        errdefer script.deinit();

        switch (layout) {
            .Kernel => {
                // Simple kernel at specified address
                try script.addKernelRegion(base_addr, 0x4000_0000); // 1GB
                try script.addStandardSections("kernel", base_addr);
            },
            .HigherHalf => {
                // Higher-half kernel
                const regions = memory.StandardRegions.x86_64_higher_half();
                for (regions) |region| {
                    try script.addRegion(region);
                }
                try script.addStandardSections("kernel", linker.CommonAddresses.X86_64_HIGHER_HALF);
            },
            .KernelUser => {
                // Kernel + user space
                try script.addKernelRegion(base_addr, 0x4000_0000);
                try script.addUserRegion(0x1000, 0x0000_7fff_ffff_f000);
                try script.addStandardSections("kernel", base_addr);
            },
            .UserSpace => {
                // User space only
                try script.addUserRegion(base_addr, 0x0000_7fff_ffff_f000);
                try script.addStandardSections("user", base_addr);
            },
            .Embedded => {
                // Embedded system
                const regions = memory.StandardRegions.embedded_nommu();
                for (regions) |region| {
                    try script.addRegion(region);
                }
                // Add sections for flash
                try script.addSection(section.StandardSections.text().withRegion("flash").withVma(0x0800_0000));
                try script.addSection(section.StandardSections.rodata().withRegion("flash").withVma(0x0800_4000));
                // Add sections for RAM
                try script.addSection(section.StandardSections.data().withRegion("ram").withVma(0x2000_0000));
                try script.addSection(section.StandardSections.bss().withRegion("ram").withVma(0x2000_4000));
            },
            .Custom => {
                // Empty, user will configure manually
            },
        }

        try script.addStandardSymbols();

        return script;
    }

    // Quick kernel script creation
    pub fn kernelScript(
        allocator: std.mem.Allocator,
        name: []const u8,
        base_addr: u64,
    ) !LinkerScript {
        return try fromKernelLayout(allocator, name, .Kernel, base_addr);
    }

    pub fn higherHalfScript(
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !LinkerScript {
        return try fromKernelLayout(allocator, name, .HigherHalf, 0);
    }

    pub fn embeddedScript(
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !LinkerScript {
        return try fromKernelLayout(allocator, name, .Embedded, 0);
    }
};

// Tests
test "linker script basic" {
    const testing = std.testing;

    var script = LinkerScript.init(testing.allocator, "test");
    defer script.deinit();

    try testing.expect(std.mem.eql(u8, script.name, "test"));
    try testing.expectEqual(@as(usize, 0), script.regions.items.len);
    try testing.expectEqual(@as(usize, 0), script.sections.items.len);
    try testing.expectEqual(@as(usize, 0), script.symbols.items.len);
}

test "linker script add regions" {
    const testing = std.testing;

    var script = LinkerScript.init(testing.allocator, "test");
    defer script.deinit();

    try script.addKernelRegion(0x10_0000, 0x100000);

    try testing.expectEqual(@as(usize, 1), script.regions.items.len);
    try testing.expect(std.mem.eql(u8, script.regions.items[0].name, "kernel"));
}

test "linker script add sections" {
    const testing = std.testing;

    var script = LinkerScript.init(testing.allocator, "test");
    defer script.deinit();

    try script.addKernelRegion(0x10_0000, 0x100000);
    try script.addStandardSections("kernel", 0x10_0000);

    try testing.expectEqual(@as(usize, 4), script.sections.items.len);
}

test "linker script add symbols" {
    const testing = std.testing;

    var script = LinkerScript.init(testing.allocator, "test");
    defer script.deinit();

    try script.addStandardSymbols();

    try testing.expect(script.symbols.items.len > 0);
}

test "linker script validation" {
    const testing = std.testing;

    var script = LinkerScript.init(testing.allocator, "test");
    defer script.deinit();

    try script.addKernelRegion(0x1000, 0x100000);
    try script.addStandardSections("kernel", 0x1000);

    const result = try script.validate();
    defer result.deinit();

    try testing.expect(result.valid);
}

test "linker script generation" {
    const testing = std.testing;

    var script = LinkerScript.init(testing.allocator, "test");
    defer script.deinit();

    try script.addKernelRegion(0x10_0000, 0x100000);
    try script.addStandardSections("kernel", 0x10_0000);
    try script.addStandardSymbols();

    const output = try script.generateToString(.{ .validate = true });
    defer testing.allocator.free(output);

    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "MEMORY") != null);
    try testing.expect(std.mem.indexOf(u8, output, "SECTIONS") != null);
}

test "kernel script preset" {
    const testing = std.testing;

    var script = try LinkerScript.kernelScript(testing.allocator, "kernel", 0x10_0000);
    defer script.deinit();

    try testing.expectEqual(@as(usize, 1), script.regions.items.len);
    try testing.expectEqual(@as(usize, 4), script.sections.items.len);
    try testing.expect(script.symbols.items.len > 0);

    const output = try script.generateToString(.{ .validate = true });
    defer testing.allocator.free(output);

    try testing.expect(output.len > 0);
}

test "higher-half kernel script" {
    const testing = std.testing;

    var script = try LinkerScript.higherHalfScript(testing.allocator, "kernel");
    defer script.deinit();

    try testing.expect(script.regions.items.len > 0);
    try testing.expect(script.sections.items.len > 0);

    const output = try script.generateToString(.{ .validate = true });
    defer testing.allocator.free(output);

    try testing.expect(output.len > 0);
}

test "embedded script preset" {
    const testing = std.testing;

    var script = try LinkerScript.embeddedScript(testing.allocator, "embedded");
    defer script.deinit();

    // Should have flash and RAM regions
    try testing.expectEqual(@as(usize, 2), script.regions.items.len);

    const output = try script.generateToString(.{ .validate = true });
    defer testing.allocator.free(output);

    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "flash") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ram") != null);
}

test "custom layout" {
    const testing = std.testing;

    var script = try LinkerScript.fromKernelLayout(
        testing.allocator,
        "custom",
        .Custom,
        0,
    );
    defer script.deinit();

    // Custom layout should be empty except for symbols
    try testing.expectEqual(@as(usize, 0), script.regions.items.len);
    try testing.expectEqual(@as(usize, 0), script.sections.items.len);
    try testing.expect(script.symbols.items.len > 0); // Standard symbols are added
}
