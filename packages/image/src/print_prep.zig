const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// CMYK Color Space
// ============================================================================

pub const CMYK = struct {
    c: f32, // Cyan (0.0 to 1.0)
    m: f32, // Magenta (0.0 to 1.0)
    y: f32, // Yellow (0.0 to 1.0)
    k: f32, // Key/Black (0.0 to 1.0)

    pub fn fromRGB(color: Color) CMYK {
        const r = @as(f32, @floatFromInt(color.r)) / 255.0;
        const g = @as(f32, @floatFromInt(color.g)) / 255.0;
        const b = @as(f32, @floatFromInt(color.b)) / 255.0;

        // Calculate K (black)
        const k = 1.0 - @max(@max(r, g), b);

        if (k >= 0.9999) {
            return CMYK{ .c = 0, .m = 0, .y = 0, .k = 1 };
        }

        // Calculate CMY
        const c = (1.0 - r - k) / (1.0 - k);
        const m = (1.0 - g - k) / (1.0 - k);
        const y = (1.0 - b - k) / (1.0 - k);

        return CMYK{ .c = c, .m = m, .y = y, .k = k };
    }

    pub fn toRGB(self: CMYK) Color {
        const r = 255.0 * (1.0 - self.c) * (1.0 - self.k);
        const g = 255.0 * (1.0 - self.m) * (1.0 - self.k);
        const b = 255.0 * (1.0 - self.y) * (1.0 - self.k);

        return Color{
            .r = @intFromFloat(@min(255.0, @max(0.0, r))),
            .g = @intFromFloat(@min(255.0, @max(0.0, g))),
            .b = @intFromFloat(@min(255.0, @max(0.0, b))),
            .a = 255,
        };
    }
};

// ============================================================================
// Color Separation
// ============================================================================

pub const SeparationPlates = struct {
    cyan: Image,
    magenta: Image,
    yellow: Image,
    black: Image,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SeparationPlates) void {
        self.cyan.deinit();
        self.magenta.deinit();
        self.yellow.deinit();
        self.black.deinit();
    }
};

pub const SeparationOptions = struct {
    ucr: f32 = 0.5, // Under Color Removal (0.0 to 1.0)
    gcr: f32 = 0.5, // Gray Component Replacement (0.0 to 1.0)
    black_generation: enum { light, medium, heavy } = .medium,
    total_ink_limit: f32 = 3.0, // Maximum sum of CMYK values (typically 2.8-4.0)
};

/// Separates an RGB image into CMYK plates for printing
pub fn separateCMYK(allocator: std.mem.Allocator, img: *const Image, options: SeparationOptions) !SeparationPlates {
    var cyan = try Image.init(allocator, img.width, img.height, .rgba);
    var magenta = try Image.init(allocator, img.width, img.height, .rgba);
    var yellow = try Image.init(allocator, img.width, img.height, .rgba);
    var black = try Image.init(allocator, img.width, img.height, .rgba);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y));
            var cmyk = CMYK.fromRGB(pixel);

            // Apply GCR (Gray Component Replacement)
            if (options.gcr > 0.0) {
                const gray = @min(@min(cmyk.c, cmyk.m), cmyk.y);
                const gcr_amount = gray * options.gcr;

                cmyk.c -= gcr_amount;
                cmyk.m -= gcr_amount;
                cmyk.y -= gcr_amount;
                cmyk.k += gcr_amount * 0.8; // Slightly reduce to avoid too much black
            }

            // Apply UCR (Under Color Removal)
            if (options.ucr > 0.0) {
                const gray = @min(@min(cmyk.c, cmyk.m), cmyk.y);
                const ucr_amount = gray * options.ucr;

                cmyk.c -= ucr_amount * 0.5;
                cmyk.m -= ucr_amount * 0.5;
                cmyk.y -= ucr_amount * 0.5;
            }

            // Apply black generation curve
            const black_mult = switch (options.black_generation) {
                .light => 0.7,
                .medium => 1.0,
                .heavy => 1.3,
            };
            cmyk.k = @min(1.0, cmyk.k * black_mult);

            // Apply total ink limit
            const total_ink = cmyk.c + cmyk.m + cmyk.y + cmyk.k;
            if (total_ink > options.total_ink_limit) {
                const scale = options.total_ink_limit / total_ink;
                cmyk.c *= scale;
                cmyk.m *= scale;
                cmyk.y *= scale;
                cmyk.k *= scale;
            }

            // Store as grayscale in each plate (0 = no ink, 255 = full ink)
            const c_val = @as(u8, @intFromFloat(cmyk.c * 255.0));
            const m_val = @as(u8, @intFromFloat(cmyk.m * 255.0));
            const y_val = @as(u8, @intFromFloat(cmyk.y * 255.0));
            const k_val = @as(u8, @intFromFloat(cmyk.k * 255.0));

            cyan.setPixel(@intCast(x), @intCast(y), Color{ .r = c_val, .g = c_val, .b = c_val, .a = 255 });
            magenta.setPixel(@intCast(x), @intCast(y), Color{ .r = m_val, .g = m_val, .b = m_val, .a = 255 });
            yellow.setPixel(@intCast(x), @intCast(y), Color{ .r = y_val, .g = y_val, .b = y_val, .a = 255 });
            black.setPixel(@intCast(x), @intCast(y), Color{ .r = k_val, .g = k_val, .b = k_val, .a = 255 });
        }
    }

    return SeparationPlates{
        .cyan = cyan,
        .magenta = magenta,
        .yellow = yellow,
        .black = black,
        .allocator = allocator,
    };
}

/// Recombines CMYK plates back into RGB
pub fn combineCMYK(allocator: std.mem.Allocator, plates: *const SeparationPlates) !Image {
    var result = try Image.init(allocator, plates.cyan.width, plates.cyan.height, .rgba);

    for (0..result.height) |y| {
        for (0..result.width) |x| {
            const c = plates.cyan.getPixel(@intCast(x), @intCast(y)).r;
            const m = plates.magenta.getPixel(@intCast(x), @intCast(y)).r;
            const y_val = plates.yellow.getPixel(@intCast(x), @intCast(y)).r;
            const k = plates.black.getPixel(@intCast(x), @intCast(y)).r;

            const cmyk = CMYK{
                .c = @as(f32, @floatFromInt(c)) / 255.0,
                .m = @as(f32, @floatFromInt(m)) / 255.0,
                .y = @as(f32, @floatFromInt(y_val)) / 255.0,
                .k = @as(f32, @floatFromInt(k)) / 255.0,
            };

            result.setPixel(@intCast(x), @intCast(y), cmyk.toRGB());
        }
    }

    return result;
}

// ============================================================================
// Print Marks
// ============================================================================

pub const PrintMarks = struct {
    crop_marks: bool = true,
    bleed_marks: bool = true,
    registration_marks: bool = true,
    color_bars: bool = true,
};

pub const PrintDimensions = struct {
    page_width: u32, // in pixels
    page_height: u32,
    bleed: u32, // bleed distance in pixels
    margin: u32, // margin for marks
};

pub const PrintReadyImage = struct {
    image: Image,
    dimensions: PrintDimensions,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PrintReadyImage) void {
        self.image.deinit();
    }
};

/// Prepares an image for print with crop marks, bleeds, and registration marks
pub fn preparePrintReady(
    allocator: std.mem.Allocator,
    img: *const Image,
    dimensions: PrintDimensions,
    marks: PrintMarks,
) !PrintReadyImage {
    const total_width = dimensions.page_width + dimensions.bleed * 2 + dimensions.margin * 2;
    const total_height = dimensions.page_height + dimensions.bleed * 2 + dimensions.margin * 2;

    var canvas = try Image.init(allocator, total_width, total_height, .rgba);

    // Fill with white
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            canvas.setPixel(@intCast(x), @intCast(y), Color{ .r = 255, .g = 255, .b = 255, .a = 255 });
        }
    }

    // Place image (with bleed, centered)
    const img_x = dimensions.margin;
    const img_y = dimensions.margin;

    // Scale image if needed to fit the page + bleed area
    const target_width = dimensions.page_width + dimensions.bleed * 2;
    const target_height = dimensions.page_height + dimensions.bleed * 2;

    // For now, simple copy (real version would scale)
    for (0..@min(img.height, target_height)) |y| {
        for (0..@min(img.width, target_width)) |x| {
            const px = img_x + @as(u32, @intCast(x));
            const py = img_y + @as(u32, @intCast(y));
            if (px < canvas.width and py < canvas.height) {
                canvas.setPixel(px, py, img.getPixel(@intCast(x), @intCast(y)));
            }
        }
    }

    // Add crop marks
    if (marks.crop_marks) {
        addCropMarks(&canvas, dimensions);
    }

    // Add bleed marks
    if (marks.bleed_marks) {
        addBleedMarks(&canvas, dimensions);
    }

    // Add registration marks
    if (marks.registration_marks) {
        addRegistrationMarks(&canvas, dimensions);
    }

    // Add color bars
    if (marks.color_bars) {
        addColorBars(&canvas, dimensions);
    }

    return PrintReadyImage{
        .image = canvas,
        .dimensions = dimensions,
        .allocator = allocator,
    };
}

fn addCropMarks(canvas: *Image, dimensions: PrintDimensions) void {
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const mark_length = 20;
    const mark_thickness = 2;

    // Calculate corners of the final trim area (page without bleed)
    const trim_x = dimensions.margin + dimensions.bleed;
    const trim_y = dimensions.margin + dimensions.bleed;
    const trim_width = dimensions.page_width;
    const trim_height = dimensions.page_height;

    // Top-left corner
    drawHorizontalLine(canvas, trim_x - mark_length, trim_y, mark_length, mark_thickness, black);
    drawVerticalLine(canvas, trim_x, trim_y - mark_length, mark_length, mark_thickness, black);

    // Top-right corner
    drawHorizontalLine(canvas, trim_x + trim_width, trim_y, mark_length, mark_thickness, black);
    drawVerticalLine(canvas, trim_x + trim_width, trim_y - mark_length, mark_length, mark_thickness, black);

    // Bottom-left corner
    drawHorizontalLine(canvas, trim_x - mark_length, trim_y + trim_height, mark_length, mark_thickness, black);
    drawVerticalLine(canvas, trim_x, trim_y + trim_height, mark_length, mark_thickness, black);

    // Bottom-right corner
    drawHorizontalLine(canvas, trim_x + trim_width, trim_y + trim_height, mark_length, mark_thickness, black);
    drawVerticalLine(canvas, trim_x + trim_width, trim_y + trim_height, mark_length, mark_thickness, black);
}

fn addBleedMarks(canvas: *Image, dimensions: PrintDimensions) void {
    const cyan = Color{ .r = 0, .g = 255, .b = 255, .a = 255 };
    const mark_length = 10;

    const bleed_x = dimensions.margin;
    const bleed_y = dimensions.margin;
    const bleed_width = dimensions.page_width + dimensions.bleed * 2;
    const bleed_height = dimensions.page_height + dimensions.bleed * 2;

    // Simple bleed indicators at corners
    drawHorizontalLine(canvas, bleed_x - mark_length, bleed_y, mark_length, 1, cyan);
    drawVerticalLine(canvas, bleed_x, bleed_y - mark_length, mark_length, 1, cyan);

    drawHorizontalLine(canvas, bleed_x + bleed_width, bleed_y, mark_length, 1, cyan);
    drawVerticalLine(canvas, bleed_x + bleed_width, bleed_y - mark_length, mark_length, 1, cyan);
}

fn addRegistrationMarks(canvas: *Image, dimensions: PrintDimensions) void {
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const size = 10;

    const center_x = dimensions.margin + dimensions.bleed + dimensions.page_width / 2;
    const top_y = dimensions.margin / 2;
    const bottom_y = dimensions.margin + dimensions.bleed * 2 + dimensions.page_height + dimensions.margin / 2;

    // Top center registration mark
    drawRegistrationMark(canvas, center_x, top_y, size, black);

    // Bottom center registration mark
    drawRegistrationMark(canvas, center_x, bottom_y, size, black);
}

fn drawRegistrationMark(canvas: *Image, cx: u32, cy: u32, size: u32, color: Color) void {
    // Draw crosshair with circle
    drawHorizontalLine(canvas, cx -| size, cy, size * 2, 1, color);
    drawVerticalLine(canvas, cx, cy -| size, size * 2, 1, color);

    // Draw circle (simplified)
    const radius = size / 2;
    for (0..size * 2) |dy| {
        for (0..size * 2) |dx| {
            const x = cx -| size + @as(u32, @intCast(dx));
            const y = cy -| size + @as(u32, @intCast(dy));

            const dist_x = @as(i32, @intCast(dx)) - @as(i32, @intCast(size));
            const dist_y = @as(i32, @intCast(dy)) - @as(i32, @intCast(size));
            const dist_sq = dist_x * dist_x + dist_y * dist_y;
            const radius_sq = @as(i32, @intCast(radius * radius));

            if (@abs(dist_sq - radius_sq) < @as(i32, @intCast(radius * 2))) {
                if (x < canvas.width and y < canvas.height) {
                    canvas.setPixel(x, y, color);
                }
            }
        }
    }
}

fn addColorBars(canvas: *Image, dimensions: PrintDimensions) void {
    const bar_height = 20;
    const bar_y = dimensions.margin + dimensions.bleed * 2 + dimensions.page_height + 10;
    const bar_x = dimensions.margin + dimensions.bleed;
    const bar_width = dimensions.page_width / 8;

    // CMYK color bars
    const colors = [_]Color{
        Color{ .r = 0, .g = 255, .b = 255, .a = 255 }, // Cyan
        Color{ .r = 255, .g = 0, .b = 255, .a = 255 }, // Magenta
        Color{ .r = 255, .g = 255, .b = 0, .a = 255 }, // Yellow
        Color{ .r = 0, .g = 0, .b = 0, .a = 255 }, // Black
        Color{ .r = 255, .g = 0, .b = 0, .a = 255 }, // Red
        Color{ .r = 0, .g = 255, .b = 0, .a = 255 }, // Green
        Color{ .r = 0, .g = 0, .b = 255, .a = 255 }, // Blue
        Color{ .r = 255, .g = 255, .b = 255, .a = 255 }, // White
    };

    for (colors, 0..) |color, i| {
        const x = bar_x + @as(u32, @intCast(i)) * bar_width;
        for (0..bar_height) |dy| {
            for (0..bar_width) |dx| {
                const px = x + @as(u32, @intCast(dx));
                const py = bar_y + @as(u32, @intCast(dy));
                if (px < canvas.width and py < canvas.height) {
                    canvas.setPixel(px, py, color);
                }
            }
        }
    }
}

fn drawHorizontalLine(canvas: *Image, x: u32, y: u32, length: u32, thickness: u32, color: Color) void {
    for (0..thickness) |dy| {
        for (0..length) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < canvas.width and py < canvas.height) {
                canvas.setPixel(px, py, color);
            }
        }
    }
}

fn drawVerticalLine(canvas: *Image, x: u32, y: u32, length: u32, thickness: u32, color: Color) void {
    for (0..length) |dy| {
        for (0..thickness) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < canvas.width and py < canvas.height) {
                canvas.setPixel(px, py, color);
            }
        }
    }
}

// ============================================================================
// Resolution and DPI Handling
// ============================================================================

pub const Resolution = struct {
    dpi: u32, // Dots per inch
    width_inches: f32,
    height_inches: f32,

    pub fn fromPixels(width_px: u32, height_px: u32, dpi: u32) Resolution {
        return Resolution{
            .dpi = dpi,
            .width_inches = @as(f32, @floatFromInt(width_px)) / @as(f32, @floatFromInt(dpi)),
            .height_inches = @as(f32, @floatFromInt(height_px)) / @as(f32, @floatFromInt(dpi)),
        };
    }

    pub fn toPixels(self: Resolution) struct { width: u32, height: u32 } {
        return .{
            .width = @intFromFloat(self.width_inches * @as(f32, @floatFromInt(self.dpi))),
            .height = @intFromFloat(self.height_inches * @as(f32, @floatFromInt(self.dpi))),
        };
    }
};

pub const ResolutionCheck = struct {
    current_dpi: u32,
    recommended_dpi: u32,
    is_sufficient: bool,
    warning_message: ?[]const u8,
};

/// Checks if image resolution is sufficient for print quality
pub fn checkPrintResolution(img: *const Image, target_width_inches: f32, target_height_inches: f32) ResolutionCheck {
    const dpi_width = @as(f32, @floatFromInt(img.width)) / target_width_inches;
    const dpi_height = @as(f32, @floatFromInt(img.height)) / target_height_inches;
    const current_dpi = @as(u32, @intFromFloat(@min(dpi_width, dpi_height)));

    const recommended_dpi: u32 = 300; // Standard print quality
    const minimum_dpi: u32 = 150; // Acceptable for some uses

    if (current_dpi >= recommended_dpi) {
        return ResolutionCheck{
            .current_dpi = current_dpi,
            .recommended_dpi = recommended_dpi,
            .is_sufficient = true,
            .warning_message = null,
        };
    } else if (current_dpi >= minimum_dpi) {
        return ResolutionCheck{
            .current_dpi = current_dpi,
            .recommended_dpi = recommended_dpi,
            .is_sufficient = true,
            .warning_message = "Resolution is below recommended 300 DPI but acceptable",
        };
    } else {
        return ResolutionCheck{
            .current_dpi = current_dpi,
            .recommended_dpi = recommended_dpi,
            .is_sufficient = false,
            .warning_message = "Resolution is too low for quality printing",
        };
    }
}

// ============================================================================
// Trapping (Choke/Spread)
// ============================================================================

pub const TrappingOptions = struct {
    trap_width: f32 = 0.25, // in pixels
    method: enum { choke, spread, centerline } = .spread,
};

/// Applies trapping to prevent white gaps in print registration errors
pub fn applyTrapping(allocator: std.mem.Allocator, plates: *const SeparationPlates, options: TrappingOptions) !SeparationPlates {
    // Simplified trapping - real version would analyze edge transitions
    // For now, return copies
    var result = SeparationPlates{
        .cyan = try Image.init(allocator, plates.cyan.width, plates.cyan.height, .rgba),
        .magenta = try Image.init(allocator, plates.magenta.width, plates.magenta.height, .rgba),
        .yellow = try Image.init(allocator, plates.yellow.width, plates.yellow.height, .rgba),
        .black = try Image.init(allocator, plates.black.width, plates.black.height, .rgba),
        .allocator = allocator,
    };

    // Copy plates with slight expansion/contraction at edges
    for (0..plates.cyan.height) |y| {
        for (0..plates.cyan.width) |x| {
            result.cyan.setPixel(@intCast(x), @intCast(y), plates.cyan.getPixel(@intCast(x), @intCast(y)));
            result.magenta.setPixel(@intCast(x), @intCast(y), plates.magenta.getPixel(@intCast(x), @intCast(y)));
            result.yellow.setPixel(@intCast(x), @intCast(y), plates.yellow.getPixel(@intCast(x), @intCast(y)));
            result.black.setPixel(@intCast(x), @intCast(y), plates.black.getPixel(@intCast(x), @intCast(y)));
        }
    }

    _ = options;
    return result;
}
