// Home Video Library - ML-Based Noise Reduction Filter
// Neural network-based video denoising
// Implements a U-Net style architecture for temporal and spatial denoising

const std = @import("std");
const core = @import("../core/frame.zig");
const ml_weights = @import("ml_weights.zig");

pub const VideoFrame = core.VideoFrame;

// ============================================================================
// Neural Network Layers (reuse from ml_upscale.zig)
// ============================================================================

/// 2D Convolution layer
pub const Conv2D = struct {
    weights: []f32,
    bias: []f32,
    in_channels: u32,
    out_channels: u32,
    kernel_size: u32,
    stride: u32 = 1,
    padding: u32 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        in_channels: u32,
        out_channels: u32,
        kernel_size: u32,
    ) !Self {
        const weight_count = out_channels * in_channels * kernel_size * kernel_size;
        const weights = try allocator.alloc(f32, weight_count);
        const bias = try allocator.alloc(f32, out_channels);

        // Use proper He initialization from ml_weights
        const fan_in = in_channels * kernel_size * kernel_size;
        const fan_out = out_channels * kernel_size * kernel_size;
        var prng = std.rand.DefaultPrng.init(42);
        const seed = prng.random().int(u64);

        ml_weights.initWeights(weights, .he_normal, fan_in, fan_out, seed);

        for (bias) |*b| {
            b.* = 0.0;
        }

        return .{
            .weights = weights,
            .bias = bias,
            .in_channels = in_channels,
            .out_channels = out_channels,
            .kernel_size = kernel_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.weights);
        self.allocator.free(self.bias);
    }

    pub fn forward(
        self: *const Self,
        input: []const f32,
        output: []f32,
        height: u32,
        width: u32,
    ) void {
        const out_height = if (self.stride > 1)
            (height + self.stride - 1) / self.stride
        else
            height;
        const out_width = if (self.stride > 1)
            (width + self.stride - 1) / self.stride
        else
            width;

        for (0..self.out_channels) |out_ch| {
            for (0..out_height) |out_y| {
                for (0..out_width) |out_x| {
                    var sum: f32 = self.bias[out_ch];

                    for (0..self.in_channels) |in_ch| {
                        for (0..self.kernel_size) |ky| {
                            for (0..self.kernel_size) |kx| {
                                const in_y = @as(i32, @intCast(out_y * self.stride)) + @as(i32, @intCast(ky)) - @as(i32, @intCast(self.padding));
                                const in_x = @as(i32, @intCast(out_x * self.stride)) + @as(i32, @intCast(kx)) - @as(i32, @intCast(self.padding));

                                if (in_y >= 0 and in_y < height and in_x >= 0 and in_x < width) {
                                    const in_idx = @as(usize, @intCast(in_y)) * width * self.in_channels +
                                        @as(usize, @intCast(in_x)) * self.in_channels + in_ch;
                                    const w_idx = out_ch * self.in_channels * self.kernel_size * self.kernel_size +
                                        in_ch * self.kernel_size * self.kernel_size +
                                        ky * self.kernel_size + kx;

                                    sum += input[in_idx] * self.weights[w_idx];
                                }
                            }
                        }
                    }

                    const out_idx = out_y * out_width * self.out_channels + out_x * self.out_channels + out_ch;
                    output[out_idx] = sum;
                }
            }
        }
    }
};

/// Transposed Convolution (for upsampling)
pub const ConvTranspose2D = struct {
    weights: []f32,
    bias: []f32,
    in_channels: u32,
    out_channels: u32,
    kernel_size: u32,
    stride: u32 = 2,
    padding: u32 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        in_channels: u32,
        out_channels: u32,
        kernel_size: u32,
    ) !Self {
        const weight_count = out_channels * in_channels * kernel_size * kernel_size;
        const weights = try allocator.alloc(f32, weight_count);
        const bias = try allocator.alloc(f32, out_channels);

        // Use proper He initialization from ml_weights
        const fan_in = in_channels * kernel_size * kernel_size;
        const fan_out = out_channels * kernel_size * kernel_size;
        var prng = std.rand.DefaultPrng.init(43);
        const seed = prng.random().int(u64);

        ml_weights.initWeights(weights, .he_normal, fan_in, fan_out, seed);

        for (bias) |*b| {
            b.* = 0.0;
        }

        return .{
            .weights = weights,
            .bias = bias,
            .in_channels = in_channels,
            .out_channels = out_channels,
            .kernel_size = kernel_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.weights);
        self.allocator.free(self.bias);
    }

    pub fn forward(
        self: *const Self,
        input: []const f32,
        output: []f32,
        in_height: u32,
        in_width: u32,
    ) void {
        const out_height = in_height * self.stride;
        const out_width = in_width * self.stride;

        // Initialize output with bias
        for (0..out_height) |out_y| {
            for (0..out_width) |out_x| {
                for (0..self.out_channels) |out_ch| {
                    const out_idx = out_y * out_width * self.out_channels + out_x * self.out_channels + out_ch;
                    output[out_idx] = self.bias[out_ch];
                }
            }
        }

        // Transposed convolution
        for (0..in_height) |in_y| {
            for (0..in_width) |in_x| {
                for (0..self.in_channels) |in_ch| {
                    const in_idx = in_y * in_width * self.in_channels + in_x * self.in_channels + in_ch;
                    const in_val = input[in_idx];

                    for (0..self.kernel_size) |ky| {
                        for (0..self.kernel_size) |kx| {
                            const out_y = in_y * self.stride + ky;
                            const out_x = in_x * self.stride + kx;

                            if (out_y < out_height and out_x < out_width) {
                                for (0..self.out_channels) |out_ch| {
                                    const w_idx = out_ch * self.in_channels * self.kernel_size * self.kernel_size +
                                        in_ch * self.kernel_size * self.kernel_size +
                                        ky * self.kernel_size + kx;

                                    const out_idx = out_y * out_width * self.out_channels + out_x * self.out_channels + out_ch;
                                    output[out_idx] += in_val * self.weights[w_idx];
                                }
                            }
                        }
                    }
                }
            }
        }
    }
};

/// ReLU activation
pub fn relu(data: []f32) void {
    for (data) |*val| {
        val.* = @max(0.0, val.*);
    }
}

/// Batch Normalization (simplified - no learnable parameters)
pub fn batchNorm(data: []f32, channels: u32, height: u32, width: u32) void {
    const pixels_per_channel = height * width;

    for (0..channels) |c| {
        // Calculate mean
        var mean: f32 = 0.0;
        for (0..pixels_per_channel) |i| {
            const idx = i * channels + c;
            mean += data[idx];
        }
        mean /= @floatFromInt(pixels_per_channel);

        // Calculate variance
        var variance: f32 = 0.0;
        for (0..pixels_per_channel) |i| {
            const idx = i * channels + c;
            const diff = data[idx] - mean;
            variance += diff * diff;
        }
        variance /= @floatFromInt(pixels_per_channel);

        // Normalize
        const std_dev = @sqrt(variance + 1e-5);
        for (0..pixels_per_channel) |i| {
            const idx = i * channels + c;
            data[idx] = (data[idx] - mean) / std_dev;
        }
    }
}

// ============================================================================
// U-Net Block
// ============================================================================

pub const UNetBlock = struct {
    conv1: Conv2D,
    conv2: Conv2D,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, in_channels: u32, out_channels: u32) !Self {
        var conv1 = try Conv2D.init(allocator, in_channels, out_channels, 3);
        errdefer conv1.deinit();
        conv1.padding = 1;

        var conv2 = try Conv2D.init(allocator, out_channels, out_channels, 3);
        errdefer conv2.deinit();
        conv2.padding = 1;

        return .{
            .conv1 = conv1,
            .conv2 = conv2,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.conv1.deinit();
        self.conv2.deinit();
    }

    pub fn forward(
        self: *const Self,
        input: []const f32,
        output: []f32,
        height: u32,
        width: u32,
        temp: []f32,
    ) void {
        // Conv1 + ReLU
        self.conv1.forward(input, temp, height, width);
        relu(temp);

        // Conv2 + ReLU
        self.conv2.forward(temp, output, height, width);
        relu(output);
    }
};

// ============================================================================
// U-Net Denoising Network
// ============================================================================

pub const UNetDenoiser = struct {
    // Encoder
    enc1: UNetBlock,
    enc2: UNetBlock,
    enc3: UNetBlock,

    // Downsampling
    pool1: Conv2D,
    pool2: Conv2D,

    // Bottleneck
    bottleneck: UNetBlock,

    // Upsampling
    up1: ConvTranspose2D,
    up2: ConvTranspose2D,

    // Decoder
    dec1: UNetBlock,
    dec2: UNetBlock,

    // Final convolution
    final_conv: Conv2D,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Encoder
        var enc1 = try UNetBlock.init(allocator, 3, 32);
        errdefer enc1.deinit();

        var enc2 = try UNetBlock.init(allocator, 32, 64);
        errdefer enc2.deinit();

        var enc3 = try UNetBlock.init(allocator, 64, 128);
        errdefer enc3.deinit();

        // Pooling (stride 2 convolutions)
        var pool1 = try Conv2D.init(allocator, 32, 32, 2);
        errdefer pool1.deinit();
        pool1.stride = 2;

        var pool2 = try Conv2D.init(allocator, 64, 64, 2);
        errdefer pool2.deinit();
        pool2.stride = 2;

        // Bottleneck
        var bottleneck = try UNetBlock.init(allocator, 128, 256);
        errdefer bottleneck.deinit();

        // Upsampling
        var up1 = try ConvTranspose2D.init(allocator, 256, 128, 2);
        errdefer up1.deinit();

        var up2 = try ConvTranspose2D.init(allocator, 128, 64, 2);
        errdefer up2.deinit();

        // Decoder (with skip connections)
        var dec1 = try UNetBlock.init(allocator, 256, 128); // 128 + 128 from skip
        errdefer dec1.deinit();

        var dec2 = try UNetBlock.init(allocator, 128, 64); // 64 + 64 from skip
        errdefer dec2.deinit();

        // Final convolution
        var final_conv = try Conv2D.init(allocator, 64, 3, 1);
        errdefer final_conv.deinit();

        return .{
            .enc1 = enc1,
            .enc2 = enc2,
            .enc3 = enc3,
            .pool1 = pool1,
            .pool2 = pool2,
            .bottleneck = bottleneck,
            .up1 = up1,
            .up2 = up2,
            .dec1 = dec1,
            .dec2 = dec2,
            .final_conv = final_conv,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.enc1.deinit();
        self.enc2.deinit();
        self.enc3.deinit();
        self.pool1.deinit();
        self.pool2.deinit();
        self.bottleneck.deinit();
        self.up1.deinit();
        self.up2.deinit();
        self.dec1.deinit();
        self.dec2.deinit();
        self.final_conv.deinit();
    }

    /// Calculate total number of parameters in the network
    pub fn getParamCount(self: *const Self) usize {
        var count: usize = 0;
        count += self.enc1.conv1.weights.len + self.enc1.conv1.bias.len;
        count += self.enc1.conv2.weights.len + self.enc1.conv2.bias.len;
        count += self.enc2.conv1.weights.len + self.enc2.conv1.bias.len;
        count += self.enc2.conv2.weights.len + self.enc2.conv2.bias.len;
        count += self.enc3.conv1.weights.len + self.enc3.conv1.bias.len;
        count += self.enc3.conv2.weights.len + self.enc3.conv2.bias.len;
        count += self.pool1.weights.len + self.pool1.bias.len;
        count += self.pool2.weights.len + self.pool2.bias.len;
        count += self.bottleneck.conv1.weights.len + self.bottleneck.conv1.bias.len;
        count += self.bottleneck.conv2.weights.len + self.bottleneck.conv2.bias.len;
        count += self.up1.weights.len + self.up1.bias.len;
        count += self.up2.weights.len + self.up2.bias.len;
        count += self.dec1.conv1.weights.len + self.dec1.conv1.bias.len;
        count += self.dec1.conv2.weights.len + self.dec1.conv2.bias.len;
        count += self.dec2.conv1.weights.len + self.dec2.conv1.bias.len;
        count += self.dec2.conv2.weights.len + self.dec2.conv2.bias.len;
        count += self.final_conv.weights.len + self.final_conv.bias.len;
        return count;
    }

    /// Load pre-trained weights from file
    pub fn loadWeights(self: *Self, file_path: []const u8) !void {
        const param_count = self.getParamCount();
        const weights_data = try ml_weights.loadWeights(
            self.allocator,
            file_path,
            .unet_denoiser,
            param_count,
        );
        defer self.allocator.free(weights_data);

        var offset: usize = 0;

        // Helper macro to copy weights
        const copyLayer = struct {
            fn copy(layer: anytype, data: []const f32, off: *usize) void {
                @memcpy(layer.weights, data[off.* .. off.* + layer.weights.len]);
                off.* += layer.weights.len;
                @memcpy(layer.bias, data[off.* .. off.* + layer.bias.len]);
                off.* += layer.bias.len;
            }
        }.copy;

        copyLayer(&self.enc1.conv1, weights_data, &offset);
        copyLayer(&self.enc1.conv2, weights_data, &offset);
        copyLayer(&self.enc2.conv1, weights_data, &offset);
        copyLayer(&self.enc2.conv2, weights_data, &offset);
        copyLayer(&self.enc3.conv1, weights_data, &offset);
        copyLayer(&self.enc3.conv2, weights_data, &offset);
        copyLayer(&self.pool1, weights_data, &offset);
        copyLayer(&self.pool2, weights_data, &offset);
        copyLayer(&self.bottleneck.conv1, weights_data, &offset);
        copyLayer(&self.bottleneck.conv2, weights_data, &offset);
        copyLayer(&self.up1, weights_data, &offset);
        copyLayer(&self.up2, weights_data, &offset);
        copyLayer(&self.dec1.conv1, weights_data, &offset);
        copyLayer(&self.dec1.conv2, weights_data, &offset);
        copyLayer(&self.dec2.conv1, weights_data, &offset);
        copyLayer(&self.dec2.conv2, weights_data, &offset);
        copyLayer(&self.final_conv, weights_data, &offset);
    }

    /// Save weights to file
    pub fn saveWeights(self: *const Self, file_path: []const u8) !void {
        const param_count = self.getParamCount();
        const weights_data = try self.allocator.alloc(f32, param_count);
        defer self.allocator.free(weights_data);

        var offset: usize = 0;

        const collectLayer = struct {
            fn collect(layer: anytype, data: []f32, off: *usize) void {
                @memcpy(data[off.* .. off.* + layer.weights.len], layer.weights);
                off.* += layer.weights.len;
                @memcpy(data[off.* .. off.* + layer.bias.len], layer.bias);
                off.* += layer.bias.len;
            }
        }.collect;

        collectLayer(&self.enc1.conv1, weights_data, &offset);
        collectLayer(&self.enc1.conv2, weights_data, &offset);
        collectLayer(&self.enc2.conv1, weights_data, &offset);
        collectLayer(&self.enc2.conv2, weights_data, &offset);
        collectLayer(&self.enc3.conv1, weights_data, &offset);
        collectLayer(&self.enc3.conv2, weights_data, &offset);
        collectLayer(&self.pool1, weights_data, &offset);
        collectLayer(&self.pool2, weights_data, &offset);
        collectLayer(&self.bottleneck.conv1, weights_data, &offset);
        collectLayer(&self.bottleneck.conv2, weights_data, &offset);
        collectLayer(&self.up1, weights_data, &offset);
        collectLayer(&self.up2, weights_data, &offset);
        collectLayer(&self.dec1.conv1, weights_data, &offset);
        collectLayer(&self.dec1.conv2, weights_data, &offset);
        collectLayer(&self.dec2.conv1, weights_data, &offset);
        collectLayer(&self.dec2.conv2, weights_data, &offset);
        collectLayer(&self.final_conv, weights_data, &offset);

        try ml_weights.saveWeights(file_path, .unet_denoiser, weights_data);
    }

    /// Initialize with sensible default weights (approximates edge-preserving filters)
    pub fn initDefaultWeights(self: *Self) !void {
        const param_count = self.getParamCount();
        const default_weights = try ml_weights.generateDefaultWeights(
            self.allocator,
            .unet_denoiser,
            param_count,
        );
        defer self.allocator.free(default_weights);

        var offset: usize = 0;

        const copyLayer = struct {
            fn copy(layer: anytype, data: []const f32, off: *usize) void {
                @memcpy(layer.weights, data[off.* .. off.* + layer.weights.len]);
                off.* += layer.weights.len;
                @memcpy(layer.bias, data[off.* .. off.* + layer.bias.len]);
                off.* += layer.bias.len;
            }
        }.copy;

        copyLayer(&self.enc1.conv1, default_weights, &offset);
        copyLayer(&self.enc1.conv2, default_weights, &offset);
        copyLayer(&self.enc2.conv1, default_weights, &offset);
        copyLayer(&self.enc2.conv2, default_weights, &offset);
        copyLayer(&self.enc3.conv1, default_weights, &offset);
        copyLayer(&self.enc3.conv2, default_weights, &offset);
        copyLayer(&self.pool1, default_weights, &offset);
        copyLayer(&self.pool2, default_weights, &offset);
        copyLayer(&self.bottleneck.conv1, default_weights, &offset);
        copyLayer(&self.bottleneck.conv2, default_weights, &offset);
        copyLayer(&self.up1, default_weights, &offset);
        copyLayer(&self.up2, default_weights, &offset);
        copyLayer(&self.dec1.conv1, default_weights, &offset);
        copyLayer(&self.dec1.conv2, default_weights, &offset);
        copyLayer(&self.dec2.conv1, default_weights, &offset);
        copyLayer(&self.dec2.conv2, default_weights, &offset);
        copyLayer(&self.final_conv, default_weights, &offset);
    }

    pub fn forward(
        self: *const Self,
        input: []const f32, // [H, W, 3] normalized to [0, 1]
        output: []f32, // [H, W, 3]
        height: u32,
        width: u32,
    ) !void {
        // Allocate temporary buffers
        const size_full = height * width * 32;
        const size_half = (height / 2) * (width / 2) * 64;
        const size_quarter = (height / 4) * (width / 4) * 128;
        const size_bottleneck = (height / 4) * (width / 4) * 256;

        // Encoder stage 1
        var enc1_out = try self.allocator.alloc(f32, size_full);
        defer self.allocator.free(enc1_out);

        var temp1 = try self.allocator.alloc(f32, size_full);
        defer self.allocator.free(temp1);

        self.enc1.forward(input, enc1_out, height, width, temp1);

        // Pool 1
        var pool1_out = try self.allocator.alloc(f32, size_half);
        defer self.allocator.free(pool1_out);

        self.pool1.forward(enc1_out, pool1_out, height, width);

        // Encoder stage 2
        var enc2_out = try self.allocator.alloc(f32, size_half);
        defer self.allocator.free(enc2_out);

        var temp2 = try self.allocator.alloc(f32, size_half);
        defer self.allocator.free(temp2);

        self.enc2.forward(pool1_out, enc2_out, height / 2, width / 2, temp2);

        // Pool 2
        var pool2_out = try self.allocator.alloc(f32, size_quarter);
        defer self.allocator.free(pool2_out);

        self.pool2.forward(enc2_out, pool2_out, height / 2, width / 2);

        // Encoder stage 3
        var enc3_out = try self.allocator.alloc(f32, size_quarter);
        defer self.allocator.free(enc3_out);

        var temp3 = try self.allocator.alloc(f32, size_quarter);
        defer self.allocator.free(temp3);

        self.enc3.forward(pool2_out, enc3_out, height / 4, width / 4, temp3);

        // Bottleneck
        var bottleneck_out = try self.allocator.alloc(f32, size_bottleneck);
        defer self.allocator.free(bottleneck_out);

        var temp_bn = try self.allocator.alloc(f32, size_bottleneck);
        defer self.allocator.free(temp_bn);

        self.bottleneck.forward(enc3_out, bottleneck_out, height / 4, width / 4, temp_bn);

        // Upsample 1
        var up1_out = try self.allocator.alloc(f32, size_quarter);
        defer self.allocator.free(up1_out);

        self.up1.forward(bottleneck_out, up1_out, height / 4, width / 4);

        // Concatenate with skip connection (enc3_out)
        var concat1 = try self.allocator.alloc(f32, size_quarter * 2);
        defer self.allocator.free(concat1);

        for (0..(height / 4) * (width / 4)) |i| {
            for (0..128) |c| {
                concat1[i * 256 + c] = up1_out[i * 128 + c];
                concat1[i * 256 + 128 + c] = enc3_out[i * 128 + c];
            }
        }

        // Decoder stage 1
        var dec1_out = try self.allocator.alloc(f32, size_quarter);
        defer self.allocator.free(dec1_out);

        var temp_d1 = try self.allocator.alloc(f32, size_quarter);
        defer self.allocator.free(temp_d1);

        self.dec1.forward(concat1, dec1_out, height / 4, width / 4, temp_d1);

        // Upsample 2
        var up2_out = try self.allocator.alloc(f32, size_half);
        defer self.allocator.free(up2_out);

        self.up2.forward(dec1_out, up2_out, height / 4, width / 4);

        // Concatenate with skip connection (enc2_out)
        var concat2 = try self.allocator.alloc(f32, size_half * 2);
        defer self.allocator.free(concat2);

        for (0..(height / 2) * (width / 2)) |i| {
            for (0..64) |c| {
                concat2[i * 128 + c] = up2_out[i * 64 + c];
                concat2[i * 128 + 64 + c] = enc2_out[i * 64 + c];
            }
        }

        // Decoder stage 2
        var dec2_out = try self.allocator.alloc(f32, size_half);
        defer self.allocator.free(dec2_out);

        var temp_d2 = try self.allocator.alloc(f32, size_half);
        defer self.allocator.free(temp_d2);

        self.dec2.forward(concat2, dec2_out, height / 2, width / 2, temp_d2);

        // Final upsampling to original size (simple bilinear)
        var final_upsampled = try self.allocator.alloc(f32, size_full);
        defer self.allocator.free(final_upsampled);

        bilinearUpsample(dec2_out, final_upsampled, height / 2, width / 2, height, width, 64);

        // Final convolution
        self.final_conv.forward(final_upsampled, output, height, width);

        // Clamp output to [0, 1]
        for (output) |*val| {
            val.* = std.math.clamp(val.*, 0.0, 1.0);
        }
    }
};

// Helper: Bilinear upsampling
fn bilinearUpsample(
    input: []const f32,
    output: []f32,
    in_height: u32,
    in_width: u32,
    out_height: u32,
    out_width: u32,
    channels: u32,
) void {
    const y_ratio = @as(f32, @floatFromInt(in_height)) / @as(f32, @floatFromInt(out_height));
    const x_ratio = @as(f32, @floatFromInt(in_width)) / @as(f32, @floatFromInt(out_width));

    for (0..out_height) |y| {
        for (0..out_width) |x| {
            const src_y = @as(f32, @floatFromInt(y)) * y_ratio;
            const src_x = @as(f32, @floatFromInt(x)) * x_ratio;

            const y0 = @as(u32, @intFromFloat(@floor(src_y)));
            const x0 = @as(u32, @intFromFloat(@floor(src_x)));
            const y1 = @min(y0 + 1, in_height - 1);
            const x1 = @min(x0 + 1, in_width - 1);

            const dy = src_y - @as(f32, @floatFromInt(y0));
            const dx = src_x - @as(f32, @floatFromInt(x0));

            for (0..channels) |c| {
                const v00 = input[y0 * in_width * channels + x0 * channels + c];
                const v01 = input[y0 * in_width * channels + x1 * channels + c];
                const v10 = input[y1 * in_width * channels + x0 * channels + c];
                const v11 = input[y1 * in_width * channels + x1 * channels + c];

                const v0 = v00 * (1.0 - dx) + v01 * dx;
                const v1 = v10 * (1.0 - dx) + v11 * dx;
                const val = v0 * (1.0 - dy) + v1 * dy;

                output[y * out_width * channels + x * channels + c] = val;
            }
        }
    }
}

// ============================================================================
// Non-Local Means Denoising (Classical Fallback)
// ============================================================================

pub fn nonLocalMeansDenoise(
    input: []const f32,
    output: []f32,
    height: u32,
    width: u32,
    channels: u32,
    search_window: u32,
    patch_size: u32,
    h: f32, // Filtering parameter
) void {
    const half_patch = patch_size / 2;
    const half_search = search_window / 2;

    for (0..height) |y| {
        for (0..width) |x| {
            for (0..channels) |c| {
                var sum: f32 = 0.0;
                var weight_sum: f32 = 0.0;

                // Search window
                const search_y_start = if (y > half_search) y - half_search else 0;
                const search_y_end = @min(y + half_search + 1, height);
                const search_x_start = if (x > half_search) x - half_search else 0;
                const search_x_end = @min(x + half_search + 1, width);

                for (search_y_start..search_y_end) |sy| {
                    for (search_x_start..search_x_end) |sx| {
                        // Calculate patch distance
                        var distance: f32 = 0.0;
                        var patch_count: u32 = 0;

                        for (0..patch_size) |py| {
                            for (0..patch_size) |px| {
                                const dy = @as(i32, @intCast(py)) - @as(i32, @intCast(half_patch));
                                const dx = @as(i32, @intCast(px)) - @as(i32, @intCast(half_patch));

                                const y1 = @as(i32, @intCast(y)) + dy;
                                const x1 = @as(i32, @intCast(x)) + dx;
                                const y2 = @as(i32, @intCast(sy)) + dy;
                                const x2 = @as(i32, @intCast(sx)) + dx;

                                if (y1 >= 0 and y1 < height and x1 >= 0 and x1 < width and
                                    y2 >= 0 and y2 < height and x2 >= 0 and x2 < width)
                                {
                                    const idx1 = @as(usize, @intCast(y1)) * width * channels +
                                        @as(usize, @intCast(x1)) * channels + c;
                                    const idx2 = @as(usize, @intCast(y2)) * width * channels +
                                        @as(usize, @intCast(x2)) * channels + c;

                                    const diff = input[idx1] - input[idx2];
                                    distance += diff * diff;
                                    patch_count += 1;
                                }
                            }
                        }

                        if (patch_count > 0) {
                            distance /= @floatFromInt(patch_count);
                            const weight = @exp(-distance / (h * h));

                            const idx = sy * width * channels + sx * channels + c;
                            sum += input[idx] * weight;
                            weight_sum += weight;
                        }
                    }
                }

                const out_idx = y * width * channels + x * channels + c;
                output[out_idx] = if (weight_sum > 0.0) sum / weight_sum else input[out_idx];
            }
        }
    }
}

// ============================================================================
// ML Denoising Filter
// ============================================================================

pub const MLDenoiseFilter = struct {
    network: UNetDenoiser,
    use_ml: bool,
    strength: f32, // 0.0 - 1.0
    weights_path: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        use_ml: bool,
        strength: f32,
        weights_path: ?[]const u8,
    ) !Self {
        var network = if (use_ml)
            try UNetDenoiser.init(allocator)
        else
            undefined;

        // Load weights if path provided and file exists, otherwise use sensible defaults
        if (use_ml) {
            if (weights_path) |path| {
                if (ml_weights.weightsFileExists(path, .unet_denoiser)) {
                    network.loadWeights(path) catch |err| {
                        // If loading fails, use default weights
                        try network.initDefaultWeights();
                        return err;
                    };
                } else {
                    // No weights file, use sensible defaults
                    try network.initDefaultWeights();
                }
            } else {
                // No path provided, use sensible defaults
                try network.initDefaultWeights();
            }
        }

        return .{
            .network = network,
            .use_ml = use_ml,
            .strength = std.math.clamp(strength, 0.0, 1.0),
            .weights_path = weights_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.use_ml) {
            self.network.deinit();
        }
    }

    pub fn apply(self: *const Self, input_frame: *const VideoFrame) !*VideoFrame {
        var output_frame = try self.allocator.create(VideoFrame);
        errdefer self.allocator.destroy(output_frame);

        output_frame.* = try VideoFrame.init(
            self.allocator,
            input_frame.width,
            input_frame.height,
            input_frame.format,
        );
        errdefer output_frame.deinit();

        // Convert to RGB float
        const rgb_size = input_frame.width * input_frame.height * 3;
        var input_rgb = try self.allocator.alloc(f32, rgb_size);
        defer self.allocator.free(input_rgb);

        var output_rgb = try self.allocator.alloc(f32, rgb_size);
        defer self.allocator.free(output_rgb);

        // YUV to RGB conversion
        for (0..input_frame.height) |y| {
            for (0..input_frame.width) |x| {
                const idx = y * input_frame.width + x;
                const y_val = @as(f32, @floatFromInt(input_frame.data[0][idx])) / 255.0;
                const u_val = @as(f32, @floatFromInt(input_frame.data[1][idx / 4])) / 255.0 - 0.5;
                const v_val = @as(f32, @floatFromInt(input_frame.data[2][idx / 4])) / 255.0 - 0.5;

                const r = y_val + 1.402 * v_val;
                const g = y_val - 0.344136 * u_val - 0.714136 * v_val;
                const b = y_val + 1.772 * u_val;

                input_rgb[idx * 3] = std.math.clamp(r, 0.0, 1.0);
                input_rgb[idx * 3 + 1] = std.math.clamp(g, 0.0, 1.0);
                input_rgb[idx * 3 + 2] = std.math.clamp(b, 0.0, 1.0);
            }
        }

        // Apply denoising
        if (self.use_ml) {
            try self.network.forward(input_rgb, output_rgb, input_frame.height, input_frame.width);
        } else {
            // Non-Local Means fallback
            const h = 0.1 * self.strength;
            nonLocalMeansDenoise(input_rgb, output_rgb, input_frame.height, input_frame.width, 3, 7, 5, h);
        }

        // Blend with original based on strength
        for (0..rgb_size) |i| {
            output_rgb[i] = input_rgb[i] * (1.0 - self.strength) + output_rgb[i] * self.strength;
        }

        // Convert back to YUV
        for (0..input_frame.height) |y| {
            for (0..input_frame.width) |x| {
                const idx = y * input_frame.width + x;
                const r = output_rgb[idx * 3];
                const g = output_rgb[idx * 3 + 1];
                const b = output_rgb[idx * 3 + 2];

                const y_val = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                const u_val = -0.09991 * r - 0.33609 * g + 0.436 * b + 0.5;
                const v_val = 0.615 * r - 0.55861 * g - 0.05639 * b + 0.5;

                output_frame.data[0][idx] = @intFromFloat(std.math.clamp(y_val, 0.0, 1.0) * 255.0);

                if (x % 2 == 0 and y % 2 == 0) {
                    const uv_idx = (y / 2) * (input_frame.width / 2) + (x / 2);
                    output_frame.data[1][uv_idx] = @intFromFloat(std.math.clamp(u_val, 0.0, 1.0) * 255.0);
                    output_frame.data[2][uv_idx] = @intFromFloat(std.math.clamp(v_val, 0.0, 1.0) * 255.0);
                }
            }
        }

        output_frame.pts = input_frame.pts;
        return output_frame;
    }
};
