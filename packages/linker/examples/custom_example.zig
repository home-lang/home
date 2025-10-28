// Example: Build a completely custom linker script

const std = @import("std");
const linker = @import("linker");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start with empty custom layout
    var script = linker.LinkerScript.init(allocator, "custom-os");
    defer script.deinit();

    std.debug.print("Building custom OS linker script...\n", .{});

    // Kernel at 2MB (identity mapped initially)
    std.debug.print("  Adding kernel region at 2MB...\n", .{});
    try script.addKernelRegion(0x20_0000, 64 * 1024 * 1024); // 64MB

    // User space starts at 4GB boundary
    std.debug.print("  Adding user space region...\n", .{});
    try script.addUserRegion(
        0x1_0000_0000,
        128 * 1024 * 1024 * 1024, // 128GB
    );

    // Add standard sections to kernel region
    std.debug.print("  Adding standard sections...\n", .{});
    try script.addStandardSections("kernel", 0x20_0000);

    // Add custom sections
    std.debug.print("  Adding custom sections...\n", .{});

    // Kernel heap section
    try script.addSection(
        linker.Section.init(".kheap", .Custom, .{
            .alloc = true,
            .writable = true,
        })
            .withAlignment(.Page)
            .withRegion("kernel"),
    );

    // Kernel stack section
    try script.addSection(
        linker.Section.init(".kstack", .Custom, .{
            .alloc = true,
            .writable = true,
        })
            .withAlignment(.Page)
            .withRegion("kernel"),
    );

    // Per-CPU data section
    try script.addSection(
        linker.Section.init(".percpu", .Custom, .{
            .alloc = true,
            .writable = true,
        })
            .withAlignment(.Page)
            .withRegion("kernel"),
    );

    // Add symbols
    std.debug.print("  Adding symbols...\n", .{});
    try script.addStandardSymbols();

    // Add custom symbols
    try script.addSymbol(linker.Symbol.init(
        "_kheap_start",
        .Section,
        .Global,
    ).withSection(".kheap"));

    try script.addSymbol(linker.Symbol.init(
        "_kstack_top",
        .Section,
        .Global,
    ).withSection(".kstack"));

    try script.addSymbol(linker.Symbol.init(
        "_percpu_start",
        .Section,
        .Global,
    ).withSection(".percpu"));

    // Validate
    std.debug.print("  Validating...\n", .{});
    const result = try script.validate();
    defer result.deinit();

    if (!result.valid) {
        std.debug.print("Validation FAILED with {d} errors:\n", .{result.errors.len});
        for (result.errors) |err| {
            std.debug.print("  ERROR: {s}\n", .{err});
        }
        return error.ValidationFailed;
    }

    std.debug.print("Validation PASSED!\n", .{});
    if (result.warnings.len > 0) {
        std.debug.print("  {d} warnings:\n", .{result.warnings.len});
        for (result.warnings) |warn| {
            std.debug.print("    {}\n", .{warn});
        }
    }

    // Generate
    std.debug.print("\nGenerating linker script...\n", .{});
    try script.generateToFile("custom_os.ld", .{
        .validate = false,
        .include_comments = true,
        .verbose = false,
    });

    std.debug.print("Successfully generated custom_os.ld!\n\n", .{});

    // Print summary
    std.debug.print("Summary:\n", .{});
    std.debug.print("  Regions:  {d}\n", .{script.regions.items.len});
    std.debug.print("  Sections: {d}\n", .{script.sections.items.len});
    std.debug.print("  Symbols:  {d}\n", .{script.symbols.items.len});

    std.debug.print("\nMemory Regions:\n", .{});
    for (script.regions.items) |region| {
        std.debug.print("  {s}: 0x{x:0>16} - 0x{x:0>16} ({d} MB)\n", .{
            region.name,
            region.base,
            region.end(),
            region.size / (1024 * 1024),
        });
    }

    std.debug.print("\nSections:\n", .{});
    for (script.sections.items) |section| {
        if (section.vma) |vma| {
            std.debug.print("  {s}: 0x{x:0>16} in {s}\n", .{
                section.name,
                vma,
                section.region orelse "none",
            });
        } else {
            std.debug.print("  {s}: (no VMA) in {s}\n", .{
                section.name,
                section.region orelse "none",
            });
        }
    }
}
