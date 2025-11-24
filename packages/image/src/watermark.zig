const std = @import("std");
const Image = @import("image.zig").Image;
const blend = @import("blend.zig");
const draw = @import("draw.zig");

/// Watermark positioning options
pub const Position = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,
    tile, // Repeat watermark across entire image
    custom, // Use custom x, y coordinates
};

/// Watermark configuration
pub const WatermarkConfig = struct {
    position: Position = .bottom_right,
    custom_x: i32 = 0,
    custom_y: i32 = 0,
    opacity: f32 = 0.5,
    blend_mode: blend.BlendMode = .normal,
    padding: u32 = 10,
    scale: f32 = 1.0,
    tile_spacing_x: u32 = 50,
    tile_spacing_y: u32 = 50,
    rotation: f32 = 0.0, // Rotation in radians (for tiled watermarks)
};

/// Text watermark configuration
pub const TextWatermarkConfig = struct {
    position: Position = .bottom_right,
    custom_x: i32 = 0,
    custom_y: i32 = 0,
    opacity: f32 = 0.5,
    padding: u32 = 10,
    scale: u32 = 2,
    color: [4]u8 = .{ 255, 255, 255, 255 },
    shadow: bool = true,
    shadow_color: [4]u8 = .{ 0, 0, 0, 128 },
    shadow_offset_x: i32 = 2,
    shadow_offset_y: i32 = 2,
};

/// Invisible watermark encoding options
pub const InvisibleWatermarkConfig = struct {
    strength: f32 = 0.02, // How much to modify pixel values (lower = less visible)
    channel: Channel = .blue, // Which channel to embed in
    seed: u64 = 0, // For pseudo-random bit placement
};

pub const Channel = enum {
    red,
    green,
    blue,
    all,
};

/// Apply an image watermark to the target image
pub fn applyImageWatermark(
    target: *Image,
    watermark: *const Image,
    config: WatermarkConfig,
) void {
    const scaled_width: u32 = @intFromFloat(@as(f32, @floatFromInt(watermark.width)) * config.scale);
    const scaled_height: u32 = @intFromFloat(@as(f32, @floatFromInt(watermark.height)) * config.scale);

    if (config.position == .tile) {
        applyTiledWatermark(target, watermark, config, scaled_width, scaled_height);
        return;
    }

    const pos = calculatePosition(
        target.width,
        target.height,
        scaled_width,
        scaled_height,
        config.position,
        config.custom_x,
        config.custom_y,
        config.padding,
    );

    blendWatermarkAt(target, watermark, pos.x, pos.y, config.opacity, config.blend_mode, config.scale);
}

/// Apply a tiled watermark pattern across the entire image
fn applyTiledWatermark(
    target: *Image,
    watermark: *const Image,
    config: WatermarkConfig,
    scaled_width: u32,
    scaled_height: u32,
) void {
    const spacing_x = scaled_width + config.tile_spacing_x;
    const spacing_y = scaled_height + config.tile_spacing_y;

    var y: i32 = -@as(i32, @intCast(scaled_height / 2));
    while (y < @as(i32, @intCast(target.height + scaled_height))) : (y += @intCast(spacing_y)) {
        var x: i32 = -@as(i32, @intCast(scaled_width / 2));
        while (x < @as(i32, @intCast(target.width + scaled_width))) : (x += @intCast(spacing_x)) {
            blendWatermarkAt(target, watermark, x, y, config.opacity, config.blend_mode, config.scale);
        }
    }
}

/// Calculate watermark position based on configuration
fn calculatePosition(
    target_width: u32,
    target_height: u32,
    watermark_width: u32,
    watermark_height: u32,
    position: Position,
    custom_x: i32,
    custom_y: i32,
    padding: u32,
) struct { x: i32, y: i32 } {
    const tw = @as(i32, @intCast(target_width));
    const th = @as(i32, @intCast(target_height));
    const ww = @as(i32, @intCast(watermark_width));
    const wh = @as(i32, @intCast(watermark_height));
    const pad = @as(i32, @intCast(padding));

    return switch (position) {
        .top_left => .{ .x = pad, .y = pad },
        .top_center => .{ .x = @divTrunc(tw - ww, 2), .y = pad },
        .top_right => .{ .x = tw - ww - pad, .y = pad },
        .center_left => .{ .x = pad, .y = @divTrunc(th - wh, 2) },
        .center => .{ .x = @divTrunc(tw - ww, 2), .y = @divTrunc(th - wh, 2) },
        .center_right => .{ .x = tw - ww - pad, .y = @divTrunc(th - wh, 2) },
        .bottom_left => .{ .x = pad, .y = th - wh - pad },
        .bottom_center => .{ .x = @divTrunc(tw - ww, 2), .y = th - wh - pad },
        .bottom_right => .{ .x = tw - ww - pad, .y = th - wh - pad },
        .custom => .{ .x = custom_x, .y = custom_y },
        .tile => .{ .x = 0, .y = 0 }, // Handled separately
    };
}

/// Blend watermark onto target at specified position
fn blendWatermarkAt(
    target: *Image,
    watermark: *const Image,
    x: i32,
    y: i32,
    opacity: f32,
    blend_mode: blend.BlendMode,
    scale: f32,
) void {
    const bytes_per_pixel: u32 = switch (target.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const wm_bytes_per_pixel: u32 = switch (watermark.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    var wy: u32 = 0;
    while (wy < watermark.height) : (wy += 1) {
        const scaled_y: i32 = y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(wy)) * scale));
        if (scaled_y < 0 or scaled_y >= @as(i32, @intCast(target.height))) continue;

        var wx: u32 = 0;
        while (wx < watermark.width) : (wx += 1) {
            const scaled_x: i32 = x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(wx)) * scale));
            if (scaled_x < 0 or scaled_x >= @as(i32, @intCast(target.width))) continue;

            const tx = @as(u32, @intCast(scaled_x));
            const ty = @as(u32, @intCast(scaled_y));

            // Get watermark pixel
            const wm_idx = (wy * watermark.width + wx) * wm_bytes_per_pixel;
            const wm_pixel = getPixelRGBA(watermark.pixels, wm_idx, wm_bytes_per_pixel);

            // Get target pixel
            const t_idx = (ty * target.width + tx) * bytes_per_pixel;
            const t_pixel = getPixelRGBA(target.pixels, t_idx, bytes_per_pixel);

            // Apply opacity to watermark alpha
            var wm_with_opacity = wm_pixel;
            wm_with_opacity[3] = @intFromFloat(@as(f32, @floatFromInt(wm_pixel[3])) * opacity);

            // Blend
            const result = blend.blend(t_pixel, wm_with_opacity, blend_mode, 1.0);

            // Write back
            setPixelRGBA(target.pixels, t_idx, bytes_per_pixel, result);
        }
    }
}

/// Get pixel as RGBA
fn getPixelRGBA(pixels: []const u8, idx: u32, bpp: u32) [4]u8 {
    if (idx + bpp > pixels.len) return .{ 0, 0, 0, 0 };

    return switch (bpp) {
        1 => .{ pixels[idx], pixels[idx], pixels[idx], 255 },
        2 => .{ pixels[idx], pixels[idx], pixels[idx], pixels[idx + 1] },
        3 => .{ pixels[idx], pixels[idx + 1], pixels[idx + 2], 255 },
        4 => .{ pixels[idx], pixels[idx + 1], pixels[idx + 2], pixels[idx + 3] },
        else => .{ 0, 0, 0, 255 },
    };
}

/// Set pixel from RGBA
fn setPixelRGBA(pixels: []u8, idx: u32, bpp: u32, color: [4]u8) void {
    if (idx + bpp > pixels.len) return;

    switch (bpp) {
        1 => {
            // Convert to grayscale
            pixels[idx] = @intFromFloat(
                @as(f32, @floatFromInt(color[0])) * 0.299 +
                    @as(f32, @floatFromInt(color[1])) * 0.587 +
                    @as(f32, @floatFromInt(color[2])) * 0.114,
            );
        },
        2 => {
            pixels[idx] = @intFromFloat(
                @as(f32, @floatFromInt(color[0])) * 0.299 +
                    @as(f32, @floatFromInt(color[1])) * 0.587 +
                    @as(f32, @floatFromInt(color[2])) * 0.114,
            );
            pixels[idx + 1] = color[3];
        },
        3 => {
            pixels[idx] = color[0];
            pixels[idx + 1] = color[1];
            pixels[idx + 2] = color[2];
        },
        4 => {
            pixels[idx] = color[0];
            pixels[idx + 1] = color[1];
            pixels[idx + 2] = color[2];
            pixels[idx + 3] = color[3];
        },
        else => {},
    }
}

/// Apply a text watermark to the image
pub fn applyTextWatermark(
    target: *Image,
    text: []const u8,
    config: TextWatermarkConfig,
) void {
    // Calculate text dimensions
    const char_width: u32 = 8 * config.scale;
    const text_width: u32 = @intCast(text.len * char_width);
    const text_height: u32 = 8 * config.scale;

    const pos = calculatePosition(
        target.width,
        target.height,
        text_width,
        text_height,
        config.position,
        config.custom_x,
        config.custom_y,
        config.padding,
    );

    // Draw shadow first
    if (config.shadow) {
        var shadow_color = config.shadow_color;
        shadow_color[3] = @intFromFloat(@as(f32, @floatFromInt(shadow_color[3])) * config.opacity);
        draw.textScaled(
            target,
            text,
            pos.x + config.shadow_offset_x,
            pos.y + config.shadow_offset_y,
            shadow_color,
            config.scale,
        );
    }

    // Draw text
    var text_color = config.color;
    text_color[3] = @intFromFloat(@as(f32, @floatFromInt(text_color[3])) * config.opacity);
    draw.textScaled(target, text, pos.x, pos.y, text_color, config.scale);
}

/// Encode an invisible watermark using LSB steganography
pub fn encodeInvisibleWatermark(
    image: *Image,
    data: []const u8,
    config: InvisibleWatermarkConfig,
) !void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    // Calculate maximum capacity (1 bit per selected channel per pixel)
    const total_pixels = image.width * image.height;
    const bits_needed = (data.len + 4) * 8; // +4 for length header

    const channels_used: u32 = if (config.channel == .all) 3 else 1;
    const max_bits = total_pixels * channels_used;

    if (bits_needed > max_bits) {
        return error.DataTooLarge;
    }

    // Create PRNG for pseudo-random bit placement
    var rng = std.Random.DefaultPrng.init(config.seed);
    const random = rng.random();

    // First, encode the length (32 bits)
    const length: u32 = @intCast(data.len);
    var bit_index: u32 = 0;

    // Encode length
    for (0..32) |i| {
        const bit: u1 = @truncate((length >> @intCast(31 - i)) & 1);
        const pixel_idx = getPixelForBit(bit_index, total_pixels, random);
        const channel_offset = getChannelOffset(config.channel, bit_index);

        const idx = pixel_idx * bytes_per_pixel + channel_offset;
        if (idx < image.pixels.len) {
            image.pixels[idx] = (image.pixels[idx] & 0xFE) | bit;
        }
        bit_index += 1;
    }

    // Encode data
    for (data) |byte| {
        for (0..8) |i| {
            const bit: u1 = @truncate((byte >> @intCast(7 - i)) & 1);
            const pixel_idx = getPixelForBit(bit_index, total_pixels, random);
            const channel_offset = getChannelOffset(config.channel, bit_index);

            const idx = pixel_idx * bytes_per_pixel + channel_offset;
            if (idx < image.pixels.len) {
                image.pixels[idx] = (image.pixels[idx] & 0xFE) | bit;
            }
            bit_index += 1;
        }
    }
}

/// Decode an invisible watermark from an image
pub fn decodeInvisibleWatermark(
    image: *const Image,
    config: InvisibleWatermarkConfig,
    allocator: std.mem.Allocator,
) ![]u8 {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const total_pixels = image.width * image.height;

    // Create PRNG with same seed
    var rng = std.Random.DefaultPrng.init(config.seed);
    const random = rng.random();

    // Decode length first (32 bits)
    var length: u32 = 0;
    var bit_index: u32 = 0;

    for (0..32) |_| {
        const pixel_idx = getPixelForBit(bit_index, total_pixels, random);
        const channel_offset = getChannelOffset(config.channel, bit_index);

        const idx = pixel_idx * bytes_per_pixel + channel_offset;
        if (idx < image.pixels.len) {
            const bit: u32 = image.pixels[idx] & 1;
            length = (length << 1) | bit;
        }
        bit_index += 1;
    }

    // Sanity check length
    if (length > total_pixels / 8) {
        return error.InvalidWatermark;
    }

    // Decode data
    const data = try allocator.alloc(u8, length);
    errdefer allocator.free(data);

    for (0..length) |byte_idx| {
        var byte: u8 = 0;
        for (0..8) |_| {
            const pixel_idx = getPixelForBit(bit_index, total_pixels, random);
            const channel_offset = getChannelOffset(config.channel, bit_index);

            const idx = pixel_idx * bytes_per_pixel + channel_offset;
            if (idx < image.pixels.len) {
                const bit: u8 = image.pixels[idx] & 1;
                byte = (byte << 1) | bit;
            }
            bit_index += 1;
        }
        data[byte_idx] = byte;
    }

    return data;
}

/// Get pixel index for a given bit (with optional pseudo-random distribution)
fn getPixelForBit(bit_index: u32, total_pixels: u32, random: std.Random) u32 {
    _ = random;
    // Simple sequential for now - could use random for more security
    return bit_index % total_pixels;
}

/// Get channel offset for embedding
fn getChannelOffset(channel: Channel, bit_index: u32) u32 {
    return switch (channel) {
        .red => 0,
        .green => 1,
        .blue => 2,
        .all => bit_index % 3,
    };
}

/// Apply a semi-transparent color overlay as watermark
pub fn applyColorOverlay(
    image: *Image,
    color: [4]u8,
    opacity: f32,
    region: ?struct { x: u32, y: u32, width: u32, height: u32 },
) void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const start_x = if (region) |r| r.x else 0;
    const start_y = if (region) |r| r.y else 0;
    const end_x = if (region) |r| @min(r.x + r.width, image.width) else image.width;
    const end_y = if (region) |r| @min(r.y + r.height, image.height) else image.height;

    var overlay_color = color;
    overlay_color[3] = @intFromFloat(@as(f32, @floatFromInt(color[3])) * opacity);

    var y = start_y;
    while (y < end_y) : (y += 1) {
        var x = start_x;
        while (x < end_x) : (x += 1) {
            const idx = (y * image.width + x) * bytes_per_pixel;
            const pixel = getPixelRGBA(image.pixels, idx, bytes_per_pixel);
            const result = blend.blend(pixel, overlay_color, .normal, 1.0);
            setPixelRGBA(image.pixels, idx, bytes_per_pixel, result);
        }
    }
}

/// Apply a diagonal stripe pattern (common for stock photo watermarks)
pub fn applyDiagonalStripes(
    image: *Image,
    color: [4]u8,
    stripe_width: u32,
    gap_width: u32,
    opacity: f32,
) void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const period = stripe_width + gap_width;

    var stripe_color = color;
    stripe_color[3] = @intFromFloat(@as(f32, @floatFromInt(color[3])) * opacity);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const diagonal_pos = (x + y) % period;
            if (diagonal_pos < stripe_width) {
                const idx = (y * image.width + x) * bytes_per_pixel;
                const pixel = getPixelRGBA(image.pixels, idx, bytes_per_pixel);
                const result = blend.blend(pixel, stripe_color, .normal, 1.0);
                setPixelRGBA(image.pixels, idx, bytes_per_pixel, result);
            }
        }
    }
}

/// Apply a grid pattern watermark
pub fn applyGridPattern(
    image: *Image,
    color: [4]u8,
    cell_size: u32,
    line_width: u32,
    opacity: f32,
) void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    var grid_color = color;
    grid_color[3] = @intFromFloat(@as(f32, @floatFromInt(color[3])) * opacity);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const on_vertical_line = (x % cell_size) < line_width;
            const on_horizontal_line = (y % cell_size) < line_width;

            if (on_vertical_line or on_horizontal_line) {
                const idx = (y * image.width + x) * bytes_per_pixel;
                const pixel = getPixelRGBA(image.pixels, idx, bytes_per_pixel);
                const result = blend.blend(pixel, grid_color, .normal, 1.0);
                setPixelRGBA(image.pixels, idx, bytes_per_pixel, result);
            }
        }
    }
}

/// Generate a fingerprint hash from image for ownership verification
pub fn generateFingerprint(image: *const Image) u64 {
    // Use a simple but effective fingerprint based on pixel sampling
    var hash: u64 = 0;
    const sample_count: u32 = 64;

    const step_x = @max(1, image.width / 8);
    const step_y = @max(1, image.height / 8);

    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    var count: u32 = 0;
    var y: u32 = 0;
    while (y < image.height and count < sample_count) : (y += step_y) {
        var x: u32 = 0;
        while (x < image.width and count < sample_count) : (x += step_x) {
            const idx = (y * image.width + x) * bytes_per_pixel;
            if (idx < image.pixels.len) {
                const pixel = getPixelRGBA(image.pixels, idx, bytes_per_pixel);
                // Mix pixel values into hash
                const pixel_val: u64 = @as(u64, pixel[0]) << 24 |
                    @as(u64, pixel[1]) << 16 |
                    @as(u64, pixel[2]) << 8 |
                    @as(u64, pixel[3]);
                hash = hash *% 31 +% pixel_val;
            }
            count += 1;
        }
    }

    return hash;
}
