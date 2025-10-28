// Home Programming Language - Comprehensive Linker Tests
// Integration tests for the complete linker script system

const std = @import("std");
const testing = std.testing;
const linker = @import("linker");

// Test complete kernel script generation
test "complete kernel script generation" {
    var script = try linker.LinkerScript.kernelScript(
        testing.allocator,
        "test-kernel",
        0x10_0000,
    );
    defer script.deinit();

    // Validate
    const result = try script.validate();
    defer result.deinit();

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 0), result.errors.len);

    // Generate
    const output = try script.generateToString(.{
        .validate = true,
        .include_comments = true,
    });
    defer testing.allocator.free(output);

    // Check output contains expected elements
    try testing.expect(std.mem.indexOf(u8, output, "OUTPUT_FORMAT") != null);
    try testing.expect(std.mem.indexOf(u8, output, "OUTPUT_ARCH") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ENTRY(_start)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "MEMORY") != null);
    try testing.expect(std.mem.indexOf(u8, output, "SECTIONS") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".text") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".rodata") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".data") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".bss") != null);
}

// Test higher-half kernel
test "higher-half kernel script" {
    var script = try linker.LinkerScript.higherHalfScript(
        testing.allocator,
        "higher-half-kernel",
    );
    defer script.deinit();

    const output = try script.generateToString(.{ .validate = true });
    defer testing.allocator.free(output);

    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "boot") != null);
    try testing.expect(std.mem.indexOf(u8, output, "kernel") != null);
}

// Test embedded system script
test "embedded system script" {
    var script = try linker.LinkerScript.embeddedScript(
        testing.allocator,
        "embedded-device",
    );
    defer script.deinit();

    const output = try script.generateToString(.{ .validate = true });
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "flash") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ram") != null);
}

// Test custom script building
test "custom script with manual configuration" {
    var script = linker.LinkerScript.init(testing.allocator, "custom");
    defer script.deinit();

    // Add custom memory regions
    try script.addRegion(linker.MemoryRegion.init(
        "rom",
        0x0000_0000,
        0x0010_0000, // 1MB ROM
        .{
            .readable = true,
            .writable = false,
            .executable = true,
        },
    ));

    try script.addRegion(linker.MemoryRegion.init(
        "ram",
        0x2000_0000,
        0x0020_0000, // 2MB RAM
        .{
            .readable = true,
            .writable = true,
            .executable = false,
        },
    ));

    // Add custom sections
    try script.addSection(
        linker.Section.init(".text", .Text, .{
            .alloc = true,
            .load = true,
            .readonly = true,
            .executable = true,
        }).withVma(0x0000_0000).withRegion("rom"),
    );

    try script.addSection(
        linker.Section.init(".data", .Data, .{
            .alloc = true,
            .load = true,
            .writable = true,
        }).withVma(0x2000_0000).withRegion("ram"),
    );

    // Add custom symbols
    try script.addSymbol(linker.Symbol.init(
        "_rom_start",
        .Section,
        .Global,
    ).withValue(0x0000_0000));

    try script.addSymbol(linker.Symbol.init(
        "_ram_start",
        .Section,
        .Global,
    ).withValue(0x2000_0000));

    // Validate
    const result = try script.validate();
    defer result.deinit();

    try testing.expect(result.valid);

    // Generate
    const output = try script.generateToString(.{ .validate = true });
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "rom") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ram") != null);
    try testing.expect(std.mem.indexOf(u8, output, "_rom_start") != null);
    try testing.expect(std.mem.indexOf(u8, output, "_ram_start") != null);
}

// Test validation catches errors
test "validation catches overlapping regions" {
    var script = linker.LinkerScript.init(testing.allocator, "invalid");
    defer script.deinit();

    // Add overlapping regions
    try script.addKernelRegion(0x1000, 0x2000);
    try script.addUserRegion(0x2000, 0x1000); // Overlaps at 0x2000

    const result = try script.validate();
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expect(result.errors.len > 0);
}

// Test validation catches misaligned sections
test "validation catches misaligned sections" {
    var script = linker.LinkerScript.init(testing.allocator, "misaligned");
    defer script.deinit();

    try script.addKernelRegion(0x0, 0x100000);

    // Add misaligned section
    try script.addSection(
        linker.Section.init(".text", .Text, .{
            .alloc = true,
            .executable = true,
        })
            .withAlignment(.Page)
            .withVma(0x1001) // Not page-aligned
            .withRegion("kernel"),
    );

    const result = try script.validate();
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expect(result.errors.len > 0);
}

// Test section ordering
test "standard sections in correct order" {
    var script = try linker.LinkerScript.kernelScript(
        testing.allocator,
        "ordered",
        0x10_0000,
    );
    defer script.deinit();

    const sections = script.sections.items;

    // Check order: .text, .rodata, .data, .bss
    try testing.expect(std.mem.eql(u8, sections[0].name, ".text"));
    try testing.expect(std.mem.eql(u8, sections[1].name, ".rodata"));
    try testing.expect(std.mem.eql(u8, sections[2].name, ".data"));
    try testing.expect(std.mem.eql(u8, sections[3].name, ".bss"));

    // Check VMAs are ordered
    for (sections[0 .. sections.len - 1], 0..) |sect, i| {
        const next = sections[i + 1];
        if (sect.vma != null and next.vma != null) {
            try testing.expect(sect.vma.? < next.vma.?);
        }
    }
}

// Test symbol generation
test "standard kernel symbols" {
    var script = try linker.LinkerScript.kernelScript(
        testing.allocator,
        "symbols",
        0x10_0000,
    );
    defer script.deinit();

    // Check for essential symbols
    var has_kernel_start = false;
    var has_kernel_end = false;
    var has_text_start = false;
    var has_bss_end = false;

    for (script.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "__kernel_start")) has_kernel_start = true;
        if (std.mem.eql(u8, sym.name, "__kernel_end")) has_kernel_end = true;
        if (std.mem.eql(u8, sym.name, "__text_start")) has_text_start = true;
        if (std.mem.eql(u8, sym.name, "__bss_end")) has_bss_end = true;
    }

    try testing.expect(has_kernel_start);
    try testing.expect(has_kernel_end);
    try testing.expect(has_text_start);
    try testing.expect(has_bss_end);
}

// Test memory region attributes
test "memory region attributes" {
    var script = linker.LinkerScript.init(testing.allocator, "attrs");
    defer script.deinit();

    // Read-only executable region
    try script.addRegion(linker.MemoryRegion.init(
        "rom",
        0x0,
        0x100000,
        .{
            .readable = true,
            .writable = false,
            .executable = true,
        },
    ));

    // Read-write non-executable region
    try script.addRegion(linker.MemoryRegion.init(
        "ram",
        0x2000_0000,
        0x100000,
        .{
            .readable = true,
            .writable = true,
            .executable = false,
        },
    ));

    const rom = script.regions.items[0];
    const ram = script.regions.items[1];

    try testing.expect(rom.attributes.readable);
    try testing.expect(!rom.attributes.writable);
    try testing.expect(rom.attributes.executable);

    try testing.expect(ram.attributes.readable);
    try testing.expect(ram.attributes.writable);
    try testing.expect(!ram.attributes.executable);
}

// Test TLS sections
test "thread-local storage sections" {
    var script = linker.LinkerScript.init(testing.allocator, "tls");
    defer script.deinit();

    try script.addKernelRegion(0x10_0000, 0x100000);

    // Add TLS sections
    try script.addSection(
        linker.Section.init(".tdata", .TData, .{
            .alloc = true,
            .load = true,
            .writable = true,
            .tls = true,
        }).withVma(0x10_0000).withRegion("kernel"),
    );

    try script.addSection(
        linker.Section.init(".tbss", .Tbss, .{
            .alloc = true,
            .writable = true,
            .tls = true,
        }).withVma(0x11_0000).withRegion("kernel"),
    );

    const tdata = script.sections.items[0];
    const tbss = script.sections.items[1];

    try testing.expect(tdata.flags.tls);
    try testing.expect(tbss.flags.tls);
}

// Test alignment utilities
test "alignment operations" {
    try testing.expectEqual(@as(u64, 4096), linker.alignUp(100, .Page));
    try testing.expectEqual(@as(u64, 4096), linker.alignUp(4096, .Page));
    try testing.expectEqual(@as(u64, 8192), linker.alignUp(4097, .Page));

    try testing.expectEqual(@as(u64, 0), linker.alignDown(100, .Page));
    try testing.expectEqual(@as(u64, 4096), linker.alignDown(4096, .Page));
    try testing.expectEqual(@as(u64, 4096), linker.alignDown(4097, .Page));

    try testing.expect(!linker.isAligned(100, .Page));
    try testing.expect(linker.isAligned(4096, .Page));
    try testing.expect(!linker.isAligned(4097, .Page));
}

// Test address range operations
test "address range operations" {
    const range = try linker.AddressRange.init(0x1000, 0x2000);

    try testing.expectEqual(@as(u64, 0x1000), range.size());
    try testing.expect(range.contains(0x1500));
    try testing.expect(!range.contains(0x2000));

    const range2 = try linker.AddressRange.init(0x1800, 0x2800);
    try testing.expect(range.overlaps(range2));

    const range3 = try linker.AddressRange.init(0x3000, 0x4000);
    try testing.expect(!range.overlaps(range3));

    const split = try range.split(0x1800);
    try testing.expectEqual(@as(u64, 0x1000), split[0].start);
    try testing.expectEqual(@as(u64, 0x1800), split[0].end);
    try testing.expectEqual(@as(u64, 0x1800), split[1].start);
    try testing.expectEqual(@as(u64, 0x2000), split[1].end);
}

// Performance test: Generate 1000 scripts
test "performance: generate multiple scripts" {
    const num_scripts = 100; // Reduced for CI

    var i: usize = 0;
    while (i < num_scripts) : (i += 1) {
        var script = try linker.LinkerScript.kernelScript(
            testing.allocator,
            "perf-test",
            0x10_0000,
        );
        defer script.deinit();

        const output = try script.generateToString(.{ .validate = false });
        defer testing.allocator.free(output);

        try testing.expect(output.len > 0);
    }
}

// Test file generation
test "generate to file" {
    const tmp_path = "/tmp/test_linker_script.ld";

    var script = try linker.LinkerScript.kernelScript(
        testing.allocator,
        "file-test",
        0x10_0000,
    );
    defer script.deinit();

    // Generate to file
    try script.generateToFile(tmp_path, .{ .validate = true });

    // Read back and verify
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(content);

    try testing.expect(content.len > 0);
    try testing.expect(std.mem.indexOf(u8, content, "MEMORY") != null);

    // Clean up
    try std.fs.cwd().deleteFile(tmp_path);
}
