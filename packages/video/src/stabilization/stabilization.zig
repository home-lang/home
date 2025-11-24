// Home Video Library - Video Stabilization
// Motion vector analysis and transform smoothing

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Motion Vector
// ============================================================================

pub const MotionVector = struct {
    dx: f32,
    dy: f32,
    confidence: f32 = 1.0,

    pub fn magnitude(self: *const MotionVector) f32 {
        return @sqrt(self.dx * self.dx + self.dy * self.dy);
    }
};

// ============================================================================
// Transform
// ============================================================================

pub const Transform = struct {
    dx: f32 = 0, // Translation X
    dy: f32 = 0, // Translation Y
    da: f32 = 0, // Rotation angle (radians)
    ds: f32 = 1.0, // Scale

    pub fn identity() Transform {
        return .{};
    }

    pub fn combine(self: *const Transform, other: *const Transform) Transform {
        return .{
            .dx = self.dx + other.dx * self.ds,
            .dy = self.dy + other.dy * self.ds,
            .da = self.da + other.da,
            .ds = self.ds * other.ds,
        };
    }

    pub fn inverse(self: *const Transform) Transform {
        return .{
            .dx = -self.dx / self.ds,
            .dy = -self.dy / self.ds,
            .da = -self.da,
            .ds = 1.0 / self.ds,
        };
    }

    pub fn toMatrix(self: *const Transform) [6]f32 {
        const cos_a = @cos(self.da);
        const sin_a = @sin(self.da);

        return [6]f32{
            self.ds * cos_a,
            self.ds * sin_a,
            self.dx,
            -self.ds * sin_a,
            self.ds * cos_a,
            self.dy,
        };
    }
};

// ============================================================================
// Feature Point
// ============================================================================

pub const FeaturePoint = struct {
    x: f32,
    y: f32,
    response: f32 = 0, // Corner response strength

    pub fn distance(self: *const FeaturePoint, other: *const FeaturePoint) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

// ============================================================================
// Feature Detector (Harris Corner Detector)
// ============================================================================

pub const FeatureDetector = struct {
    width: u32,
    height: u32,
    max_features: usize = 1000,
    quality_level: f32 = 0.01,
    min_distance: f32 = 10.0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32) FeatureDetector {
        return .{
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn detectFeatures(self: *const FeatureDetector, frame: []const u8) ![]FeaturePoint {
        var features = std.ArrayList(FeaturePoint).init(self.allocator);

        // Calculate gradients
        const grad_x = try self.calculateGradientX(frame);
        defer self.allocator.free(grad_x);

        const grad_y = try self.calculateGradientY(frame);
        defer self.allocator.free(grad_y);

        // Calculate corner response
        const response = try self.calculateCornerResponse(grad_x, grad_y);
        defer self.allocator.free(response);

        // Find maximum response value
        var max_response: f32 = 0;
        for (response) |r| {
            if (r > max_response) max_response = r;
        }

        const threshold = max_response * self.quality_level;

        // Non-maximum suppression and feature extraction
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = y * self.width + x;
                if (response[idx] < threshold) continue;

                // Check if this is a local maximum
                if (!self.isLocalMaximum(response, @intCast(x), @intCast(y))) continue;

                // Check minimum distance to existing features
                const point = FeaturePoint{
                    .x = @floatFromInt(x),
                    .y = @floatFromInt(y),
                    .response = response[idx],
                };

                var too_close = false;
                for (features.items) |existing| {
                    if (point.distance(&existing) < self.min_distance) {
                        too_close = true;
                        break;
                    }
                }

                if (!too_close) {
                    try features.append(point);
                    if (features.items.len >= self.max_features) break;
                }
            }
            if (features.items.len >= self.max_features) break;
        }

        return features.toOwnedSlice();
    }

    fn calculateGradientX(self: *const FeatureDetector, frame: []const u8) ![]f32 {
        var grad = try self.allocator.alloc(f32, frame.len);

        for (1..self.height - 1) |y| {
            for (1..self.width - 1) |x| {
                const idx = y * self.width + x;
                const left = @as(f32, @floatFromInt(frame[idx - 1]));
                const right = @as(f32, @floatFromInt(frame[idx + 1]));
                grad[idx] = (right - left) / 2.0;
            }
        }

        return grad;
    }

    fn calculateGradientY(self: *const FeatureDetector, frame: []const u8) ![]f32 {
        var grad = try self.allocator.alloc(f32, frame.len);

        for (1..self.height - 1) |y| {
            for (1..self.width - 1) |x| {
                const idx = y * self.width + x;
                const top = @as(f32, @floatFromInt(frame[idx - self.width]));
                const bottom = @as(f32, @floatFromInt(frame[idx + self.width]));
                grad[idx] = (bottom - top) / 2.0;
            }
        }

        return grad;
    }

    fn calculateCornerResponse(self: *const FeatureDetector, grad_x: []const f32, grad_y: []const f32) ![]f32 {
        var response = try self.allocator.alloc(f32, grad_x.len);
        @memset(response, 0);

        const window_size = 3;
        const k: f32 = 0.04; // Harris corner parameter

        for (window_size..self.height - window_size) |y| {
            for (window_size..self.width - window_size) |x| {
                const idx = y * self.width + x;

                // Calculate structure tensor in window
                var sum_ix2: f32 = 0;
                var sum_iy2: f32 = 0;
                var sum_ixy: f32 = 0;

                for (0..window_size * 2 + 1) |wy| {
                    for (0..window_size * 2 + 1) |wx| {
                        const widx = (y - window_size + wy) * self.width + (x - window_size + wx);
                        const gx = grad_x[widx];
                        const gy = grad_y[widx];

                        sum_ix2 += gx * gx;
                        sum_iy2 += gy * gy;
                        sum_ixy += gx * gy;
                    }
                }

                // Harris corner response
                const det = sum_ix2 * sum_iy2 - sum_ixy * sum_ixy;
                const trace = sum_ix2 + sum_iy2;
                response[idx] = det - k * trace * trace;
            }
        }

        return response;
    }

    fn isLocalMaximum(self: *const FeatureDetector, response: []const f32, x: u32, y: u32) bool {
        const idx = y * self.width + x;
        const value = response[idx];

        for (0..3) |dy| {
            for (0..3) |dx| {
                if (dx == 1 and dy == 1) continue;

                const nx = x + @as(u32, @intCast(dx)) - 1;
                const ny = y + @as(u32, @intCast(dy)) - 1;

                if (nx >= self.width or ny >= self.height) continue;

                const nidx = ny * self.width + nx;
                if (response[nidx] > value) return false;
            }
        }

        return true;
    }
};

// ============================================================================
// Feature Tracker (Lucas-Kanade)
// ============================================================================

pub const FeatureTracker = struct {
    width: u32,
    height: u32,
    window_size: u32 = 15,
    max_iterations: u32 = 20,
    epsilon: f32 = 0.01,

    pub fn init(width: u32, height: u32) FeatureTracker {
        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn trackFeatures(
        self: *const FeatureTracker,
        prev_frame: []const u8,
        curr_frame: []const u8,
        features: []const FeaturePoint,
        allocator: Allocator,
    ) ![]MotionVector {
        var vectors = try allocator.alloc(MotionVector, features.len);

        for (features, 0..) |feature, i| {
            vectors[i] = try self.trackFeature(prev_frame, curr_frame, feature);
        }

        return vectors;
    }

    fn trackFeature(
        self: *const FeatureTracker,
        prev_frame: []const u8,
        curr_frame: []const u8,
        feature: FeaturePoint,
    ) !MotionVector {
        var dx: f32 = 0;
        var dy: f32 = 0;

        const half_win = @as(i32, @intCast(self.window_size)) / 2;

        // Lucas-Kanade optical flow
        for (0..self.max_iterations) |_| {
            var sum_ix2: f32 = 0;
            var sum_iy2: f32 = 0;
            var sum_ixy: f32 = 0;
            var sum_ix_it: f32 = 0;
            var sum_iy_it: f32 = 0;

            for (0..self.window_size) |wy| {
                for (0..self.window_size) |wx| {
                    const px = @as(i32, @intFromFloat(feature.x)) + @as(i32, @intCast(wx)) - half_win;
                    const py = @as(i32, @intFromFloat(feature.y)) + @as(i32, @intCast(wy)) - half_win;

                    if (px < 1 or py < 1 or px >= self.width - 1 or py >= self.height - 1) continue;

                    const qx = px + @as(i32, @intFromFloat(dx));
                    const qy = py + @as(i32, @intFromFloat(dy));

                    if (qx < 1 or qy < 1 or qx >= self.width - 1 or qy >= self.height - 1) continue;

                    const pidx: usize = @intCast(py * @as(i32, @intCast(self.width)) + px);
                    const qidx: usize = @intCast(qy * @as(i32, @intCast(self.width)) + qx);

                    // Spatial gradient from previous frame
                    const ix = (@as(f32, @floatFromInt(prev_frame[pidx + 1])) -
                        @as(f32, @floatFromInt(prev_frame[pidx - 1]))) / 2.0;
                    const iy = (@as(f32, @floatFromInt(prev_frame[pidx + self.width])) -
                        @as(f32, @floatFromInt(prev_frame[pidx - self.width]))) / 2.0;

                    // Temporal gradient
                    const it = @as(f32, @floatFromInt(curr_frame[qidx])) -
                        @as(f32, @floatFromInt(prev_frame[pidx]));

                    sum_ix2 += ix * ix;
                    sum_iy2 += iy * iy;
                    sum_ixy += ix * iy;
                    sum_ix_it += ix * it;
                    sum_iy_it += iy * it;
                }
            }

            // Solve optical flow equation
            const det = sum_ix2 * sum_iy2 - sum_ixy * sum_ixy;
            if (@abs(det) < 1e-5) break;

            const delta_dx = (sum_iy2 * sum_ix_it - sum_ixy * sum_iy_it) / det;
            const delta_dy = (sum_ix2 * sum_iy_it - sum_ixy * sum_ix_it) / det;

            dx -= delta_dx;
            dy -= delta_dy;

            if (@abs(delta_dx) < self.epsilon and @abs(delta_dy) < self.epsilon) break;
        }

        return .{ .dx = dx, .dy = dy };
    }
};

// ============================================================================
// Transform Estimator
// ============================================================================

pub const TransformEstimator = struct {
    pub fn estimateTransform(
        features: []const FeaturePoint,
        vectors: []const MotionVector,
    ) Transform {
        if (features.len < 3 or vectors.len < 3) return Transform.identity();

        // Use RANSAC to robustly estimate transform
        // Simplified: use average motion
        var sum_dx: f32 = 0;
        var sum_dy: f32 = 0;
        var count: f32 = 0;

        for (vectors) |vec| {
            if (vec.confidence > 0.5) {
                sum_dx += vec.dx;
                sum_dy += vec.dy;
                count += 1;
            }
        }

        if (count == 0) return Transform.identity();

        return .{
            .dx = sum_dx / count,
            .dy = sum_dy / count,
            .da = 0, // Simplified - would calculate rotation
            .ds = 1.0,
        };
    }
};

// ============================================================================
// Transform Smoother
// ============================================================================

pub const SmootherType = enum {
    moving_average,
    gaussian,
    kalman,
};

pub const TransformSmoother = struct {
    type: SmootherType,
    window_size: usize = 30,
    history: std.ArrayList(Transform),
    allocator: Allocator,

    pub fn init(allocator: Allocator, smoother_type: SmootherType) TransformSmoother {
        return .{
            .type = smoother_type,
            .history = std.ArrayList(Transform).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TransformSmoother) void {
        self.history.deinit();
    }

    pub fn addTransform(self: *TransformSmoother, transform: Transform) !Transform {
        try self.history.append(transform);

        // Keep only recent history
        if (self.history.items.len > self.window_size) {
            _ = self.history.orderedRemove(0);
        }

        return switch (self.type) {
            .moving_average => self.movingAverage(),
            .gaussian => self.gaussianSmooth(),
            .kalman => self.kalmanFilter(),
        };
    }

    fn movingAverage(self: *const TransformSmoother) Transform {
        if (self.history.items.len == 0) return Transform.identity();

        var sum_dx: f32 = 0;
        var sum_dy: f32 = 0;
        var sum_da: f32 = 0;
        var sum_ds: f32 = 0;

        for (self.history.items) |t| {
            sum_dx += t.dx;
            sum_dy += t.dy;
            sum_da += t.da;
            sum_ds += t.ds;
        }

        const count = @as(f32, @floatFromInt(self.history.items.len));
        return .{
            .dx = sum_dx / count,
            .dy = sum_dy / count,
            .da = sum_da / count,
            .ds = sum_ds / count,
        };
    }

    fn gaussianSmooth(self: *const TransformSmoother) Transform {
        if (self.history.items.len == 0) return Transform.identity();

        // Gaussian kernel
        const sigma: f32 = 5.0;
        var sum_dx: f32 = 0;
        var sum_dy: f32 = 0;
        var sum_da: f32 = 0;
        var sum_ds: f32 = 0;
        var sum_weight: f32 = 0;

        const center = @as(f32, @floatFromInt(self.history.items.len)) / 2.0;

        for (self.history.items, 0..) |t, i| {
            const x = @as(f32, @floatFromInt(i)) - center;
            const weight = @exp(-(x * x) / (2.0 * sigma * sigma));

            sum_dx += t.dx * weight;
            sum_dy += t.dy * weight;
            sum_da += t.da * weight;
            sum_ds += t.ds * weight;
            sum_weight += weight;
        }

        return .{
            .dx = sum_dx / sum_weight,
            .dy = sum_dy / sum_weight,
            .da = sum_da / sum_weight,
            .ds = sum_ds / sum_weight,
        };
    }

    fn kalmanFilter(self: *const TransformSmoother) Transform {
        // Simplified Kalman filter
        // Real implementation would maintain state estimates and covariance
        return self.gaussianSmooth();
    }
};

// ============================================================================
// Video Stabilizer
// ============================================================================

pub const StabilizerOptions = struct {
    smoothness: f32 = 30.0, // Smoothing window size
    max_shift: f32 = 100.0, // Maximum shift in pixels
    crop_ratio: f32 = 0.04, // Amount to crop (0.04 = 4%)
    smoother_type: SmootherType = .gaussian,
};

pub const VideoStabilizer = struct {
    width: u32,
    height: u32,
    options: StabilizerOptions,
    detector: FeatureDetector,
    tracker: FeatureTracker,
    smoother: TransformSmoother,
    previous_frame: ?[]u8 = null,
    previous_features: ?[]FeaturePoint = null,
    cumulative_transform: Transform = Transform.identity(),
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32, options: StabilizerOptions) VideoStabilizer {
        return .{
            .width = width,
            .height = height,
            .options = options,
            .detector = FeatureDetector.init(allocator, width, height),
            .tracker = FeatureTracker.init(width, height),
            .smoother = TransformSmoother.init(allocator, options.smoother_type),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VideoStabilizer) void {
        if (self.previous_frame) |frame| {
            self.allocator.free(frame);
        }
        if (self.previous_features) |features| {
            self.allocator.free(features);
        }
        self.smoother.deinit();
    }

    pub fn processFrame(self: *VideoStabilizer, frame: []const u8) !Transform {
        const pixels = self.width * self.height;
        if (frame.len < pixels) return error.InvalidFrame;

        const luma = frame[0..pixels];

        if (self.previous_frame == null) {
            // First frame
            self.previous_frame = try self.allocator.dupe(u8, luma);
            self.previous_features = try self.detector.detectFeatures(luma);
            return Transform.identity();
        }

        // Detect features in previous frame if not available
        if (self.previous_features == null) {
            self.previous_features = try self.detector.detectFeatures(self.previous_frame.?);
        }

        // Track features
        const vectors = try self.tracker.trackFeatures(
            self.previous_frame.?,
            luma,
            self.previous_features.?,
            self.allocator,
        );
        defer self.allocator.free(vectors);

        // Estimate transform
        const frame_transform = TransformEstimator.estimateTransform(self.previous_features.?, vectors);

        // Accumulate transform
        self.cumulative_transform = self.cumulative_transform.combine(&frame_transform);

        // Smooth transform
        const smoothed = try self.smoother.addTransform(self.cumulative_transform);

        // Calculate stabilization transform (difference between actual and smoothed)
        const stabilization = Transform{
            .dx = smoothed.dx - self.cumulative_transform.dx,
            .dy = smoothed.dy - self.cumulative_transform.dy,
            .da = smoothed.da - self.cumulative_transform.da,
            .ds = smoothed.ds / self.cumulative_transform.ds,
        };

        // Clamp shifts
        const clamped = Transform{
            .dx = std.math.clamp(stabilization.dx, -self.options.max_shift, self.options.max_shift),
            .dy = std.math.clamp(stabilization.dy, -self.options.max_shift, self.options.max_shift),
            .da = stabilization.da,
            .ds = stabilization.ds,
        };

        // Update previous frame and features
        @memcpy(self.previous_frame.?, luma);
        self.allocator.free(self.previous_features.?);
        self.previous_features = try self.detector.detectFeatures(luma);

        return clamped;
    }

    pub fn reset(self: *VideoStabilizer) void {
        if (self.previous_frame) |frame| {
            self.allocator.free(frame);
            self.previous_frame = null;
        }
        if (self.previous_features) |features| {
            self.allocator.free(features);
            self.previous_features = null;
        }
        self.cumulative_transform = Transform.identity();
        self.smoother.history.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Transform combination" {
    const testing = std.testing;

    const t1 = Transform{ .dx = 10, .dy = 5 };
    const t2 = Transform{ .dx = -3, .dy = 2 };

    const combined = t1.combine(&t2);

    try testing.expectEqual(@as(f32, 7), combined.dx);
    try testing.expectEqual(@as(f32, 7), combined.dy);
}

test "Feature point distance" {
    const testing = std.testing;

    const p1 = FeaturePoint{ .x = 0, .y = 0 };
    const p2 = FeaturePoint{ .x = 3, .y = 4 };

    const dist = p1.distance(&p2);
    try testing.expectApproxEqAbs(@as(f32, 5.0), dist, 0.01);
}

test "Transform smoother moving average" {
    const testing = std.testing;

    var smoother = TransformSmoother.init(testing.allocator, .moving_average);
    defer smoother.deinit();

    _ = try smoother.addTransform(.{ .dx = 10, .dy = 0 });
    _ = try smoother.addTransform(.{ .dx = 20, .dy = 0 });
    const result = try smoother.addTransform(.{ .dx = 30, .dy = 0 });

    try testing.expectApproxEqAbs(@as(f32, 20.0), result.dx, 0.01);
}
