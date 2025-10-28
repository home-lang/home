// Example: Printf-style formatting

const std = @import("std");
const variadic = @import("variadic");

pub fn main() !void {
    std.debug.print("=== Printf Example ===\n\n", .{});

    // Basic formatting
    try variadic.printf.printf("Hello, %s!\n", .{"World"});
    try variadic.printf.printf("The answer is %d\n", .{@as(i32, 42)});

    // Multiple arguments
    try variadic.printf.printf("%d + %d = %d\n", .{ @as(i32, 2), @as(i32, 3), @as(i32, 5) });

    // Different number bases
    try variadic.printf.printf("Decimal: %d, Hex: %x, Octal: %o, Binary: %b\n", .{
        @as(u32, 255),
        @as(u32, 255),
        @as(u32, 255),
        @as(u32, 255),
    });

    // Floating point
    try variadic.printf.printf("Pi: %.2f, E: %.5f\n", .{
        @as(f64, 3.14159),
        @as(f64, 2.71828),
    });

    // Width and alignment
    std.debug.print("\nWidth and Padding:\n", .{});
    try variadic.printf.printf("Right-aligned: [%10d]\n", .{@as(i32, 42)});
    try variadic.printf.printf("Left-aligned:  [%-10d]\n", .{@as(i32, 42)});
    try variadic.printf.printf("Zero-padded:   [%010d]\n", .{@as(i32, 42)});

    // Alternate forms
    std.debug.print("\nAlternate Forms:\n", .{});
    try variadic.printf.printf("Hex with prefix: %#x\n", .{@as(u32, 255)});
    try variadic.printf.printf("Octal with prefix: %#o\n", .{@as(u32, 64)});

    // Pointers
    std.debug.print("\nPointers:\n", .{});
    const value: i32 = 100;
    try variadic.printf.printf("Address: %p\n", .{&value});

    // String buffer
    std.debug.print("\nString Buffer:\n", .{});
    var buf: [256]u8 = undefined;
    const n = try variadic.printf.sprintf(&buf, "Formatted: %d items at $%.2f each", .{
        @as(i32, 5),
        @as(f64, 19.99),
    });
    std.debug.print("Result: {s}\n", .{buf[0..n]});

    // Allocated string
    std.debug.print("\nAllocated String:\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const str = try variadic.printf.asprintf(
        allocator,
        "System has %d cores and %d MB RAM",
        .{ @as(u32, 8), @as(u64, 16384) },
    );
    defer allocator.free(str);
    std.debug.print("Allocated: {s}\n", .{str});
}
