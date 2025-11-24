const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

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
    const capacity = calculateCapacity(img, options);
    if (data.len * 8 > capacity) {
        return error.InsufficientCapacity;
    }

    var result = try Image.init(allocator, img.width, img.height, img.format);

    // Copy original image
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            result.setPixel(@intCast(x), @intCast(y), img.getPixel(@intCast(x), @intCast(y)));
        }
    }

    // Prepare data with length header
    var data_with_header = std.ArrayList(u8).init(allocator);
    defer data_with_header.deinit();

    // Add 4-byte length header
    const len = @as(u32, @intCast(data.len));
    try data_with_header.append(@intCast((len >> 24) & 0xFF));
    try data_with_header.append(@intCast((len >> 16) & 0xFF));
    try data_with_header.append(@intCast((len >> 8) & 0xFF));
    try data_with_header.append(@intCast(len & 0xFF));
    try data_with_header.appendSlice(data);

    // Optional simple XOR encryption
    if (options.encryption) |key| {
        for (data_with_header.items[4..], 0..) |*byte, i| {
            byte.* ^= key[i % key.len];
        }
    }

    // Encode data into LSBs
    var bit_index: usize = 0;
    const total_bits = data_with_header.items.len * 8;
    const mask = (@as(u8, 1) << options.bits_per_channel) - 1;

    outer: for (0..result.height) |y| {
        for (0..result.width) |x| {
            if (bit_index >= total_bits) break :outer;

            var pixel = result.getPixel(@intCast(x), @intCast(y));

            // Encode in R channel
            if (bit_index < total_bits) {
                const bits = extractBits(data_with_header.items, bit_index, options.bits_per_channel);
                pixel.r = (pixel.r & ~mask) | bits;
                bit_index += options.bits_per_channel;
            }

            // Encode in G channel
            if (bit_index < total_bits) {
                const bits = extractBits(data_with_header.items, bit_index, options.bits_per_channel);
                pixel.g = (pixel.g & ~mask) | bits;
                bit_index += options.bits_per_channel;
            }

            // Encode in B channel
            if (bit_index < total_bits) {
                const bits = extractBits(data_with_header.items, bit_index, options.bits_per_channel);
                pixel.b = (pixel.b & ~mask) | bits;
                bit_index += options.bits_per_channel;
            }

            // Encode in A channel if enabled
            if (options.use_alpha and bit_index < total_bits) {
                const bits = extractBits(data_with_header.items, bit_index, options.bits_per_channel);
                pixel.a = (pixel.a & ~mask) | bits;
                bit_index += options.bits_per_channel;
            }

            result.setPixel(@intCast(x), @intCast(y), pixel);
        }
    }

    return result;
}

/// Decodes data from an image using LSB steganography
pub fn decodeLSB(allocator: std.mem.Allocator, img: *const Image, options: LSBOptions) ![]u8 {
    // First, extract the length header (4 bytes)
    var header_bits = std.ArrayList(u8).init(allocator);
    defer header_bits.deinit();

    var bit_buffer: u8 = 0;
    var bits_in_buffer: u3 = 0;
    var bytes_extracted: usize = 0;
    const mask = (@as(u8, 1) << options.bits_per_channel) - 1;

    // Extract header (4 bytes = 32 bits)
    outer_header: for (0..img.height) |y| {
        for (0..img.width) |x| {
            if (bytes_extracted >= 4) break :outer_header;

            const pixel = img.getPixel(@intCast(x), @intCast(y));

            // Extract from R
            const r_bits = pixel.r & mask;
            bit_buffer = (bit_buffer << options.bits_per_channel) | r_bits;
            bits_in_buffer += options.bits_per_channel;
            if (bits_in_buffer >= 8) {
                try header_bits.append(bit_buffer);
                bytes_extracted += 1;
                bit_buffer = 0;
                bits_in_buffer = 0;
                if (bytes_extracted >= 4) break :outer_header;
            }

            // Extract from G
            const g_bits = pixel.g & mask;
            bit_buffer = (bit_buffer << options.bits_per_channel) | g_bits;
            bits_in_buffer += options.bits_per_channel;
            if (bits_in_buffer >= 8) {
                try header_bits.append(bit_buffer);
                bytes_extracted += 1;
                bit_buffer = 0;
                bits_in_buffer = 0;
                if (bytes_extracted >= 4) break :outer_header;
            }

            // Extract from B
            const b_bits = pixel.b & mask;
            bit_buffer = (bit_buffer << options.bits_per_channel) | b_bits;
            bits_in_buffer += options.bits_per_channel;
            if (bits_in_buffer >= 8) {
                try header_bits.append(bit_buffer);
                bytes_extracted += 1;
                bit_buffer = 0;
                bits_in_buffer = 0;
                if (bytes_extracted >= 4) break :outer_header;
            }

            // Extract from A if enabled
            if (options.use_alpha) {
                const a_bits = pixel.a & mask;
                bit_buffer = (bit_buffer << options.bits_per_channel) | a_bits;
                bits_in_buffer += options.bits_per_channel;
                if (bits_in_buffer >= 8) {
                    try header_bits.append(bit_buffer);
                    bytes_extracted += 1;
                    bit_buffer = 0;
                    bits_in_buffer = 0;
                    if (bytes_extracted >= 4) break :outer_header;
                }
            }
        }
    }

    if (header_bits.items.len < 4) return error.InvalidData;

    // Parse length from header
    const data_len = (@as(u32, header_bits.items[0]) << 24) |
        (@as(u32, header_bits.items[1]) << 16) |
        (@as(u32, header_bits.items[2]) << 8) |
        @as(u32, header_bits.items[3]);

    if (data_len == 0 or data_len > 100_000_000) return error.InvalidLength;

    // Extract the actual data
    var result = try allocator.alloc(u8, data_len);
    errdefer allocator.free(result);

    bit_buffer = 0;
    bits_in_buffer = 0;
    bytes_extracted = 0;
    var skip_header = true;
    var header_bytes_skipped: usize = 0;

    outer: for (0..img.height) |y| {
        for (0..img.width) |x| {
            if (bytes_extracted >= data_len) break :outer;

            const pixel = img.getPixel(@intCast(x), @intCast(y));

            // Process R channel
            const r_bits = pixel.r & mask;
            bit_buffer = (bit_buffer << options.bits_per_channel) | r_bits;
            bits_in_buffer += options.bits_per_channel;
            if (bits_in_buffer >= 8) {
                if (skip_header) {
                    header_bytes_skipped += 1;
                    if (header_bytes_skipped >= 4) skip_header = false;
                } else {
                    result[bytes_extracted] = bit_buffer;
                    bytes_extracted += 1;
                    if (bytes_extracted >= data_len) break :outer;
                }
                bit_buffer = 0;
                bits_in_buffer = 0;
            }

            // Process G channel
            const g_bits = pixel.g & mask;
            bit_buffer = (bit_buffer << options.bits_per_channel) | g_bits;
            bits_in_buffer += options.bits_per_channel;
            if (bits_in_buffer >= 8) {
                if (skip_header) {
                    header_bytes_skipped += 1;
                    if (header_bytes_skipped >= 4) skip_header = false;
                } else {
                    result[bytes_extracted] = bit_buffer;
                    bytes_extracted += 1;
                    if (bytes_extracted >= data_len) break :outer;
                }
                bit_buffer = 0;
                bits_in_buffer = 0;
            }

            // Process B channel
            const b_bits = pixel.b & mask;
            bit_buffer = (bit_buffer << options.bits_per_channel) | b_bits;
            bits_in_buffer += options.bits_per_channel;
            if (bits_in_buffer >= 8) {
                if (skip_header) {
                    header_bytes_skipped += 1;
                    if (header_bytes_skipped >= 4) skip_header = false;
                } else {
                    result[bytes_extracted] = bit_buffer;
                    bytes_extracted += 1;
                    if (bytes_extracted >= data_len) break :outer;
                }
                bit_buffer = 0;
                bits_in_buffer = 0;
            }

            // Process A channel if enabled
            if (options.use_alpha) {
                const a_bits = pixel.a & mask;
                bit_buffer = (bit_buffer << options.bits_per_channel) | a_bits;
                bits_in_buffer += options.bits_per_channel;
                if (bits_in_buffer >= 8) {
                    if (skip_header) {
                        header_bytes_skipped += 1;
                        if (header_bytes_skipped >= 4) skip_header = false;
                    } else {
                        result[bytes_extracted] = bit_buffer;
                        bytes_extracted += 1;
                        if (bytes_extracted >= data_len) break :outer;
                    }
                    bit_buffer = 0;
                    bits_in_buffer = 0;
                }
            }
        }
    }

    // Decrypt if needed
    if (options.encryption) |key| {
        for (result, 0..) |*byte, i| {
            byte.* ^= key[i % key.len];
        }
    }

    return result;
}

fn calculateCapacity(img: *const Image, options: LSBOptions) usize {
    const channels: usize = if (options.use_alpha) 4 else 3;
    const total_pixels = img.width * img.height;
    const bits_per_pixel = channels * options.bits_per_channel;
    const total_bits = total_pixels * bits_per_pixel;
    return total_bits / 8 - 4; // Subtract header size
}

fn extractBits(data: []const u8, bit_index: usize, num_bits: u3) u8 {
    const byte_index = bit_index / 8;
    const bit_offset = @as(u3, @intCast(bit_index % 8));

    if (byte_index >= data.len) return 0;

    const byte = data[byte_index];
    const shift = @as(u3, @intCast(8 - bit_offset - num_bits));
    const mask = (@as(u8, 1) << num_bits) - 1;

    return (byte >> shift) & mask;
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
    var locations = std.ArrayList(WatermarkLocation).init(allocator);
    defer locations.deinit();

    var strength_map = try Image.init(allocator, img.width, img.height, .rgba);

    var max_strength: f32 = 0.0;
    var total_strength: f32 = 0.0;
    var block_count: u32 = 0;

    // Analyze blocks for watermark patterns
    var y: u32 = 0;
    while (y + options.block_size <= img.height) : (y += options.block_size / 2) {
        var x: u32 = 0;
        while (x + options.block_size <= img.width) : (x += options.block_size / 2) {
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
            total_strength += strength;
            block_count += 1;

            if (strength > options.threshold) {
                try locations.append(WatermarkLocation{
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

    const avg_strength = total_strength / @as(f32, @floatFromInt(block_count));
    const detected = max_strength > options.threshold * 2.0;
    const confidence = @min(1.0, max_strength / 0.5);

    return WatermarkResult{
        .detected = detected,
        .confidence = confidence,
        .locations = try locations.toOwnedSlice(),
        .visualization = strength_map,
        .allocator = allocator,
    };
}

fn analyzeSpatialWatermark(img: *const Image, x: u32, y: u32, block_size: u32) f32 {
    // Detect patterns in LSBs that might indicate watermarks
    var lsb_entropy: f32 = 0.0;
    var bit_counts = [_]u32{0} ** 256;

    for (0..block_size) |dy| {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < img.width and py < img.height) {
                const pixel = img.getPixel(@intCast(px), @intCast(py));
                // Extract LSB pattern
                const lsb_pattern = (pixel.r & 1) << 2 | (pixel.g & 1) << 1 | (pixel.b & 1);
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
                const p1 = img.getPixel(@intCast(px1), @intCast(py));
                const p2 = img.getPixel(@intCast(px2), @intCast(py));

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
                const p1 = img.getPixel(@intCast(px), @intCast(py1));
                const p2 = img.getPixel(@intCast(px), @intCast(py2));

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
    var result = try Image.init(allocator, img.width, img.height, img.format);

    // Copy original
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            result.setPixel(@intCast(x), @intCast(y), img.getPixel(@intCast(x), @intCast(y)));
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

            var pixel = result.getPixel(@intCast(x), @intCast(y));

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
    var pattern = try allocator.alloc(u8, pattern_len);
    @memset(pattern, 0);

    // Extract pattern from multiple locations and average
    for (0..pattern_len) |i| {
        var bit_votes: u32 = 0;
        var total_samples: u32 = 0;

        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const idx = (x + y * img.width) % pattern_len;
                if (idx == i) {
                    const pixel = img.getPixel(@intCast(x), @intCast(y));
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
