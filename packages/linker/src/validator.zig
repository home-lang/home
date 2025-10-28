// Home Programming Language - Linker Script Validator
// Validates linker scripts for correctness and safety

const std = @import("std");
const linker = @import("linker.zig");
const memory = @import("memory.zig");
const section = @import("section.zig");
const symbol = @import("symbol.zig");

pub const ValidationError = error{
    OverlappingMemoryRegions,
    OverlappingSections,
    SectionOutsideRegion,
    InvalidAlignment,
    InvalidAddress,
    DuplicateSymbol,
    UndefinedSymbol,
    CircularDependency,
    ZeroSizeRegion,
    ZeroSizeSection,
    MisalignedSection,
    InvalidSectionFlags,
    ConflictingAttributes,
};

pub const Severity = enum { Low, Medium, High };

pub const ValidationWarning = struct {
    message: []const u8,
    severity: Severity,

    pub fn format(
        self: ValidationWarning,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const severity_str = switch (self.severity) {
            .Low => "LOW",
            .Medium => "MEDIUM",
            .High => "HIGH",
        };
        try writer.print("[{s}] {s}", .{ severity_str, self.message });
    }
};

pub const ValidationResult = struct {
    valid: bool,
    errors: []const []const u8,
    warnings: []const ValidationWarning,
    allocator: std.mem.Allocator,

    pub fn deinit(self: ValidationResult) void {
        for (self.errors) |err| {
            self.allocator.free(err);
        }
        self.allocator.free(self.errors);
        self.allocator.free(self.warnings);
    }
};

pub const Validator = struct {
    errors: std.ArrayList([]const u8),
    warnings: std.ArrayList(ValidationWarning),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Validator {
        return .{
            .errors = std.ArrayList([]const u8){},
            .warnings = std.ArrayList(ValidationWarning){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Validator) void {
        for (self.errors.items) |err| {
            self.allocator.free(err);
        }
        self.errors.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }

    fn addError(self: *Validator, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(self.allocator, msg);
    }

    fn addWarning(self: *Validator, severity: Severity, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.warnings.append(self.allocator, .{
            .message = msg,
            .severity = severity,
        });
    }

    // Validate memory regions
    pub fn validateMemoryRegions(self: *Validator, regions: []const memory.MemoryRegion) !void {
        // Check for zero-size regions
        for (regions) |region| {
            if (region.size == 0) {
                try self.addError("Memory region '{s}' has zero size", .{region.name});
            }
        }

        // Check for overlaps
        for (regions, 0..) |region1, i| {
            for (regions[i + 1 ..]) |region2| {
                if (region1.overlaps(region2)) {
                    try self.addError(
                        "Memory regions '{s}' and '{s}' overlap (0x{x:0>16}-0x{x:0>16} vs 0x{x:0>16}-0x{x:0>16})",
                        .{ region1.name, region2.name, region1.base, region1.end(), region2.base, region2.end() },
                    );
                }
            }
        }

        // Warn about non-page-aligned regions
        for (regions) |region| {
            if (!linker.isAligned(region.base, .Page)) {
                try self.addWarning(.Medium, "Memory region '{s}' base address 0x{x:0>16} is not page-aligned", .{ region.name, region.base });
            }
            if (!linker.isAligned(region.size, .Page)) {
                try self.addWarning(.Low, "Memory region '{s}' size 0x{x} is not page-aligned", .{ region.name, region.size });
            }
        }
    }

    // Validate sections
    pub fn validateSections(
        self: *Validator,
        sections: []const section.Section,
        regions: []const memory.MemoryRegion,
    ) !void {
        // Check for duplicate section names
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (sections) |sect| {
            if (seen.contains(sect.name)) {
                try self.addError("Duplicate section name '{s}'", .{sect.name});
            } else {
                try seen.put(sect.name, {});
            }
        }

        // Check section addresses and regions
        for (sections) |sect| {
            // Check alignment
            if (sect.vma) |vma| {
                if (!linker.isAligned(vma, sect.alignment)) {
                    try self.addError(
                        "Section '{s}' VMA 0x{x:0>16} is not aligned to {d} bytes",
                        .{ sect.name, vma, sect.alignment.toBytes() },
                    );
                }
            }

            // Check if section is within its region
            if (sect.region) |region_name| {
                var found_region = false;
                for (regions) |region| {
                    if (std.mem.eql(u8, region.name, region_name)) {
                        found_region = true;
                        if (sect.vma) |vma| {
                            if (!region.contains(vma)) {
                                try self.addError(
                                    "Section '{s}' VMA 0x{x:0>16} is outside region '{s}' (0x{x:0>16}-0x{x:0>16})",
                                    .{ sect.name, vma, region_name, region.base, region.end() },
                                );
                            }
                        }
                        break;
                    }
                }
                if (!found_region) {
                    try self.addError("Section '{s}' references undefined region '{s}'", .{ sect.name, region_name });
                }
            }

            // Check section flags consistency
            if (sect.flags.executable and !sect.flags.readonly) {
                try self.addWarning(.High, "Section '{s}' is executable but not read-only (security risk)", .{sect.name});
            }

            if (sect.flags.writable and sect.flags.code) {
                try self.addWarning(.High, "Section '{s}' is both writable and contains code (security risk)", .{sect.name});
            }
        }

        // Check for overlapping sections
        for (sections, 0..) |sect1, i| {
            if (sect1.vma == null) continue;

            for (sections[i + 1 ..]) |sect2| {
                if (sect2.vma == null) continue;

                // Assume minimum 4KB section size for overlap check
                const sect1_end = sect1.vma.? + 4096;
                const sect2_end = sect2.vma.? + 4096;

                if (sect1.vma.? < sect2_end and sect2.vma.? < sect1_end) {
                    try self.addWarning(.High, "Sections '{s}' and '{s}' may overlap", .{ sect1.name, sect2.name });
                }
            }
        }

        // Warn about missing standard sections
        const standard_sections = [_][]const u8{ ".text", ".rodata", ".data", ".bss" };
        for (standard_sections) |std_sect| {
            var found = false;
            for (sections) |sect| {
                if (std.mem.eql(u8, sect.name, std_sect)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.addWarning(.Low, "Standard section '{s}' is missing", .{std_sect});
            }
        }
    }

    // Validate symbols
    pub fn validateSymbols(
        self: *Validator,
        symbols: []const symbol.Symbol,
        sections: []const section.Section,
    ) !void {
        // Check for duplicate symbols
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (symbols) |sym| {
            if (seen.contains(sym.name)) {
                try self.addError("Duplicate symbol '{s}'", .{sym.name});
            } else {
                try seen.put(sym.name, {});
            }
        }

        // Check symbol references
        for (symbols) |sym| {
            if (sym.section) |sect_name| {
                var found = false;
                for (sections) |sect| {
                    if (std.mem.eql(u8, sect.name, sect_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try self.addError("Symbol '{s}' references undefined section '{s}'", .{ sym.name, sect_name });
                }
            }

            // Warn about weak symbols
            if (sym.visibility == .Weak) {
                try self.addWarning(.Low, "Symbol '{s}' has weak visibility", .{sym.name});
            }
        }
    }

    // Complete validation
    pub fn validate(
        self: *Validator,
        regions: []const memory.MemoryRegion,
        sections: []const section.Section,
        symbols: []const symbol.Symbol,
    ) !ValidationResult {
        try self.validateMemoryRegions(regions);
        try self.validateSections(sections, regions);
        try self.validateSymbols(symbols, sections);

        return ValidationResult{
            .valid = self.errors.items.len == 0,
            .errors = try self.errors.toOwnedSlice(self.allocator),
            .warnings = try self.warnings.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }
};

// Tests
test "validator basic" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    try testing.expectEqual(@as(usize, 0), validator.errors.items.len);
    try testing.expectEqual(@as(usize, 0), validator.warnings.items.len);
}

test "validate memory regions - no overlaps" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const regions = [_]memory.MemoryRegion{
        memory.MemoryRegion.init("kernel", 0x1000, 0x1000, .{}),
        memory.MemoryRegion.init("user", 0x3000, 0x1000, .{}),
    };

    try validator.validateMemoryRegions(&regions);

    try testing.expectEqual(@as(usize, 0), validator.errors.items.len);
}

test "validate memory regions - overlaps" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const regions = [_]memory.MemoryRegion{
        memory.MemoryRegion.init("kernel", 0x1000, 0x2000, .{}),
        memory.MemoryRegion.init("user", 0x2000, 0x1000, .{}), // Overlaps at 0x2000
    };

    try validator.validateMemoryRegions(&regions);

    try testing.expectEqual(@as(usize, 1), validator.errors.items.len);
}

test "validate memory regions - zero size" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const regions = [_]memory.MemoryRegion{
        memory.MemoryRegion.init("kernel", 0x1000, 0, .{}),
    };

    try validator.validateMemoryRegions(&regions);

    try testing.expectEqual(@as(usize, 1), validator.errors.items.len);
}

test "validate sections - duplicate names" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const sections = [_]section.Section{
        section.StandardSections.text(),
        section.StandardSections.text(), // Duplicate
    };

    const regions = [_]memory.MemoryRegion{
        memory.MemoryRegion.init("kernel", 0x1000, 0x100000, .{}),
    };

    try validator.validateSections(&sections, &regions);

    try testing.expectEqual(@as(usize, 1), validator.errors.items.len);
}

test "validate sections - undefined region" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const sections = [_]section.Section{
        section.StandardSections.text().withRegion("nonexistent"),
    };

    const regions = [_]memory.MemoryRegion{
        memory.MemoryRegion.init("kernel", 0x1000, 0x100000, .{}),
    };

    try validator.validateSections(&sections, &regions);

    try testing.expectEqual(@as(usize, 1), validator.errors.items.len);
}

test "validate sections - misaligned" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const sections = [_]section.Section{
        section.StandardSections.text()
            .withAlignment(.Page)
            .withVma(0x1001), // Not page-aligned
    };

    const regions = [_]memory.MemoryRegion{
        memory.MemoryRegion.init("kernel", 0x0, 0x100000, .{}),
    };

    try validator.validateSections(&sections, &regions);

    try testing.expectEqual(@as(usize, 1), validator.errors.items.len);
}

test "validate symbols - duplicate" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const symbols = [_]symbol.Symbol{
        symbol.Symbol.init("test", .Func, .Global),
        symbol.Symbol.init("test", .Object, .Local), // Duplicate
    };

    const sections = [_]section.Section{
        section.StandardSections.text(),
    };

    try validator.validateSymbols(&symbols, &sections);

    try testing.expectEqual(@as(usize, 1), validator.errors.items.len);
}

test "validate symbols - undefined section" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const symbols = [_]symbol.Symbol{
        symbol.Symbol.init("test", .Section, .Global).withSection(".nonexistent"),
    };

    const sections = [_]section.Section{
        section.StandardSections.text(),
    };

    try validator.validateSymbols(&symbols, &sections);

    try testing.expectEqual(@as(usize, 1), validator.errors.items.len);
}

test "complete validation - valid" {
    const testing = std.testing;

    var validator = Validator.init(testing.allocator);
    defer validator.deinit();

    const regions = [_]memory.MemoryRegion{
        memory.MemoryRegion.init("kernel", 0x1000, 0x100000, .{}),
    };

    const sections = [_]section.Section{
        section.StandardSections.text().withRegion("kernel").withVma(0x1000),
        section.StandardSections.rodata().withRegion("kernel").withVma(0x5000),
        section.StandardSections.data().withRegion("kernel").withVma(0x9000),
        section.StandardSections.bss().withRegion("kernel").withVma(0xd000),
    };

    const symbols = [_]symbol.Symbol{
        symbol.Symbol.init("test", .Func, .Global).withSection(".text"),
    };

    const result = try validator.validate(&regions, &sections, &symbols);
    defer result.deinit();

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}
