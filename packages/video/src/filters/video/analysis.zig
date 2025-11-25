// Home Video Library - Video Analysis Filters
// Histogram generation, quality metrics (PSNR, SSIM), frame comparison

const std = @import("std");
const core = @import("../../core.zig");
const VideoFrame = core.VideoFrame;

/// Histogram data for a single channel
pub const Histogram = struct {
    bins: [256]u32,
    total_pixels: u64,

    const Self = @This();

    pub fn init() Self {
        return .{
            .bins = [_]u32{0} ** 256,
            .total_pixels = 0,
        };
    }

    pub fn add(self: *Self, value: u8) void {
        self.bins[value] += 1;
        self.total_pixels += 1;
    }

    pub fn getProbability(self: *const Self, value: u8) f64 {
        if (self.total_pixels == 0) return 0.0;
        return @as(f64, @floatFromInt(self.bins[value])) / @as(f64, @floatFromInt(self.total_pixels));
    }

    pub fn getCumulativeProbability(self: *const Self, value: u8) f64 {
        if (self.total_pixels == 0) return 0.0;

        var sum: u64 = 0;
        for (0..@as(usize, value) + 1) |i| {
            sum += self.bins[i];
        }

        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.total_pixels));
    }

    pub fn getMean(self: *const Self) f64 {
        if (self.total_pixels == 0) return 0.0;

        var sum: u64 = 0;
        for (0..256) |i| {
            sum += i * self.bins[i];
        }

        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.total_pixels));
    }

    pub fn getVariance(self: *const Self) f64 {
        if (self.total_pixels == 0) return 0.0;

        const mean = self.getMean();
        var sum_sq_diff: f64 = 0.0;

        for (0..256) |i| {
            const diff = @as(f64, @floatFromInt(i)) - mean;
            sum_sq_diff += diff * diff * @as(f64, @floatFromInt(self.bins[i]));
        }

        return sum_sq_diff / @as(f64, @floatFromInt(self.total_pixels));
    }

    pub fn getStdDev(self: *const Self) f64 {
        return std.math.sqrt(self.getVariance());
    }

    pub fn getMin(self: *const Self) u8 {
        for (0..256) |i| {
            if (self.bins[i] > 0) return @intCast(i);
        }
        return 0;
    }

    pub fn getMax(self: *const Self) u8 {
        var i: usize = 255;
        while (i > 0) : (i -= 1) {
            if (self.bins[i] > 0) return @intCast(i);
        }
        return 0;
    }

    pub fn getMedian(self: *const Self) u8 {
        if (self.total_pixels == 0) return 0;

        const half = self.total_pixels / 2;
        var sum: u64 = 0;

        for (0..256) |i| {
            sum += self.bins[i];
            if (sum >= half) return @intCast(i);
        }

        return 255;
    }
};

/// Multi-channel histogram
pub const ColorHistogram = struct {
    channel_0: Histogram, // Y/R/Gray
    channel_1: Histogram, // U/G
    channel_2: Histogram, // V/B
    format: core.PixelFormat,

    const Self = @This();

    pub fn init(format: core.PixelFormat) Self {
        return .{
            .channel_0 = Histogram.init(),
            .channel_1 = Histogram.init(),
            .channel_2 = Histogram.init(),
            .format = format,
        };
    }
};

/// Histogram generator filter
pub const HistogramFilter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn generate(self: *Self, frame: *const VideoFrame) !ColorHistogram {
        _ = self;

        var histogram = ColorHistogram.init(frame.format);
        const pixel_count = frame.width * frame.height;

        // Analyze luma/first channel
        for (0..pixel_count) |i| {
            histogram.channel_0.add(frame.data[0][i]);
        }

        // Analyze chroma/other channels if present
        if (frame.format == .yuv420p or frame.format == .yuv422p or frame.format == .yuv444p) {
            const chroma_size = switch (frame.format) {
                .yuv420p => (frame.width / 2) * (frame.height / 2),
                .yuv422p => (frame.width / 2) * frame.height,
                .yuv444p => frame.width * frame.height,
                else => 0,
            };

            for (0..chroma_size) |i| {
                histogram.channel_1.add(frame.data[1][i]);
                histogram.channel_2.add(frame.data[2][i]);
            }
        } else if (frame.format == .rgb24 or frame.format == .bgr24) {
            for (0..pixel_count) |i| {
                histogram.channel_1.add(frame.data[0][i * 3 + 1]);
                histogram.channel_2.add(frame.data[0][i * 3 + 2]);
            }
        } else if (frame.format == .rgba or frame.format == .bgra) {
            for (0..pixel_count) |i| {
                histogram.channel_1.add(frame.data[0][i * 4 + 1]);
                histogram.channel_2.add(frame.data[0][i * 4 + 2]);
            }
        }

        return histogram;
    }

    pub fn visualize(self: *Self, histogram: *const ColorHistogram, width: u32, height: u32) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, width, height, .rgb24);

        // Clear to black
        @memset(output.data[0], 0);

        // Find max bin value for scaling
        var max_bin: u32 = 0;
        for (histogram.channel_0.bins) |bin| {
            max_bin = @max(max_bin, bin);
        }

        if (max_bin == 0) return output;

        // Draw histogram bars
        const bar_width = width / 256;
        for (0..256) |i| {
            const bin_height = @as(u32, @intFromFloat(@as(f32, @floatFromInt(histogram.channel_0.bins[i])) / @as(f32, @floatFromInt(max_bin)) * @as(f32, @floatFromInt(height))));

            const x_start = @as(u32, @intCast(i)) * bar_width;
            const x_end = @min(x_start + bar_width, width);

            var y: u32 = 0;
            while (y < bin_height and y < height) : (y += 1) {
                var x = x_start;
                while (x < x_end) : (x += 1) {
                    const pixel_idx = ((height - 1 - y) * width + x) * 3;
                    output.data[0][pixel_idx + 0] = 255; // R
                    output.data[0][pixel_idx + 1] = 255; // G
                    output.data[0][pixel_idx + 2] = 255; // B
                }
            }
        }

        return output;
    }
};

/// PSNR (Peak Signal-to-Noise Ratio) calculation
pub const PSNRCalculator = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Calculate PSNR between two frames
    pub fn calculate(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !f64 {
        _ = self;

        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        const pixel_count = frame1.width * frame1.height;

        // Calculate MSE (Mean Squared Error)
        var mse: f64 = 0.0;

        // Compare luma/first plane
        for (0..pixel_count) |i| {
            const diff = @as(f64, @floatFromInt(frame1.data[0][i])) - @as(f64, @floatFromInt(frame2.data[0][i]));
            mse += diff * diff;
        }

        mse /= @as(f64, @floatFromInt(pixel_count));

        // Handle perfect match
        if (mse < 0.0001) {
            return std.math.inf(f64);
        }

        // PSNR = 10 * log10(MAX^2 / MSE)
        const max_pixel_value: f64 = 255.0;
        const psnr = 10.0 * std.math.log10((max_pixel_value * max_pixel_value) / mse);

        return psnr;
    }

    /// Calculate PSNR for each channel separately
    pub fn calculateChannels(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !struct { y: f64, u: f64, v: f64 } {
        _ = self;

        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        const pixel_count = frame1.width * frame1.height;

        // Calculate Y channel PSNR
        var mse_y: f64 = 0.0;
        for (0..pixel_count) |i| {
            const diff = @as(f64, @floatFromInt(frame1.data[0][i])) - @as(f64, @floatFromInt(frame2.data[0][i]));
            mse_y += diff * diff;
        }
        mse_y /= @as(f64, @floatFromInt(pixel_count));

        const psnr_y = if (mse_y < 0.0001) std.math.inf(f64) else 10.0 * std.math.log10((255.0 * 255.0) / mse_y);

        // Calculate U/V channel PSNR for YUV formats
        var psnr_u: f64 = std.math.inf(f64);
        var psnr_v: f64 = std.math.inf(f64);

        if (frame1.format == .yuv420p or frame1.format == .yuv422p or frame1.format == .yuv444p) {
            const chroma_size = switch (frame1.format) {
                .yuv420p => (frame1.width / 2) * (frame1.height / 2),
                .yuv422p => (frame1.width / 2) * frame1.height,
                .yuv444p => frame1.width * frame1.height,
                else => 0,
            };

            var mse_u: f64 = 0.0;
            var mse_v: f64 = 0.0;

            for (0..chroma_size) |i| {
                const diff_u = @as(f64, @floatFromInt(frame1.data[1][i])) - @as(f64, @floatFromInt(frame2.data[1][i]));
                const diff_v = @as(f64, @floatFromInt(frame1.data[2][i])) - @as(f64, @floatFromInt(frame2.data[2][i]));
                mse_u += diff_u * diff_u;
                mse_v += diff_v * diff_v;
            }

            mse_u /= @as(f64, @floatFromInt(chroma_size));
            mse_v /= @as(f64, @floatFromInt(chroma_size));

            psnr_u = if (mse_u < 0.0001) std.math.inf(f64) else 10.0 * std.math.log10((255.0 * 255.0) / mse_u);
            psnr_v = if (mse_v < 0.0001) std.math.inf(f64) else 10.0 * std.math.log10((255.0 * 255.0) / mse_v);
        }

        return .{ .y = psnr_y, .u = psnr_u, .v = psnr_v };
    }
};

/// SSIM (Structural Similarity Index) calculation
pub const SSIMCalculator = struct {
    window_size: u32 = 11,
    k1: f64 = 0.01,
    k2: f64 = 0.03,

    const Self = @This();

    pub fn init(window_size: u32) Self {
        return .{ .window_size = window_size };
    }

    /// Calculate SSIM between two frames
    pub fn calculate(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !f64 {
        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        // Use a sliding window approach
        var ssim_sum: f64 = 0.0;
        var window_count: u64 = 0;

        const half_window = self.window_size / 2;

        var y: u32 = half_window;
        while (y < frame1.height - half_window) : (y += self.window_size) {
            var x: u32 = half_window;
            while (x < frame1.width - half_window) : (x += self.window_size) {
                const ssim_window = try self.calculateWindow(frame1, frame2, x, y);
                ssim_sum += ssim_window;
                window_count += 1;
            }
        }

        if (window_count == 0) return 1.0;

        return ssim_sum / @as(f64, @floatFromInt(window_count));
    }

    fn calculateWindow(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame, center_x: u32, center_y: u32) !f64 {
        const half = self.window_size / 2;

        const start_x = center_x - half;
        const end_x = center_x + half;
        const start_y = center_y - half;
        const end_y = center_y + half;

        // Calculate means
        var sum1: f64 = 0.0;
        var sum2: f64 = 0.0;
        var count: u64 = 0;

        var y = start_y;
        while (y <= end_y) : (y += 1) {
            var x = start_x;
            while (x <= end_x) : (x += 1) {
                const idx = y * frame1.width + x;
                sum1 += @as(f64, @floatFromInt(frame1.data[0][idx]));
                sum2 += @as(f64, @floatFromInt(frame2.data[0][idx]));
                count += 1;
            }
        }

        const mean1 = sum1 / @as(f64, @floatFromInt(count));
        const mean2 = sum2 / @as(f64, @floatFromInt(count));

        // Calculate variances and covariance
        var var1: f64 = 0.0;
        var var2: f64 = 0.0;
        var covar: f64 = 0.0;

        y = start_y;
        while (y <= end_y) : (y += 1) {
            var x = start_x;
            while (x <= end_x) : (x += 1) {
                const idx = y * frame1.width + x;
                const val1 = @as(f64, @floatFromInt(frame1.data[0][idx]));
                const val2 = @as(f64, @floatFromInt(frame2.data[0][idx]));

                const diff1 = val1 - mean1;
                const diff2 = val2 - mean2;

                var1 += diff1 * diff1;
                var2 += diff2 * diff2;
                covar += diff1 * diff2;
            }
        }

        var1 /= @as(f64, @floatFromInt(count));
        var2 /= @as(f64, @floatFromInt(count));
        covar /= @as(f64, @floatFromInt(count));

        // SSIM formula
        const L: f64 = 255.0; // Dynamic range
        const c1 = (self.k1 * L) * (self.k1 * L);
        const c2 = (self.k2 * L) * (self.k2 * L);

        const numerator = (2.0 * mean1 * mean2 + c1) * (2.0 * covar + c2);
        const denominator = (mean1 * mean1 + mean2 * mean2 + c1) * (var1 + var2 + c2);

        return numerator / denominator;
    }
};

/// Frame difference calculator
pub const FrameDifferenceCalculator = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Calculate Mean Absolute Difference (MAD)
    pub fn calculateMAD(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !f64 {
        _ = self;

        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        const pixel_count = frame1.width * frame1.height;
        var sum: f64 = 0.0;

        for (0..pixel_count) |i| {
            const diff = @abs(@as(i32, frame1.data[0][i]) - @as(i32, frame2.data[0][i]));
            sum += @as(f64, @floatFromInt(diff));
        }

        return sum / @as(f64, @floatFromInt(pixel_count));
    }

    /// Calculate Mean Squared Error (MSE)
    pub fn calculateMSE(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !f64 {
        _ = self;

        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        const pixel_count = frame1.width * frame1.height;
        var sum: f64 = 0.0;

        for (0..pixel_count) |i| {
            const diff = @as(f64, @floatFromInt(frame1.data[0][i])) - @as(f64, @floatFromInt(frame2.data[0][i]));
            sum += diff * diff;
        }

        return sum / @as(f64, @floatFromInt(pixel_count));
    }

    /// Calculate Root Mean Squared Error (RMSE)
    pub fn calculateRMSE(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !f64 {
        const mse = try self.calculateMSE(frame1, frame2);
        return std.math.sqrt(mse);
    }

    /// Calculate percentage of different pixels
    pub fn calculateDifferencePercentage(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame, threshold: u8) !f64 {
        _ = self;

        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        const pixel_count = frame1.width * frame1.height;
        var diff_count: u64 = 0;

        for (0..pixel_count) |i| {
            const diff = @abs(@as(i32, frame1.data[0][i]) - @as(i32, frame2.data[0][i]));
            if (diff > threshold) {
                diff_count += 1;
            }
        }

        return @as(f64, @floatFromInt(diff_count)) / @as(f64, @floatFromInt(pixel_count)) * 100.0;
    }
};

/// Video quality metrics aggregator
pub const QualityMetrics = struct {
    psnr: f64,
    ssim: f64,
    mad: f64,
    mse: f64,

    const Self = @This();

    pub fn calculate(frame1: *const VideoFrame, frame2: *const VideoFrame) !Self {
        var psnr_calc = PSNRCalculator.init();
        var ssim_calc = SSIMCalculator.init(11);
        var diff_calc = FrameDifferenceCalculator.init();

        return .{
            .psnr = try psnr_calc.calculate(frame1, frame2),
            .ssim = try ssim_calc.calculate(frame1, frame2),
            .mad = try diff_calc.calculateMAD(frame1, frame2),
            .mse = try diff_calc.calculateMSE(frame1, frame2),
        };
    }

    pub fn format(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "PSNR: {d:.2} dB, SSIM: {d:.4}, MAD: {d:.2}, MSE: {d:.2}",
            .{ self.psnr, self.ssim, self.mad, self.mse },
        );
    }
};
