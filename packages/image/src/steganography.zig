const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// LSB (Least Significant Bit) Steganography
// ============================================================================

pub const LSBOptions = struct {
    bits_per_channel: u3 = 1, // Number of LSBs to use (1-4)
    use_alpha: bool = false, // Whether to use alpha channel
    encryption: ?[]const u8 = null, // Optional encryption key
};

/// Encodes data into an image using LSB steganography
pub fn encodeLSB(allocator: std.mem.Allocator, img: *const Image, data: []const u8, options: LSBOptions) !Image {
    try validateLSBOptions(img, options);
    if (data.len > std.math.maxInt(u32)) return error.DataTooLarge;
    const carrier_bits = try calculateCarrierBits(img, options);
    if (carrier_bits < 32 or data.len > (carrier_bits - 32) / 8) return error.InsufficientCapacity;

    var result = try Image.init(allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    // Copy original image
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            result.setPixel(
                @intCast(x),
                @intCast(y),
                img.getPixel(@intCast(x), @intCast(y)) orelse return error.UnsupportedFormat,
            );
        }
    }

    // Prepare data with length header
    const message_len = std.math.add(usize, 4, data.len) catch return error.DataTooLarge;
    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);

    // Add 4-byte length header
    std.mem.writeInt(u32, message[0..4], @intCast(data.len), .big);
    @memcpy(message[4..], data);

    // Optional simple XOR encryption
    if (options.encryption) |key| {
        for (message[4..], 0..) |*byte, i| {
            byte.* ^= key[i % key.len];
        }
    }

    // Encode data into LSBs
    var bit_index: usize = 0;
    const total_bits = std.math.mul(usize, message.len, 8) catch return error.DataTooLarge;
    const mask = (@as(u8, 1) << options.bits_per_channel) - 1;

    outer: for (0..result.height) |y| {
        for (0..result.width) |x| {
            if (bit_index >= total_bits) break :outer;

            var pixel = result.getPixel(@intCast(x), @intCast(y)) orelse return error.UnsupportedFormat;

            // Encode in R channel
            if (bit_index < total_bits) {
                embedChannel(&pixel.r, message, &bit_index, options.bits_per_channel, mask);
            }

            // Encode in G channel
            if (bit_index < total_bits) {
                embedChannel(&pixel.g, message, &bit_index, options.bits_per_channel, mask);
            }

            // Encode in B channel
            if (bit_index < total_bits) {
                embedChannel(&pixel.b, message, &bit_index, options.bits_per_channel, mask);
            }

            // Encode in A channel if enabled
            if (options.use_alpha and bit_index < total_bits) {
                embedChannel(&pixel.a, message, &bit_index, options.bits_per_channel, mask);
            }

            result.setPixel(@intCast(x), @intCast(y), pixel);
        }
    }

    return result;
}

/// Decodes data from an image using LSB steganography
pub fn decodeLSB(allocator: std.mem.Allocator, img: *const Image, options: LSBOptions) ![]u8 {
    try validateLSBOptions(img, options);

    var header: [4]u8 = undefined;
    try extractBitsInto(img, options, 0, &header);

    // Parse length from header
    const data_len = std.mem.readInt(u32, &header, .big);
    if (data_len > try calculateCapacity(img, options)) return error.InvalidLength;

    // Extract the actual data
    const result = try allocator.alloc(u8, data_len);
    errdefer allocator.free(result);
    try extractBitsInto(img, options, 32, result);

    // Decrypt if needed
    if (options.encryption) |key| {
        for (result, 0..) |*byte, i| {
            byte.* ^= key[i % key.len];
        }
    }

    return result;
}

fn validateLSBOptions(img: *const Image, options: LSBOptions) !void {
    if (options.bits_per_channel == 0 or options.bits_per_channel > 4) return error.InvalidBitsPerChannel;
    if (img.format != .rgb8 and img.format != .rgba8) return error.UnsupportedFormat;
    if (options.use_alpha and img.format != .rgba8) return error.AlphaChannelUnavailable;
    if (options.encryption) |key| {
        if (key.len == 0) return error.InvalidEncryptionKey;
    }
}

fn calculateCapacity(img: *const Image, options: LSBOptions) !usize {
    const total_bits = try calculateCarrierBits(img, options);
    return if (total_bits >= 32) (total_bits - 32) / 8 else 0;
}

fn calculateCarrierBits(img: *const Image, options: LSBOptions) !usize {
    const channels: usize = if (options.use_alpha) 4 else 3;
    const total_pixels = std.math.mul(usize, img.width, img.height) catch return error.InvalidDimensions;
    const bits_per_pixel = channels * @as(usize, options.bits_per_channel);
    return std.math.mul(usize, total_pixels, bits_per_pixel) catch return error.InvalidDimensions;
}

fn embedChannel(channel: *u8, data: []const u8, bit_index: *usize, bits_per_channel: u3, mask: u8) void {
    const total_bits = data.len * 8;
    var group: u8 = 0;
    var slot: u3 = 0;
    while (slot < bits_per_channel) : (slot += 1) {
        group <<= 1;
        if (bit_index.* < total_bits) {
            const byte = data[bit_index.* / 8];
            const shift: u3 = @intCast(7 - bit_index.* % 8);
            group |= (byte >> shift) & 1;
            bit_index.* += 1;
        }
    }
    channel.* = (channel.* & ~mask) | group;
}

fn extractBitsInto(img: *const Image, options: LSBOptions, skip_bits: usize, output: []u8) !void {
    @memset(output, 0);
    const output_bits = std.math.mul(usize, output.len, 8) catch return error.InvalidLength;
    const required_bits = std.math.add(usize, skip_bits, output_bits) catch return error.InvalidLength;
    if (output_bits == 0) return;

    var stream_bit: usize = 0;
    var output_bit: usize = 0;
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y)) orelse return error.UnsupportedFormat;
            const channels = [_]u8{ pixel.r, pixel.g, pixel.b, pixel.a };
            const channel_count: usize = if (options.use_alpha) 4 else 3;

            for (channels[0..channel_count]) |channel| {
                var slot: u3 = 0;
                while (slot < options.bits_per_channel) : (slot += 1) {
                    if (stream_bit >= required_bits) return;
                    if (stream_bit >= skip_bits) {
                        const channel_shift: u3 = @intCast(options.bits_per_channel - 1 - slot);
                        const output_shift: u3 = @intCast(7 - output_bit % 8);
                        output[output_bit / 8] |= ((channel >> channel_shift) & 1) << output_shift;
                        output_bit += 1;
                    }
                    stream_bit += 1;
                }
            }
        }
    }

    return error.InvalidData;
}

// ============================================================================
// Watermark Detection
// ============================================================================

pub const WatermarkResult = struct {
    detected: bool,
    confidence: f32, // 0.0 to 1.0
    locations: []WatermarkLocation,
    visualization: Image,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WatermarkResult) void {
        self.allocator.free(self.locations);
        self.visualization.deinit();
    }
};

pub const WatermarkLocation = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    strength: f32,
};

pub const WatermarkDetectionOptions = struct {
    block_size: u32 = 32,
    threshold: f32 = 0.1,
    check_frequency_domain: bool = true,
    check_spatial_domain: bool = true,
};

/// Detects invisible watermarks in an image
pub fn detectWatermark(allocator: std.mem.Allocator, img: *const Image, options: WatermarkDetectionOptions) !WatermarkResult {
    if (options.block_size < 2) return error.InvalidBlockSize;
    try validateColorImage(img);

    var locations: std.ArrayList(WatermarkLocation) = .empty;
    defer locations.deinit(allocator);

    var strength_map = try Image.init(allocator, img.width, img.height, .rgba8);
    errdefer strength_map.deinit();

    var max_strength: f32 = 0.0;

    // Analyze blocks for watermark patterns
    var y: u32 = 0;
    while (y <= img.height and options.block_size <= img.height - y) : (y += options.block_size / 2) {
        var x: u32 = 0;
        while (x <= img.width and options.block_size <= img.width - x) : (x += options.block_size / 2) {
            var strength: f32 = 0.0;

            // Spatial domain analysis
            if (options.check_spatial_domain) {
                strength += analyzeSpatialWatermark(img, x, y, options.block_size);
            }

            // Frequency domain analysis
            if (options.check_frequency_domain) {
                strength += analyzeFrequencyWatermark(img, x, y, options.block_size);
            }

            max_strength = @max(max_strength, strength);

            if (strength > options.threshold) {
                try locations.append(allocator, WatermarkLocation{
                    .x = x,
                    .y = y,
                    .width = options.block_size,
                    .height = options.block_size,
                    .strength = strength,
                });
            }

            // Visualize strength
            const intensity = @as(u8, @intFromFloat(@min(255.0, strength * 512.0)));
            for (0..options.block_size) |dy| {
                for (0..options.block_size) |dx| {
                    const px = x + @as(u32, @intCast(dx));
                    const py = y + @as(u32, @intCast(dy));
                    if (px < img.width and py < img.height) {
                        strength_map.setPixel(
                            @intCast(px),
                            @intCast(py),
                            Color{ .r = intensity, .g = intensity, .b = 255, .a = 255 },
                        );
                    }
                }
            }
        }
    }

    const detected = max_strength > options.threshold * 2.0;
    const confidence = @min(1.0, max_strength / 0.5);

    const owned_locations = try locations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_locations);

    return WatermarkResult{
        .detected = detected,
        .confidence = confidence,
        .locations = owned_locations,
        .visualization = strength_map,
        .allocator = allocator,
    };
}

fn analyzeSpatialWatermark(img: *const Image, x: u32, y: u32, block_size: u32) f32 {
    // Detect patterns in LSBs that might indicate watermarks
    var lsb_entropy: f32 = 0.0;
    var bit_counts: [256]u32 = @splat(0);

    for (0..block_size) |dy| {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < img.width and py < img.height) {
                const pixel = img.getPixel(@intCast(px), @intCast(py)) orelse continue;
                // Extract LSB pattern
                const lsb_pattern = ((pixel.r & 1) << 2) | ((pixel.g & 1) << 1) | (pixel.b & 1);
                bit_counts[lsb_pattern] += 1;
            }
        }
    }

    // Calculate entropy of LSB patterns
    const total = block_size * block_size;
    for (bit_counts[0..8]) |count| {
        if (count > 0) {
            const p = @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(total));
            lsb_entropy -= p * @log(p);
        }
    }

    // High entropy in LSBs might indicate embedded data
    // Natural images typically have lower LSB entropy
    const max_entropy = @log(8.0);
    return lsb_entropy / max_entropy;
}

fn analyzeFrequencyWatermark(img: *const Image, x: u32, y: u32, block_size: u32) f32 {
    // Simplified frequency analysis
    // Real implementation would use actual DCT or FFT

    var high_freq_energy: f32 = 0.0;
    var total_energy: f32 = 0.0;

    // Compute horizontal gradients
    for (0..block_size) |dy| {
        for (0..block_size - 1) |dx| {
            const px1 = x + @as(u32, @intCast(dx));
            const px2 = x + @as(u32, @intCast(dx + 1));
            const py = y + @as(u32, @intCast(dy));

            if (px2 < img.width and py < img.height) {
                const p1 = img.getPixel(@intCast(px1), @intCast(py)) orelse continue;
                const p2 = img.getPixel(@intCast(px2), @intCast(py)) orelse continue;

                const diff = @as(f32, @floatFromInt(p1.r)) - @as(f32, @floatFromInt(p2.r));
                const energy = diff * diff;
                total_energy += energy;

                // High frequency = rapid changes
                if (@abs(diff) > 10.0) {
                    high_freq_energy += energy;
                }
            }
        }
    }

    // Compute vertical gradients
    for (0..block_size - 1) |dy| {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py1 = y + @as(u32, @intCast(dy));
            const py2 = y + @as(u32, @intCast(dy + 1));

            if (px < img.width and py2 < img.height) {
                const p1 = img.getPixel(@intCast(px), @intCast(py1)) orelse continue;
                const p2 = img.getPixel(@intCast(px), @intCast(py2)) orelse continue;

                const diff = @as(f32, @floatFromInt(p1.r)) - @as(f32, @floatFromInt(p2.r));
                const energy = diff * diff;
                total_energy += energy;

                if (@abs(diff) > 10.0) {
                    high_freq_energy += energy;
                }
            }
        }
    }

    if (total_energy == 0.0) return 0.0;

    // Watermarks often have distinct frequency signatures
    return high_freq_energy / total_energy;
}

// ============================================================================
// Pattern Embedding/Extraction
// ============================================================================

pub const EmbeddingStrength = enum {
    weak, // Less visible, less robust
    medium,
    strong, // More visible, more robust
};

/// Embeds a repeating pattern into an image for tracking
pub fn embedPattern(
    allocator: std.mem.Allocator,
    img: *const Image,
    pattern: []const u8,
    strength: EmbeddingStrength,
) !Image {
    if (pattern.len == 0) return error.EmptyPattern;
    try validateColorImage(img);
    var result = try Image.init(allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    // Copy original
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            result.setPixel(
                @intCast(x),
                @intCast(y),
                img.getPixel(@intCast(x), @intCast(y)) orelse return error.UnsupportedFormat,
            );
        }
    }

    const amplitude: f32 = switch (strength) {
        .weak => 5.0,
        .medium => 10.0,
        .strong => 20.0,
    };

    // Embed pattern in DCT domain (simplified - real version would use actual DCT)
    for (0..result.height) |y| {
        for (0..result.width) |x| {
            const pattern_idx = (x + y * img.width) % pattern.len;
            const pattern_bit = (pattern[pattern_idx] & 1) != 0;

            var pixel = result.getPixel(@intCast(x), @intCast(y)) orelse return error.UnsupportedFormat;

            if (pattern_bit) {
                pixel.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(pixel.r)) + amplitude));
                pixel.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(pixel.g)) + amplitude));
                pixel.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(pixel.b)) + amplitude));
            }

            result.setPixel(@intCast(x), @intCast(y), pixel);
        }
    }

    return result;
}

/// Extracts an embedded pattern from an image
pub fn extractPattern(allocator: std.mem.Allocator, img: *const Image, pattern_len: usize) ![]u8 {
    if (pattern_len == 0) return error.EmptyPattern;
    try validateColorImage(img);
    const pattern = try allocator.alloc(u8, pattern_len);
    errdefer allocator.free(pattern);
    @memset(pattern, 0);

    // Extract pattern from multiple locations and average
    for (0..pattern_len) |i| {
        var bit_votes: u32 = 0;
        var total_samples: u32 = 0;

        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const idx = (x + y * img.width) % pattern_len;
                if (idx == i) {
                    const pixel = img.getPixel(@intCast(x), @intCast(y)) orelse return error.UnsupportedFormat;
                    const brightness = (@as(u32, pixel.r) + @as(u32, pixel.g) + @as(u32, pixel.b)) / 3;

                    if (brightness > 128) bit_votes += 1;
                    total_samples += 1;
                }
            }
        }

        if (total_samples > 0 and bit_votes * 2 > total_samples) {
            pattern[i] = 1;
        }
    }

    return pattern;
}

fn validateColorImage(img: *const Image) !void {
    switch (img.format) {
        .grayscale8, .rgb8, .rgba8 => {},
        else => return error.UnsupportedFormat,
    }
}

test "LSB steganography round-trips every supported group width" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 16, 16, .rgba8);
    defer img.deinit();
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            img.setPixel(@intCast(x), @intCast(y), .{ .r = 120, .g = 121, .b = 122, .a = 200 });
        }
    }

    for ([_]u3{ 1, 2, 3, 4 }) |bits_per_channel| {
        const options = LSBOptions{ .bits_per_channel = bits_per_channel, .encryption = "key" };
        var encoded = try encodeLSB(allocator, &img, "home", options);
        defer encoded.deinit();
        try std.testing.expectEqual(@as(u8, 200), encoded.getPixel(0, 0).?.a);

        const decoded = try decodeLSB(allocator, &encoded, options);
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings("home", decoded);
    }

    var tiny = try Image.init(allocator, 1, 1, .rgba8);
    defer tiny.deinit();
    try std.testing.expectError(error.InsufficientCapacity, encodeLSB(allocator, &tiny, "x", .{}));
    try std.testing.expectError(error.InsufficientCapacity, encodeLSB(allocator, &tiny, "", .{}));
    try std.testing.expectError(error.InvalidBitsPerChannel, encodeLSB(allocator, &img, "x", .{ .bits_per_channel = 0 }));
    try std.testing.expectError(error.InvalidEncryptionKey, encodeLSB(allocator, &img, "x", .{ .encryption = "" }));
}

test "watermark analysis and pattern validation own their results" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 4, 4, .rgba8);
    defer img.deinit();

    var result = try detectWatermark(allocator, &img, .{ .block_size = 2 });
    defer result.deinit();
    try std.testing.expectEqual(img.width, result.visualization.width);
    try std.testing.expectEqual(img.height, result.visualization.height);
    try std.testing.expectError(error.EmptyPattern, embedPattern(allocator, &img, "", .weak));
    try std.testing.expectError(error.EmptyPattern, extractPattern(allocator, &img, 0));
}
