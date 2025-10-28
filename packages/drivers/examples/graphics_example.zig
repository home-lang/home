// Example: Graphics Driver Usage

const std = @import("std");
const drivers = @import("drivers");

pub fn main() !void {
    std.debug.print("=== Graphics Driver Example ===\n\n", .{});

    // Pixel format information
    std.debug.print("Pixel Formats:\n", .{});
    const formats = [_]drivers.graphics.PixelFormat{
        .rgba8888,
        .rgb888,
        .rgb565,
        .indexed8,
    };

    for (formats) |format| {
        std.debug.print("  {s}: {d} bytes/pixel, {d} bits/pixel\n", .{
            @tagName(format),
            format.bytesPerPixel(),
            format.bitsPerPixel(),
        });
    }

    // Color creation
    std.debug.print("\nColor Examples:\n", .{});
    const colors = [_]struct { name: []const u8, color: drivers.graphics.Color }{
        .{ .name = "Red", .color = drivers.graphics.Color.RED },
        .{ .name = "Green", .color = drivers.graphics.Color.GREEN },
        .{ .name = "Blue", .color = drivers.graphics.Color.BLUE },
        .{ .name = "White", .color = drivers.graphics.Color.WHITE },
        .{ .name = "Custom", .color = drivers.graphics.Color.rgb(128, 64, 192) },
    };

    for (colors) |item| {
        std.debug.print("  {s}: R={d}, G={d}, B={d}\n", .{
            item.name,
            item.color.r,
            item.color.g,
            item.color.b,
        });
        std.debug.print("    RGBA8888: 0x{X:0>8}\n", .{item.color.toU32(.rgba8888)});
        std.debug.print("    RGB565: 0x{X:0>4}\n", .{item.color.toU32(.rgb565)});
    }

    // Simulated framebuffer (using allocated memory instead of actual hardware)
    std.debug.print("\nSimulated Framebuffer:\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const width = 640;
    const height = 480;
    const format = drivers.graphics.PixelFormat.rgba8888;
    const pitch = width * format.bytesPerPixel();

    // Allocate simulated framebuffer memory
    const fb_size = pitch * height;
    const fb_memory = try allocator.alloc(u8, fb_size);
    defer allocator.free(fb_memory);

    const fb_info = drivers.graphics.FramebufferInfo{
        .address = @intFromPtr(fb_memory.ptr),
        .width = width,
        .height = height,
        .pitch = pitch,
        .bpp = format.bitsPerPixel(),
        .format = format,
    };

    var fb = drivers.graphics.Framebuffer.init(fb_info);

    std.debug.print("  Resolution: {d}x{d}\n", .{ width, height });
    std.debug.print("  Pitch: {d} bytes\n", .{pitch});
    std.debug.print("  Format: {s}\n", .{@tagName(format)});
    std.debug.print("  Total Size: {d} bytes\n", .{fb_size});

    // Drawing operations
    std.debug.print("\nDrawing Operations:\n", .{});
    fb.clear(drivers.graphics.Color.BLACK);
    std.debug.print("  Cleared to black\n", .{});

    fb.drawRect(10, 10, 100, 50, drivers.graphics.Color.RED);
    std.debug.print("  Drew red rectangle at (10, 10) size 100x50\n", .{});

    fb.drawLine(0, 0, 100, 100, drivers.graphics.Color.GREEN);
    std.debug.print("  Drew green line from (0, 0) to (100, 100)\n", .{});

    fb.drawCircle(320, 240, 50, drivers.graphics.Color.BLUE);
    std.debug.print("  Drew blue circle at (320, 240) radius 50\n", .{});

    // Verify pixel
    if (fb.getPixel(10, 10)) |pixel| {
        std.debug.print("\nPixel at (10, 10): R={d}, G={d}, B={d}\n", .{
            pixel.r,
            pixel.g,
            pixel.b,
        });
    }

    // VGA Text Mode
    std.debug.print("\nVGA Text Mode:\n", .{});
    std.debug.print("  Default Address: 0x{X}\n", .{drivers.graphics.VGAText.DEFAULT_ADDRESS});
    std.debug.print("  Default Size: {d}x{d}\n", .{
        drivers.graphics.VGAText.DEFAULT_WIDTH,
        drivers.graphics.VGAText.DEFAULT_HEIGHT,
    });

    const entry = drivers.graphics.VGAText.makeEntry('A', .white, .blue);
    std.debug.print("  Text Entry 'A' (white on blue): 0x{X:0>4}\n", .{entry});

    std.debug.print("\nGraphics driver API demonstration complete!\n", .{});
}
