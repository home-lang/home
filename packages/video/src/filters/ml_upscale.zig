// Home Video Library - ML-Based Upscaling Filter
// Neural network-based super-resolution upscaling
// Implements a simplified ESRGAN/Real-ESRGAN approach

const std = @import("std");
const core = @import("../core/frame.zig");

pub const VideoFrame = core.VideoFrame;

// ============================================================================
// Neural Network Primitives
// ============================================================================

/// 2D Convolution layer
pub const Conv2D = struct {
    weights: []f32, // [out_channels][in_channels][kernel_h][kernel_w]
    bias: []f32, // [out_channels]
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

        // He initialization
        const std_dev = @sqrt(2.0 / @as(f32, @floatFromInt(in_channels * kernel_size * kernel_size)));
        var prng = std.rand.DefaultPrng.init(42);
        const random = prng.random();

        for (weights) |*w| {
            w.* = random.floatNorm(f32) * std_dev;
        }

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
        const out_height = height; // Assuming padding maintains size
        const out_width = width;

        for (0..self.out_channels) |out_ch| {
            for (0..out_height) |out_y| {
                for (0..out_width) |out_x| {
                    var sum: f32 = self.bias[out_ch];

                    for (0..self.in_channels) |in_ch| {
                        for (0..self.kernel_size) |ky| {
                            for (0..self.kernel_size) |kx| {
                                const in_y = @as(i32, @intCast(out_y)) + @as(i32, @intCast(ky)) - @as(i32, @intCast(self.padding));
                                const in_x = @as(i32, @intCast(out_x)) + @as(i32, @intCast(kx)) - @as(i32, @intCast(self.padding));

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

/// ReLU activation
pub fn relu(data: []f32) void {
    for (data) |*val| {
        val.* = @max(0.0, val.*);
    }
}

/// Leaky ReLU activation
pub fn leakyRelu(data: []f32, negative_slope: f32) void {
    for (data) |*val| {
        if (val.* < 0.0) {
            val.* *= negative_slope;
        }
    }
}

/// Pixel shuffle (upscaling by rearranging pixels)
/// Converts (H, W, C*r^2) -> (H*r, W*r, C)
pub fn pixelShuffle(
    input: []const f32,
    output: []f32,
    height: u32,
    width: u32,
    channels: u32,
    upscale_factor: u32,
) void {
    const r = upscale_factor;
    const in_channels = channels * r * r;

    for (0..height) |h| {
        for (0..width) |w| {
            for (0..channels) |c| {
                for (0..r) |dy| {
                    for (0..r) |dx| {
                        const in_c = c * r * r + dy * r + dx;
                        const in_idx = h * width * in_channels + w * in_channels + in_c;

                        const out_h = h * r + dy;
                        const out_w = w * r + dx;
                        const out_idx = out_h * (width * r) * channels + out_w * channels + c;

                        output[out_idx] = input[in_idx];
                    }
                }
            }
        }
    }
}

// ============================================================================
// Residual Block
// ============================================================================

pub const ResidualBlock = struct {
    conv1: Conv2D,
    conv2: Conv2D,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, channels: u32) !Self {
        var conv1 = try Conv2D.init(allocator, channels, channels, 3);
        errdefer conv1.deinit();
        conv1.padding = 1;

        var conv2 = try Conv2D.init(allocator, channels, channels, 3);
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
        temp_buffer: []f32,
    ) !void {
        // Conv1 + LeakyReLU
        self.conv1.forward(input, temp_buffer, height, width);
        leakyRelu(temp_buffer, 0.2);

        // Conv2
        self.conv2.forward(temp_buffer, output, height, width);

        // Residual connection
        for (0..input.len) |i| {
            output[i] += input[i];
        }
    }
};

// ============================================================================
// Upscaling Network (ESRGAN-style)
// ============================================================================

pub const ESRGANUpscaler = struct {
    // Feature extraction
    conv_first: Conv2D,

    // Residual blocks
    residual_blocks: []ResidualBlock,
    num_blocks: u32,

    // Upsampling
    upconv1: Conv2D,
    upconv2: Conv2D,

    // Final convolution
    conv_last: Conv2D,

    // Network parameters
    num_features: u32,
    upscale_factor: u32,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, upscale_factor: u32, num_blocks: u32) !Self {
        const num_features: u32 = 64;

        // First convolution (3 -> 64 channels)
        var conv_first = try Conv2D.init(allocator, 3, num_features, 3);
        errdefer conv_first.deinit();
        conv_first.padding = 1;

        // Residual blocks
        const residual_blocks = try allocator.alloc(ResidualBlock, num_blocks);
        errdefer allocator.free(residual_blocks);

        var initialized: usize = 0;
        errdefer {
            for (residual_blocks[0..initialized]) |*block| {
                block.deinit();
            }
        }

        for (residual_blocks) |*block| {
            block.* = try ResidualBlock.init(allocator, num_features);
            initialized += 1;
        }

        // Upsampling convolutions (pixel shuffle)
        var upconv1 = try Conv2D.init(allocator, num_features, num_features * 4, 3);
        errdefer upconv1.deinit();
        upconv1.padding = 1;

        var upconv2 = try Conv2D.init(allocator, num_features, num_features * 4, 3);
        errdefer upconv2.deinit();
        upconv2.padding = 1;

        // Final convolution (64 -> 3 channels)
        var conv_last = try Conv2D.init(allocator, num_features, 3, 3);
        errdefer conv_last.deinit();
        conv_last.padding = 1;

        return .{
            .conv_first = conv_first,
            .residual_blocks = residual_blocks,
            .num_blocks = num_blocks,
            .upconv1 = upconv1,
            .upconv2 = upconv2,
            .conv_last = conv_last,
            .num_features = num_features,
            .upscale_factor = upscale_factor,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.conv_first.deinit();
        for (self.residual_blocks) |*block| {
            block.deinit();
        }
        self.allocator.free(self.residual_blocks);
        self.upconv1.deinit();
        self.upconv2.deinit();
        self.conv_last.deinit();
    }

    pub fn forward(
        self: *const Self,
        input: []const f32, // [H, W, 3] normalized to [0, 1]
        output: []f32, // [H*scale, W*scale, 3]
        height: u32,
        width: u32,
    ) !void {
        const out_height = height * self.upscale_factor;
        const out_width = width * self.upscale_factor;

        // Allocate temporary buffers
        const feat_size = height * width * self.num_features;
        const upsampled_size = (height * 2) * (width * 2) * self.num_features;

        var feat1 = try self.allocator.alloc(f32, feat_size);
        defer self.allocator.free(feat1);

        var feat2 = try self.allocator.alloc(f32, feat_size);
        defer self.allocator.free(feat2);

        var temp = try self.allocator.alloc(f32, feat_size);
        defer self.allocator.free(temp);

        // First convolution
        self.conv_first.forward(input, feat1, height, width);

        // Residual blocks (feature refinement)
        for (self.residual_blocks, 0..) |*block, i| {
            const in_feat = if (i % 2 == 0) feat1 else feat2;
            const out_feat = if (i % 2 == 0) feat2 else feat1;
            try block.forward(in_feat, out_feat, height, width, temp);
        }

        const final_feat = if (self.num_blocks % 2 == 0) feat1 else feat2;

        // Upsampling (2x)
        var up1 = try self.allocator.alloc(f32, height * width * self.num_features * 4);
        defer self.allocator.free(up1);

        self.upconv1.forward(final_feat, up1, height, width);
        leakyRelu(up1, 0.2);

        var up1_shuffled = try self.allocator.alloc(f32, (height * 2) * (width * 2) * self.num_features);
        defer self.allocator.free(up1_shuffled);

        pixelShuffle(up1, up1_shuffled, height, width, self.num_features, 2);

        // Upsampling (2x) - only if 4x upscale
        if (self.upscale_factor == 4) {
            var up2 = try self.allocator.alloc(f32, (height * 2) * (width * 2) * self.num_features * 4);
            defer self.allocator.free(up2);

            self.upconv2.forward(up1_shuffled, up2, height * 2, width * 2);
            leakyRelu(up2, 0.2);

            var up2_shuffled = try self.allocator.alloc(f32, upsampled_size * 4);
            defer self.allocator.free(up2_shuffled);

            pixelShuffle(up2, up2_shuffled, height * 2, width * 2, self.num_features, 2);

            // Final convolution
            self.conv_last.forward(up2_shuffled, output, out_height, out_width);
        } else {
            // Final convolution (2x only)
            self.conv_last.forward(up1_shuffled, output, out_height, out_width);
        }

        // Clamp output to [0, 1]
        for (output) |*val| {
            val.* = std.math.clamp(val.*, 0.0, 1.0);
        }
    }
};

// ============================================================================
// Simple Bicubic Upscaling (Fallback)
// ============================================================================

pub fn bicubicWeight(x: f32) f32 {
    const abs_x = @abs(x);
    if (abs_x <= 1.0) {
        return 1.5 * abs_x * abs_x * abs_x - 2.5 * abs_x * abs_x + 1.0;
    } else if (abs_x < 2.0) {
        return -0.5 * abs_x * abs_x * abs_x + 2.5 * abs_x * abs_x - 4.0 * abs_x + 2.0;
    }
    return 0.0;
}

pub fn bicubicUpscale(
    input: []const f32,
    output: []f32,
    src_height: u32,
    src_width: u32,
    dst_height: u32,
    dst_width: u32,
    channels: u32,
) void {
    const x_ratio = @as(f32, @floatFromInt(src_width)) / @as(f32, @floatFromInt(dst_width));
    const y_ratio = @as(f32, @floatFromInt(src_height)) / @as(f32, @floatFromInt(dst_height));

    for (0..dst_height) |dst_y| {
        for (0..dst_width) |dst_x| {
            const src_x = @as(f32, @floatFromInt(dst_x)) * x_ratio;
            const src_y = @as(f32, @floatFromInt(dst_y)) * y_ratio;

            const x0 = @as(i32, @intFromFloat(@floor(src_x)));
            const y0 = @as(i32, @intFromFloat(@floor(src_y)));

            for (0..channels) |c| {
                var sum: f32 = 0.0;
                var weight_sum: f32 = 0.0;

                // 4x4 bicubic kernel
                var dy: i32 = -1;
                while (dy <= 2) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 2) : (dx += 1) {
                        const sx = x0 + dx;
                        const sy = y0 + dy;

                        if (sx >= 0 and sx < src_width and sy >= 0 and sy < src_height) {
                            const weight_x = bicubicWeight(src_x - @as(f32, @floatFromInt(sx)));
                            const weight_y = bicubicWeight(src_y - @as(f32, @floatFromInt(sy)));
                            const weight = weight_x * weight_y;

                            const src_idx = @as(usize, @intCast(sy)) * src_width * channels +
                                @as(usize, @intCast(sx)) * channels + c;
                            sum += input[src_idx] * weight;
                            weight_sum += weight;
                        }
                    }
                }

                const dst_idx = dst_y * dst_width * channels + dst_x * channels + c;
                output[dst_idx] = if (weight_sum > 0.0) sum / weight_sum else 0.0;
            }
        }
    }
}

// ============================================================================
// ML Upscaler Filter
// ============================================================================

pub const MLUpscaleFilter = struct {
    network: ESRGANUpscaler,
    upscale_factor: u32,
    use_ml: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, upscale_factor: u32, use_ml: bool) !Self {
        if (upscale_factor != 2 and upscale_factor != 4) {
            return error.InvalidUpscaleFactor;
        }

        const network = if (use_ml)
            try ESRGANUpscaler.init(allocator, upscale_factor, 8) // 8 residual blocks
        else
            undefined;

        return .{
            .network = network,
            .upscale_factor = upscale_factor,
            .use_ml = use_ml,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.use_ml) {
            self.network.deinit();
        }
    }

    pub fn apply(self: *const Self, input_frame: *const VideoFrame) !*VideoFrame {
        const out_width = input_frame.width * self.upscale_factor;
        const out_height = input_frame.height * self.upscale_factor;

        var output_frame = try self.allocator.create(VideoFrame);
        errdefer self.allocator.destroy(output_frame);

        output_frame.* = try VideoFrame.init(
            self.allocator,
            out_width,
            out_height,
            input_frame.format,
        );
        errdefer output_frame.deinit();

        if (self.use_ml) {
            // Convert to RGB float [0, 1]
            const input_size = input_frame.width * input_frame.height * 3;
            const output_size = out_width * out_height * 3;

            var input_rgb = try self.allocator.alloc(f32, input_size);
            defer self.allocator.free(input_rgb);

            var output_rgb = try self.allocator.alloc(f32, output_size);
            defer self.allocator.free(output_rgb);

            // Convert YUV to RGB and normalize
            for (0..input_frame.height) |y| {
                for (0..input_frame.width) |x| {
                    const idx = y * input_frame.width + x;
                    const y_val = @as(f32, @floatFromInt(input_frame.data[0][idx])) / 255.0;
                    const u_val = @as(f32, @floatFromInt(input_frame.data[1][idx / 4])) / 255.0 - 0.5;
                    const v_val = @as(f32, @floatFromInt(input_frame.data[2][idx / 4])) / 255.0 - 0.5;

                    // BT.709
                    const r = y_val + 1.402 * v_val;
                    const g = y_val - 0.344136 * u_val - 0.714136 * v_val;
                    const b = y_val + 1.772 * u_val;

                    input_rgb[idx * 3] = std.math.clamp(r, 0.0, 1.0);
                    input_rgb[idx * 3 + 1] = std.math.clamp(g, 0.0, 1.0);
                    input_rgb[idx * 3 + 2] = std.math.clamp(b, 0.0, 1.0);
                }
            }

            // Run neural network
            try self.network.forward(input_rgb, output_rgb, input_frame.height, input_frame.width);

            // Convert back to YUV
            for (0..out_height) |y| {
                for (0..out_width) |x| {
                    const idx = y * out_width + x;
                    const r = output_rgb[idx * 3];
                    const g = output_rgb[idx * 3 + 1];
                    const b = output_rgb[idx * 3 + 2];

                    const y_val = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    const u_val = -0.09991 * r - 0.33609 * g + 0.436 * b + 0.5;
                    const v_val = 0.615 * r - 0.55861 * g - 0.05639 * b + 0.5;

                    output_frame.data[0][idx] = @intFromFloat(std.math.clamp(y_val, 0.0, 1.0) * 255.0);

                    if (x % 2 == 0 and y % 2 == 0) {
                        const uv_idx = (y / 2) * (out_width / 2) + (x / 2);
                        output_frame.data[1][uv_idx] = @intFromFloat(std.math.clamp(u_val, 0.0, 1.0) * 255.0);
                        output_frame.data[2][uv_idx] = @intFromFloat(std.math.clamp(v_val, 0.0, 1.0) * 255.0);
                    }
                }
            }
        } else {
            // Bicubic fallback
            const input_size = input_frame.width * input_frame.height * 3;
            const output_size = out_width * out_height * 3;

            var input_rgb = try self.allocator.alloc(f32, input_size);
            defer self.allocator.free(input_rgb);

            var output_rgb = try self.allocator.alloc(f32, output_size);
            defer self.allocator.free(output_rgb);

            // Convert to RGB first (same as above)
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

            bicubicUpscale(
                input_rgb,
                output_rgb,
                input_frame.height,
                input_frame.width,
                out_height,
                out_width,
                3,
            );

            // Convert back to YUV (same as above)
            for (0..out_height) |y| {
                for (0..out_width) |x| {
                    const idx = y * out_width + x;
                    const r = output_rgb[idx * 3];
                    const g = output_rgb[idx * 3 + 1];
                    const b = output_rgb[idx * 3 + 2];

                    const y_val = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    const u_val = -0.09991 * r - 0.33609 * g + 0.436 * b + 0.5;
                    const v_val = 0.615 * r - 0.55861 * g - 0.05639 * b + 0.5;

                    output_frame.data[0][idx] = @intFromFloat(std.math.clamp(y_val, 0.0, 1.0) * 255.0);

                    if (x % 2 == 0 and y % 2 == 0) {
                        const uv_idx = (y / 2) * (out_width / 2) + (x / 2);
                        output_frame.data[1][uv_idx] = @intFromFloat(std.math.clamp(u_val, 0.0, 1.0) * 255.0);
                        output_frame.data[2][uv_idx] = @intFromFloat(std.math.clamp(v_val, 0.0, 1.0) * 255.0);
                    }
                }
            }
        }

        output_frame.pts = input_frame.pts;
        return output_frame;
    }
};
