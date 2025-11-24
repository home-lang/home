// Home Video Library - Video Quality Metrics
// PSNR, SSIM, and VMAF-like quality analysis

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// PSNR (Peak Signal-to-Noise Ratio)
// ============================================================================

pub const PsnrResult = struct {
    y: f64, // Luma PSNR
    u: f64, // U chroma PSNR
    v: f64, // V chroma PSNR
    average: f64, // Weighted average
    mse_y: f64, // Mean squared error for Y
    mse_u: f64,
    mse_v: f64,

    pub fn isInfinite(self: *const PsnrResult) bool {
        return std.math.isInf(self.y) or std.math.isInf(self.u) or std.math.isInf(self.v);
    }
};

pub fn calculatePsnr(
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    bit_depth: u8,
) !PsnrResult {
    if (reference.len != distorted.len) return error.SizeMismatch;

    const pixels = width * height;
    const chroma_pixels = pixels / 4; // Assuming 4:2:0

    const max_value = (@as(f64, 1) * @as(f64, @floatFromInt(@as(u32, 1) << @intCast(bit_depth)))) - 1.0;

    // Calculate MSE for Y plane
    const mse_y = calculateMse(reference[0..pixels], distorted[0..pixels]);

    // Calculate MSE for U plane
    const u_start = pixels;
    const u_end = pixels + chroma_pixels;
    const mse_u = calculateMse(reference[u_start..u_end], distorted[u_start..u_end]);

    // Calculate MSE for V plane
    const v_start = u_end;
    const v_end = v_start + chroma_pixels;
    const mse_v = calculateMse(reference[v_start..v_end], distorted[v_start..v_end]);

    // Convert MSE to PSNR
    const psnr_y = if (mse_y == 0) std.math.inf(f64) else 10.0 * std.math.log10((max_value * max_value) / mse_y);
    const psnr_u = if (mse_u == 0) std.math.inf(f64) else 10.0 * std.math.log10((max_value * max_value) / mse_u);
    const psnr_v = if (mse_v == 0) std.math.inf(f64) else 10.0 * std.math.log10((max_value * max_value) / mse_v);

    // Weighted average (Y has more weight)
    const avg = (6.0 * psnr_y + psnr_u + psnr_v) / 8.0;

    return PsnrResult{
        .y = psnr_y,
        .u = psnr_u,
        .v = psnr_v,
        .average = avg,
        .mse_y = mse_y,
        .mse_u = mse_u,
        .mse_v = mse_v,
    };
}

fn calculateMse(reference: []const u8, distorted: []const u8) f64 {
    var sum: f64 = 0;
    for (reference, distorted) |r, d| {
        const diff = @as(f64, @floatFromInt(r)) - @as(f64, @floatFromInt(d));
        sum += diff * diff;
    }
    return sum / @as(f64, @floatFromInt(reference.len));
}

// ============================================================================
// SSIM (Structural Similarity Index)
// ============================================================================

pub const SsimResult = struct {
    y: f64, // Luma SSIM
    u: f64, // U chroma SSIM
    v: f64, // V chroma SSIM
    average: f64, // Weighted average
};

pub fn calculateSsim(
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) !SsimResult {
    if (reference.len != distorted.len) return error.SizeMismatch;

    const pixels = width * height;
    const chroma_pixels = pixels / 4;

    // Calculate SSIM for Y plane
    const ssim_y = try calculateSsimPlane(
        reference[0..pixels],
        distorted[0..pixels],
        width,
        height,
        allocator,
    );

    // Calculate SSIM for U plane
    const u_start = pixels;
    const u_end = pixels + chroma_pixels;
    const ssim_u = try calculateSsimPlane(
        reference[u_start..u_end],
        distorted[u_start..u_end],
        width / 2,
        height / 2,
        allocator,
    );

    // Calculate SSIM for V plane
    const v_start = u_end;
    const v_end = v_start + chroma_pixels;
    const ssim_v = try calculateSsimPlane(
        reference[v_start..v_end],
        distorted[v_start..v_end],
        width / 2,
        height / 2,
        allocator,
    );

    // Weighted average
    const avg = (4.0 * ssim_y + ssim_u + ssim_v) / 6.0;

    return SsimResult{
        .y = ssim_y,
        .u = ssim_u,
        .v = ssim_v,
        .average = avg,
    };
}

fn calculateSsimPlane(
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) !f64 {
    const window_size: u32 = 8;
    const c1: f64 = 6.5025; // (0.01 * 255)^2
    const c2: f64 = 58.5225; // (0.03 * 255)^2

    var ssim_sum: f64 = 0;
    var count: u32 = 0;

    // Create Gaussian kernel weights (simplified - uniform for now)
    var weights = try allocator.alloc(f64, window_size * window_size);
    defer allocator.free(weights);
    const weight_val = 1.0 / @as(f64, @floatFromInt(window_size * window_size));
    for (weights) |*w| {
        w.* = weight_val;
    }

    // Slide window across image
    var y: u32 = 0;
    while (y + window_size <= height) : (y += window_size) {
        var x: u32 = 0;
        while (x + window_size <= width) : (x += window_size) {
            const ssim_val = calculateSsimWindow(
                reference,
                distorted,
                x,
                y,
                width,
                window_size,
                weights,
                c1,
                c2,
            );
            ssim_sum += ssim_val;
            count += 1;
        }
    }

    return if (count > 0) ssim_sum / @as(f64, @floatFromInt(count)) else 0.0;
}

fn calculateSsimWindow(
    ref: []const u8,
    dist: []const u8,
    x: u32,
    y: u32,
    stride: u32,
    size: u32,
    weights: []const f64,
    c1: f64,
    c2: f64,
) f64 {
    var sum_ref: f64 = 0;
    var sum_dist: f64 = 0;
    var sum_ref_sq: f64 = 0;
    var sum_dist_sq: f64 = 0;
    var sum_ref_dist: f64 = 0;
    var sum_weights: f64 = 0;

    for (0..size) |dy| {
        for (0..size) |dx| {
            const idx = ((y + @as(u32, @intCast(dy))) * stride + (x + @as(u32, @intCast(dx))));
            if (idx >= ref.len) continue;

            const weight = weights[dy * size + dx];
            const r = @as(f64, @floatFromInt(ref[idx]));
            const d = @as(f64, @floatFromInt(dist[idx]));

            sum_ref += r * weight;
            sum_dist += d * weight;
            sum_ref_sq += r * r * weight;
            sum_dist_sq += d * d * weight;
            sum_ref_dist += r * d * weight;
            sum_weights += weight;
        }
    }

    if (sum_weights == 0) return 1.0;

    const mean_ref = sum_ref / sum_weights;
    const mean_dist = sum_dist / sum_weights;
    const var_ref = sum_ref_sq / sum_weights - mean_ref * mean_ref;
    const var_dist = sum_dist_sq / sum_weights - mean_dist * mean_dist;
    const covar = sum_ref_dist / sum_weights - mean_ref * mean_dist;

    const numerator = (2.0 * mean_ref * mean_dist + c1) * (2.0 * covar + c2);
    const denominator = (mean_ref * mean_ref + mean_dist * mean_dist + c1) *
        (var_ref + var_dist + c2);

    return numerator / denominator;
}

// ============================================================================
// VMAF-like Quality Score
// ============================================================================

pub const VmafResult = struct {
    score: f64, // 0-100 scale
    vif: f64, // Visual Information Fidelity
    dlm: f64, // Detail Loss Metric
    motion: f64, // Motion score

    pub fn getQualityLevel(self: *const VmafResult) []const u8 {
        if (self.score >= 95) return "Excellent";
        if (self.score >= 80) return "Good";
        if (self.score >= 60) return "Fair";
        if (self.score >= 40) return "Poor";
        return "Bad";
    }
};

pub fn calculateVmafLike(
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) !VmafResult {
    // Simplified VMAF-like calculation (real VMAF uses machine learning)

    // Calculate VIF (Visual Information Fidelity)
    const vif = try calculateVif(reference, distorted, width, height, allocator);

    // Calculate DLM (Detail Loss Metric) from high-frequency content
    const dlm = try calculateDlm(reference, distorted, width, height, allocator);

    // Estimate motion from temporal differences (simplified)
    const motion = estimateMotion(reference, width, height);

    // Combine metrics (simplified model)
    const score = std.math.clamp(
        vif * 60.0 + dlm * 30.0 + (1.0 - motion * 0.1) * 10.0,
        0.0,
        100.0,
    );

    return VmafResult{
        .score = score,
        .vif = vif,
        .dlm = dlm,
        .motion = motion,
    };
}

fn calculateVif(
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) !f64 {
    _ = allocator;

    const pixels = width * height;
    var numerator: f64 = 0;
    var denominator: f64 = 0;

    for (0..pixels) |i| {
        if (i >= reference.len or i >= distorted.len) break;

        const r = @as(f64, @floatFromInt(reference[i]));
        const d = @as(f64, @floatFromInt(distorted[i]));

        const variance_ref = r * r;
        const variance_dist = d * d;

        numerator += variance_dist;
        denominator += variance_ref + 1.0; // Add 1 to avoid division by zero
    }

    return if (denominator > 0) std.math.clamp(numerator / denominator, 0.0, 1.0) else 0.0;
}

fn calculateDlm(
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) !f64 {
    _ = allocator;

    // Simple edge-based detail loss
    var detail_loss: f64 = 0;
    var count: u32 = 0;

    for (1..height - 1) |y| {
        for (1..width - 1) |x| {
            const idx = y * width + x;

            // Sobel operator for edge detection
            const edge_ref = calculateEdgeStrength(reference, @intCast(idx), width);
            const edge_dist = calculateEdgeStrength(distorted, @intCast(idx), width);

            const loss = @abs(edge_ref - edge_dist);
            detail_loss += loss;
            count += 1;
        }
    }

    const avg_loss = if (count > 0) detail_loss / @as(f64, @floatFromInt(count)) else 0.0;
    return std.math.clamp(1.0 - (avg_loss / 255.0), 0.0, 1.0);
}

fn calculateEdgeStrength(data: []const u8, idx: usize, stride: usize) f64 {
    if (idx < stride or idx + stride >= data.len) return 0;

    const top = @as(f64, @floatFromInt(data[idx - stride]));
    const bottom = @as(f64, @floatFromInt(data[idx + stride]));
    const left = @as(f64, @floatFromInt(data[idx - 1]));
    const right = @as(f64, @floatFromInt(data[idx + 1]));

    const gx = right - left;
    const gy = bottom - top;

    return @sqrt(gx * gx + gy * gy);
}

fn estimateMotion(data: []const u8, width: u32, height: u32) f64 {
    // Estimate motion from spatial activity
    var activity: f64 = 0;
    var count: u32 = 0;

    for (1..height) |y| {
        for (1..width) |x| {
            const idx = y * width + x;
            if (idx >= data.len or idx < width) continue;

            const curr = @as(f64, @floatFromInt(data[idx]));
            const prev = @as(f64, @floatFromInt(data[idx - width]));

            activity += @abs(curr - prev);
            count += 1;
        }
    }

    const avg_activity = if (count > 0) activity / @as(f64, @floatFromInt(count)) else 0.0;
    return std.math.clamp(avg_activity / 255.0, 0.0, 1.0);
}

// ============================================================================
// Quality Score Interpretation
// ============================================================================

pub const QualityLevel = enum {
    excellent, // PSNR > 40dB, SSIM > 0.95
    good, // PSNR > 35dB, SSIM > 0.90
    fair, // PSNR > 30dB, SSIM > 0.80
    poor, // PSNR > 25dB, SSIM > 0.70
    bad, // Below poor thresholds

    pub fn fromPsnr(psnr: f64) QualityLevel {
        if (psnr > 40.0) return .excellent;
        if (psnr > 35.0) return .good;
        if (psnr > 30.0) return .fair;
        if (psnr > 25.0) return .poor;
        return .bad;
    }

    pub fn fromSsim(ssim: f64) QualityLevel {
        if (ssim > 0.95) return .excellent;
        if (ssim > 0.90) return .good;
        if (ssim > 0.80) return .fair;
        if (ssim > 0.70) return .poor;
        return .bad;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PSNR identical frames" {
    const testing = std.testing;

    var frame1 = [_]u8{100} ** 256;
    var frame2 = [_]u8{100} ** 256;

    const result = try calculatePsnr(&frame1, &frame2, 16, 16, 8);

    try testing.expect(result.isInfinite());
}

test "PSNR different frames" {
    const testing = std.testing;

    var frame1 = [_]u8{100} ** 256;
    var frame2 = [_]u8{110} ** 256;

    const result = try calculatePsnr(&frame1, &frame2, 16, 16, 8);

    try testing.expect(!result.isInfinite());
    try testing.expect(result.mse_y > 0);
}

test "SSIM identical frames" {
    const testing = std.testing;

    var frame1 = [_]u8{100} ** 256;
    var frame2 = [_]u8{100} ** 256;

    const result = try calculateSsim(&frame1, &frame2, 16, 16, testing.allocator);

    try testing.expectApproxEqAbs(@as(f64, 1.0), result.y, 0.01);
}

test "Quality level from PSNR" {
    const testing = std.testing;

    try testing.expectEqual(QualityLevel.excellent, QualityLevel.fromPsnr(45.0));
    try testing.expectEqual(QualityLevel.good, QualityLevel.fromPsnr(37.0));
    try testing.expectEqual(QualityLevel.poor, QualityLevel.fromPsnr(27.0));
    try testing.expectEqual(QualityLevel.bad, QualityLevel.fromPsnr(20.0));
}
