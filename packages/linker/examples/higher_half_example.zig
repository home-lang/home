// Example: Generate a higher-half kernel linker script

const std = @import("std");
const linker = @import("linker");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a higher-half kernel script
    var script = try linker.LinkerScript.higherHalfScript(
        allocator,
        "higher-half-kernel",
    );
    defer script.deinit();

    // Add some custom symbols
    try script.addSymbol(linker.Symbol.init(
        "_kernel_physical_start",
        .Object,
        .Global,
    ).withValue(0x0010_0000));

    try script.addSymbol(linker.Symbol.init(
        "_kernel_virtual_start",
        .Object,
        .Global,
    ).withValue(linker.CommonAddresses.X86_64_HIGHER_HALF));

    // Validate
    const result = try script.validate();
    defer result.deinit();

    if (!result.valid) {
        std.debug.print("Validation failed:\n", .{});
        for (result.errors) |err| {
            std.debug.print("  ERROR: {s}\n", .{err});
        }
        return error.ValidationFailed;
    }

    std.debug.print("Validation passed with {d} warnings\n", .{result.warnings.len});
    for (result.warnings) |warn| {
        std.debug.print("  {}\n", .{warn});
    }

    // Generate to file
    try script.generateToFile("higher_half_kernel.ld", .{
        .validate = false, // Already validated
        .include_comments = true,
        .verbose = false,
    });

    std.debug.print("Generated higher_half_kernel.ld\n", .{});
}
