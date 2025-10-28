// Example: Generate an embedded system linker script (ARM Cortex-M)

const std = @import("std");
const linker = @import("linker");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create custom embedded script
    var script = linker.LinkerScript.init(allocator, "stm32-cortex-m");
    defer script.deinit();

    // Flash memory (512KB)
    try script.addRegion(linker.MemoryRegion.init(
        "flash",
        0x0800_0000,
        512 * 1024,
        .{
            .readable = true,
            .writable = false,
            .executable = true,
            .cacheable = true,
        },
    ));

    // SRAM (128KB)
    try script.addRegion(linker.MemoryRegion.init(
        "sram",
        0x2000_0000,
        128 * 1024,
        .{
            .readable = true,
            .writable = true,
            .executable = false,
            .cacheable = true,
        },
    ));

    // Vector table in flash (must be at start)
    try script.addSection(
        linker.Section.init(".vectors", .Custom, .{
            .alloc = true,
            .load = true,
            .readonly = true,
            .executable = true,
        })
            .withVma(0x0800_0000)
            .withAlignment(.Word)
            .withRegion("flash"),
    );

    // Code in flash
    try script.addSection(
        linker.Section.init(".text", .Text, .{
            .alloc = true,
            .load = true,
            .readonly = true,
            .executable = true,
        })
            .withVma(0x0800_0400)
            .withAlignment(.Page)
            .withRegion("flash"),
    );

    // Constants in flash
    try script.addSection(
        linker.Section.init(".rodata", .Rodata, .{
            .alloc = true,
            .load = true,
            .readonly = true,
        })
            .withVma(0x0808_0000)
            .withAlignment(.Page)
            .withRegion("flash"),
    );

    // Initialized data in SRAM (loaded from flash)
    try script.addSection(
        linker.Section.init(".data", .Data, .{
            .alloc = true,
            .load = true,
            .writable = true,
        })
            .withVma(0x2000_0000)
            .withLma(0x0809_0000) // Load from flash
            .withAlignment(.Word)
            .withRegion("sram"),
    );

    // Uninitialized data in SRAM
    try script.addSection(
        linker.Section.init(".bss", .Bss, .{
            .alloc = true,
            .writable = true,
        })
            .withVma(0x2001_0000)
            .withAlignment(.Word)
            .withRegion("sram"),
    );

    // Add embedded-specific symbols
    try script.addSymbol(linker.Symbol.init(
        "_svectors",
        .Section,
        .Global,
    ).withSection(".vectors"));

    try script.addSymbol(linker.Symbol.init(
        "_stext",
        .Section,
        .Global,
    ).withSection(".text"));

    try script.addSymbol(linker.Symbol.init(
        "_sdata",
        .Section,
        .Global,
    ).withSection(".data"));

    try script.addSymbol(linker.Symbol.init(
        "_sbss",
        .Section,
        .Global,
    ).withSection(".bss"));

    try script.addSymbol(linker.Symbol.init(
        "_stack_top",
        .Object,
        .Global,
    ).withValue(0x2002_0000)); // End of SRAM

    // Validate and generate
    const result = try script.validate();
    defer result.deinit();

    if (!result.valid) {
        std.debug.print("Validation failed:\n", .{});
        for (result.errors) |err| {
            std.debug.print("  ERROR: {s}\n", .{err});
        }
        return error.ValidationFailed;
    }

    std.debug.print("Validation passed!\n", .{});

    // Generate to file
    try script.generateToFile("stm32_cortex_m.ld", .{
        .validate = false,
        .include_comments = true,
        .verbose = false,
    });

    std.debug.print("Generated stm32_cortex_m.ld\n", .{});

    // Also print to stdout
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("\n--- Generated Script ---\n\n");
    try script.generate(stdout, .{
        .validate = false,
        .include_comments = true,
        .verbose = false,
    });
}
