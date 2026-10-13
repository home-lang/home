// Example: Printf-style formatting

const std = @import("std");
const variadic = @import("variadic");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "=== Printf Example ===\n\n");

    // Basic formatting
    _ = try variadic.printf.printf("Hello, %s!\n", .{"World"});
    _ = try variadic.printf.printf("The answer is %d\n", .{@as(i32, 42)});

    // Multiple arguments
    _ = try variadic.printf.printf("%d + %d = %d\n", .{ @as(i32, 2), @as(i32, 3), @as(i32, 5) });

    // Different number bases
    _ = try variadic.printf.printf("Decimal: %d, Hex: %x, Octal: %o, Binary: %b\n", .{
        @as(u32, 255),
        @as(u32, 255),
        @as(u32, 255),
        @as(u32, 255),
    });

    // Floating point
    _ = try variadic.printf.printf("Pi: %.2f, E: %.5f\n", .{
        @as(f64, 3.14159),
        @as(f64, 2.71828),
    });

    // Width and alignment
    try stdout.writeStreamingAll(io, "\nWidth and Padding:\n");
    _ = try variadic.printf.printf("Right-aligned: [%10d]\n", .{@as(i32, 42)});
    _ = try variadic.printf.printf("Left-aligned:  [%-10d]\n", .{@as(i32, 42)});
    _ = try variadic.printf.printf("Zero-padded:   [%010d]\n", .{@as(i32, 42)});

    // Alternate forms
    try stdout.writeStreamingAll(io, "\nAlternate Forms:\n");
    _ = try variadic.printf.printf("Hex with prefix: %#x\n", .{@as(u32, 255)});
    _ = try variadic.printf.printf("Octal with prefix: %#o\n", .{@as(u32, 64)});

    // Pointers
    try stdout.writeStreamingAll(io, "\nPointers:\n");
    const value: i32 = 100;
    _ = try variadic.printf.printf("Address: %p\n", .{&value});

    // String buffer
    try stdout.writeStreamingAll(io, "\nString Buffer:\n");
    var buf: [256]u8 = undefined;
    const n = try variadic.printf.sprintf(&buf, "Formatted: %d items at $%.2f each", .{
        @as(i32, 5),
        @as(f64, 19.99),
    });
    try stdout.writeStreamingAll(io, "Result: ");
    try stdout.writeStreamingAll(io, buf[0..n]);
    try stdout.writeStreamingAll(io, "\n");

    // Allocated string
    try stdout.writeStreamingAll(io, "\nAllocated String:\n");
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const str = try variadic.printf.asprintf(
        allocator,
        "System has %d cores and %d MB RAM",
        .{ @as(u32, 8), @as(u64, 16384) },
    );
    defer allocator.free(str);
    try stdout.writeStreamingAll(io, "Allocated: ");
    try stdout.writeStreamingAll(io, str);
    try stdout.writeStreamingAll(io, "\n");
}
