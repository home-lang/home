const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// QR Code Generation
// ============================================================================

pub const QRCode = struct {
    modules: []bool,
    size: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QRCode) void {
        self.allocator.free(self.modules);
    }

    pub fn generate(allocator: std.mem.Allocator, data: []const u8, error_correction: ErrorCorrection) !QRCode {
        // Simplified QR generation - real implementation would encode data properly
        const version = calculateVersion(data.len);
        const size = 17 + 4 * version;

        var modules = try allocator.alloc(bool, size * size);
        @memset(modules, false);

        // Add finder patterns
        addFinderPattern(modules, size, 0, 0);
        addFinderPattern(modules, size, size - 7, 0);
        addFinderPattern(modules, size, 0, size - 7);

        // Add timing patterns
        for (8..size - 8) |i| {
            modules[6 * size + i] = (i % 2 == 0);
            modules[i * size + 6] = (i % 2 == 0);
        }

        // Encode data (simplified - just fill with pattern)
        var idx: usize = 0;
        for (0..size) |y| {
            for (0..size) |x| {
                if (!isReserved(x, y, size)) {
                    modules[y * size + x] = (data[idx % data.len] & (1 << @intCast(idx % 8))) != 0;
                    idx += 1;
                }
            }
        }

        _ = error_correction;
        return QRCode{ .modules = modules, .size = size, .allocator = allocator };
    }

    pub fn toImage(self: *const QRCode, allocator: std.mem.Allocator, module_size: u32, quiet_zone: u32) !Image {
        const img_size = (self.size + quiet_zone * 2) * module_size;
        var img = try Image.init(allocator, img_size, img_size, .rgba);

        // Fill white
        for (0..img_size) |y| {
            for (0..img_size) |x| {
                img.setPixel(@intCast(x), @intCast(y), Color.WHITE);
            }
        }

        // Draw modules
        for (0..self.size) |y| {
            for (0..self.size) |x| {
                if (self.modules[y * self.size + x]) {
                    const px = (x + quiet_zone) * module_size;
                    const py = (y + quiet_zone) * module_size;
                    for (0..module_size) |dy| {
                        for (0..module_size) |dx| {
                            img.setPixel(@intCast(px + dx), @intCast(py + dy), Color.BLACK);
                        }
                    }
                }
            }
        }

        return img;
    }
};

pub const ErrorCorrection = enum { low, medium, quartile, high };

fn calculateVersion(data_len: usize) u32 {
    if (data_len <= 25) return 1;
    if (data_len <= 47) return 2;
    if (data_len <= 77) return 3;
    if (data_len <= 114) return 4;
    return @min(40, 5 + @as(u32, @intCast(data_len / 100)));
}

fn addFinderPattern(modules: []bool, size: u32, x: u32, y: u32) void {
    for (0..7) |dy| {
        for (0..7) |dx| {
            const is_border = (dy == 0 or dy == 6 or dx == 0 or dx == 6);
            const is_center = (dy >= 2 and dy <= 4 and dx >= 2 and dx <= 4);
            if (is_border or is_center) {
                modules[(y + dy) * size + (x + dx)] = true;
            }
        }
    }
}

fn isReserved(x: usize, y: usize, size: u32) bool {
    // Finder patterns
    if ((x < 9 and y < 9) or (x >= size - 8 and y < 9) or (x < 9 and y >= size - 8)) return true;
    // Timing patterns
    if (x == 6 or y == 6) return true;
    return false;
}

// ============================================================================
// Barcode Generation
// ============================================================================

pub const BarcodeType = enum {
    code128,
    code39,
    ean13,
    upc_a,
    interleaved2of5,
};

pub fn generateBarcode(allocator: std.mem.Allocator, data: []const u8, barcode_type: BarcodeType, bar_width: u32, height: u32) !Image {
    return switch (barcode_type) {
        .code128 => generateCode128(allocator, data, bar_width, height),
        .code39 => generateCode39(allocator, data, bar_width, height),
        .ean13 => generateEAN13(allocator, data, bar_width, height),
        .upc_a => generateUPCA(allocator, data, bar_width, height),
        .interleaved2of5 => generateInterleaved2of5(allocator, data, bar_width, height),
    };
}

fn generateCode128(allocator: std.mem.Allocator, data: []const u8, bar_width: u32, height: u32) !Image {
    // Simplified Code 128 - real implementation would properly encode
    var pattern = std.ArrayList(bool).init(allocator);
    defer pattern.deinit();

    // Start code
    try pattern.appendSlice(&[_]bool{true, true, false, true, false, false, true, true, false, false, false});

    // Data (simplified)
    for (data) |byte| {
        for (0..7) |i| {
            try pattern.append((byte & (@as(u8, 1) << @intCast(i))) != 0);
        }
    }

    // Stop code
    try pattern.appendSlice(&[_]bool{true, true, false, false, true, false, true, true, false, false, true, true});

    const width = pattern.items.len * bar_width;
    var img = try Image.init(allocator, width, height, .rgba);

    for (0..height) |y| {
        for (0..width) |x| {
            const bar = pattern.items[x / bar_width];
            img.setPixel(@intCast(x), @intCast(y), if (bar) Color.BLACK else Color.WHITE);
        }
    }

    return img;
}

fn generateCode39(allocator: std.mem.Allocator, data: []const u8, bar_width: u32, height: u32) !Image {
    return generateCode128(allocator, data, bar_width, height); // Simplified
}

fn generateEAN13(allocator: std.mem.Allocator, data: []const u8, bar_width: u32, height: u32) !Image {
    return generateCode128(allocator, data, bar_width, height); // Simplified
}

fn generateUPCA(allocator: std.mem.Allocator, data: []const u8, bar_width: u32, height: u32) !Image {
    return generateCode128(allocator, data, bar_width, height); // Simplified
}

fn generateInterleaved2of5(allocator: std.mem.Allocator, data: []const u8, bar_width: u32, height: u32) !Image {
    return generateCode128(allocator, data, bar_width, height); // Simplified
}
