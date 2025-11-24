const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Feature Detection and Matching
// ============================================================================

pub const Feature = struct {
    x: f32,
    y: f32,
    scale: f32,
    orientation: f32,
    descriptor: [128]f32, // Simplified SIFT-like descriptor
    strength: f32,
};

pub const FeatureMatch = struct {
    feature1_idx: usize,
    feature2_idx: usize,
    distance: f32,
    confidence: f32,
};

pub const FeatureDetectionOptions = struct {
    max_features: usize = 1000,
    corner_threshold: f32 = 0.01,
    edge_threshold: f32 = 10.0,
};

/// Detects key features in an image using corner detection
pub fn detectFeatures(allocator: std.mem.Allocator, img: *const Image, options: FeatureDetectionOptions) ![]Feature {
    var features = std.ArrayList(Feature).init(allocator);
    defer features.deinit();

    // Convert to grayscale
    var gray = try allocator.alloc(f32, img.width * img.height);
    defer allocator.free(gray);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y));
            const intensity = (@as(f32, @floatFromInt(pixel.r)) * 0.299 +
                @as(f32, @floatFromInt(pixel.g)) * 0.587 +
                @as(f32, @floatFromInt(pixel.b)) * 0.114) / 255.0;
            gray[y * img.width + x] = intensity;
        }
    }

    // Compute Harris corners
    var corners = try computeHarrisCorners(allocator, gray, img.width, img.height, options);
    defer allocator.free(corners);

    // Extract features from corners
    for (corners) |corner| {
        if (features.items.len >= options.max_features) break;

        const descriptor = try computeDescriptor(gray, img.width, img.height, corner.x, corner.y);
        try features.append(Feature{
            .x = corner.x,
            .y = corner.y,
            .scale = 1.0,
            .orientation = 0.0,
            .descriptor = descriptor,
            .strength = corner.strength,
        });
    }

    return features.toOwnedSlice();
}

const Corner = struct {
    x: f32,
    y: f32,
    strength: f32,
};

fn computeHarrisCorners(allocator: std.mem.Allocator, gray: []const f32, width: u32, height: u32, options: FeatureDetectionOptions) ![]Corner {
    var corners = std.ArrayList(Corner).init(allocator);
    defer corners.deinit();

    // Compute image gradients
    var Ix = try allocator.alloc(f32, width * height);
    defer allocator.free(Ix);
    var Iy = try allocator.alloc(f32, width * height);
    defer allocator.free(Iy);

    for (1..height - 1) |y| {
        for (1..width - 1) |x| {
            const idx = y * width + x;
            Ix[idx] = (gray[idx + 1] - gray[idx - 1]) / 2.0;
            Iy[idx] = (gray[idx + width] - gray[idx - width]) / 2.0;
        }
    }

    // Compute Harris response
    const window_size = 3;
    const k: f32 = 0.04;

    for (window_size..height - window_size) |y| {
        for (window_size..width - window_size) |x| {
            var Ixx: f32 = 0.0;
            var Iyy: f32 = 0.0;
            var Ixy: f32 = 0.0;

            // Sum over window
            for (0..window_size) |dy| {
                for (0..window_size) |dx| {
                    const idx = (y + dy - window_size / 2) * width + (x + dx - window_size / 2);
                    Ixx += Ix[idx] * Ix[idx];
                    Iyy += Iy[idx] * Iy[idx];
                    Ixy += Ix[idx] * Iy[idx];
                }
            }

            // Harris response: det(M) - k * trace(M)^2
            const det = Ixx * Iyy - Ixy * Ixy;
            const trace = Ixx + Iyy;
            const response = det - k * trace * trace;

            if (response > options.corner_threshold) {
                try corners.append(Corner{
                    .x = @floatFromInt(x),
                    .y = @floatFromInt(y),
                    .strength = response,
                });
            }
        }
    }

    // Sort by strength and return top corners
    std.mem.sort(Corner, corners.items, {}, struct {
        fn lessThan(_: void, a: Corner, b: Corner) bool {
            return a.strength > b.strength;
        }
    }.lessThan);

    return corners.toOwnedSlice();
}

fn computeDescriptor(gray: []const f32, width: u32, height: u32, x: f32, y: f32) [128]f32 {
    var descriptor: [128]f32 = undefined;

    const cx = @as(i32, @intFromFloat(x));
    const cy = @as(i32, @intFromFloat(y));
    const patch_size = 16;

    // Simplified descriptor: sample patch around feature
    var idx: usize = 0;
    for (0..patch_size) |dy| {
        for (0..patch_size) |dx| {
            const px = cx - patch_size / 2 + @as(i32, @intCast(dx));
            const py = cy - patch_size / 2 + @as(i32, @intCast(dy));

            var value: f32 = 0.0;
            if (px >= 0 and px < width and py >= 0 and py < height) {
                value = gray[@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))];
            }

            if (idx < 128) {
                descriptor[idx] = value;
                idx += 1;
            }
        }
    }

    // Normalize
    var sum: f32 = 0.0;
    for (descriptor) |val| {
        sum += val * val;
    }
    const norm = @sqrt(sum);
    if (norm > 0.0001) {
        for (&descriptor) |*val| {
            val.* /= norm;
        }
    }

    return descriptor;
}

/// Matches features between two images
pub fn matchFeatures(allocator: std.mem.Allocator, features1: []const Feature, features2: []const Feature, max_distance: f32) ![]FeatureMatch {
    var matches = std.ArrayList(FeatureMatch).init(allocator);
    defer matches.deinit();

    // For each feature in image 1, find best match in image 2
    for (features1, 0..) |f1, i| {
        var best_distance: f32 = std.math.floatMax(f32);
        var second_best_distance: f32 = std.math.floatMax(f32);
        var best_idx: usize = 0;

        for (features2, 0..) |f2, j| {
            const distance = computeDescriptorDistance(&f1.descriptor, &f2.descriptor);

            if (distance < best_distance) {
                second_best_distance = best_distance;
                best_distance = distance;
                best_idx = j;
            } else if (distance < second_best_distance) {
                second_best_distance = distance;
            }
        }

        // Lowe's ratio test
        if (best_distance < max_distance and best_distance < 0.7 * second_best_distance) {
            try matches.append(FeatureMatch{
                .feature1_idx = i,
                .feature2_idx = best_idx,
                .distance = best_distance,
                .confidence = 1.0 - (best_distance / second_best_distance),
            });
        }
    }

    return matches.toOwnedSlice();
}

fn computeDescriptorDistance(desc1: *const [128]f32, desc2: *const [128]f32) f32 {
    var sum: f32 = 0.0;
    for (desc1, desc2) |v1, v2| {
        const diff = v1 - v2;
        sum += diff * diff;
    }
    return @sqrt(sum);
}

// ============================================================================
// Homography Estimation (RANSAC)
// ============================================================================

pub const Homography = struct {
    matrix: [9]f32, // 3x3 matrix stored row-major

    pub fn identity() Homography {
        return Homography{
            .matrix = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        };
    }

    pub fn transform(self: *const Homography, x: f32, y: f32) struct { x: f32, y: f32 } {
        const w = self.matrix[6] * x + self.matrix[7] * y + self.matrix[8];
        return .{
            .x = (self.matrix[0] * x + self.matrix[1] * y + self.matrix[2]) / w,
            .y = (self.matrix[3] * x + self.matrix[4] * y + self.matrix[5]) / w,
        };
    }
};

pub const RANSACOptions = struct {
    max_iterations: u32 = 1000,
    inlier_threshold: f32 = 3.0,
    confidence: f32 = 0.99,
};

/// Estimates homography between matched features using RANSAC
pub fn estimateHomography(
    allocator: std.mem.Allocator,
    features1: []const Feature,
    features2: []const Feature,
    matches: []const FeatureMatch,
    options: RANSACOptions,
) !Homography {
    if (matches.len < 4) return error.InsufficientMatches;

    var best_homography = Homography.identity();
    var best_inlier_count: usize = 0;
    var rng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));

    for (0..options.max_iterations) |_| {
        // Select 4 random matches
        var indices: [4]usize = undefined;
        for (&indices) |*idx| {
            idx.* = rng.random().intRangeAtMost(usize, 0, matches.len - 1);
        }

        // Compute homography from these 4 points
        var src_points: [4][2]f32 = undefined;
        var dst_points: [4][2]f32 = undefined;

        for (indices, 0..) |match_idx, i| {
            const match = matches[match_idx];
            src_points[i] = [_]f32{ features1[match.feature1_idx].x, features1[match.feature1_idx].y };
            dst_points[i] = [_]f32{ features2[match.feature2_idx].x, features2[match.feature2_idx].y };
        }

        const H = computeHomographyDLT(&src_points, &dst_points) catch continue;

        // Count inliers
        var inlier_count: usize = 0;
        for (matches) |match| {
            const p1 = features1[match.feature1_idx];
            const p2 = features2[match.feature2_idx];

            const transformed = H.transform(p1.x, p1.y);
            const dx = transformed.x - p2.x;
            const dy = transformed.y - p2.y;
            const error = @sqrt(dx * dx + dy * dy);

            if (error < options.inlier_threshold) {
                inlier_count += 1;
            }
        }

        if (inlier_count > best_inlier_count) {
            best_inlier_count = inlier_count;
            best_homography = H;
        }

        // Early termination if we have enough inliers
        const inlier_ratio = @as(f32, @floatFromInt(inlier_count)) / @as(f32, @floatFromInt(matches.len));
        if (inlier_ratio > options.confidence) break;
    }

    _ = allocator;
    return best_homography;
}

fn computeHomographyDLT(src: *const [4][2]f32, dst: *const [4][2]f32) !Homography {
    // Simplified DLT (Direct Linear Transform)
    // Real implementation would solve 8x9 linear system

    // For now, compute affine approximation
    var sum_sx: f32 = 0;
    var sum_sy: f32 = 0;
    var sum_dx: f32 = 0;
    var sum_dy: f32 = 0;

    for (src, dst) |s, d| {
        sum_sx += s[0];
        sum_sy += s[1];
        sum_dx += d[0];
        sum_dy += d[1];
    }

    const scale_x = (dst[1][0] - dst[0][0]) / (src[1][0] - src[0][0] + 0.0001);
    const scale_y = (dst[2][1] - dst[0][1]) / (src[2][1] - src[0][1] + 0.0001);
    const tx = sum_dx / 4.0 - (sum_sx / 4.0) * scale_x;
    const ty = sum_dy / 4.0 - (sum_sy / 4.0) * scale_y;

    return Homography{
        .matrix = [_]f32{
            scale_x, 0,       tx,
            0,       scale_y, ty,
            0,       0,       1,
        },
    };
}

// ============================================================================
// Image Stitching
// ============================================================================

pub const StitchOptions = struct {
    blend_width: u32 = 50,
    blend_mode: enum { linear, multiband } = .linear,
};

pub const PanoramaResult = struct {
    image: Image,
    homographies: []Homography,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PanoramaResult) void {
        self.image.deinit();
        self.allocator.free(self.homographies);
    }
};

/// Stitches multiple images into a panorama
pub fn stitchPanorama(
    allocator: std.mem.Allocator,
    images: []const *const Image,
    options: StitchOptions,
) !PanoramaResult {
    if (images.len < 2) return error.InsufficientImages;

    // Detect features in all images
    var all_features = try allocator.alloc([]Feature, images.len);
    defer {
        for (all_features) |features| {
            allocator.free(features);
        }
        allocator.free(all_features);
    }

    for (images, 0..) |img, i| {
        all_features[i] = try detectFeatures(allocator, img, .{});
    }

    // Compute homographies between consecutive images
    var homographies = try allocator.alloc(Homography, images.len);
    homographies[0] = Homography.identity(); // Reference image

    for (1..images.len) |i| {
        const matches = try matchFeatures(allocator, all_features[i - 1], all_features[i], 0.5);
        defer allocator.free(matches);

        homographies[i] = try estimateHomography(
            allocator,
            all_features[i - 1],
            all_features[i],
            matches,
            .{},
        );
    }

    // Compute output canvas size
    var min_x: f32 = 0;
    var max_x: f32 = @floatFromInt(images[0].width);
    var min_y: f32 = 0;
    var max_y: f32 = @floatFromInt(images[0].height);

    for (images, homographies) |img, H| {
        const corners = [_]struct { x: f32, y: f32 }{
            H.transform(0, 0),
            H.transform(@floatFromInt(img.width), 0),
            H.transform(0, @floatFromInt(img.height)),
            H.transform(@floatFromInt(img.width), @floatFromInt(img.height)),
        };

        for (corners) |corner| {
            min_x = @min(min_x, corner.x);
            max_x = @max(max_x, corner.x);
            min_y = @min(min_y, corner.y);
            max_y = @max(max_y, corner.y);
        }
    }

    const canvas_width = @as(u32, @intFromFloat(@ceil(max_x - min_x)));
    const canvas_height = @as(u32, @intFromFloat(@ceil(max_y - min_y)));

    // Create output canvas
    var canvas = try Image.init(allocator, canvas_width, canvas_height, .rgba);

    // Initialize with transparent
    for (0..canvas_height) |y| {
        for (0..canvas_width) |x| {
            canvas.setPixel(@intCast(x), @intCast(y), Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        }
    }

    // Warp and blend each image
    for (images, homographies) |img, H| {
        try blendImage(&canvas, img, &H, -min_x, -min_y, options);
    }

    return PanoramaResult{
        .image = canvas,
        .homographies = homographies,
        .allocator = allocator,
    };
}

fn blendImage(canvas: *Image, img: *const Image, H: *const Homography, offset_x: f32, offset_y: f32, options: StitchOptions) !void {
    // For each pixel in the source image
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const src_point = H.transform(@floatFromInt(x), @floatFromInt(y));
            const canvas_x = @as(i32, @intFromFloat(src_point.x + offset_x));
            const canvas_y = @as(i32, @intFromFloat(src_point.y + offset_y));

            if (canvas_x >= 0 and canvas_x < canvas.width and canvas_y >= 0 and canvas_y < canvas.height) {
                const src_color = img.getPixel(@intCast(x), @intCast(y));
                const ux = @as(u32, @intCast(canvas_x));
                const uy = @as(u32, @intCast(canvas_y));
                const existing = canvas.getPixel(ux, uy);

                // Simple alpha blending
                if (existing.a == 0) {
                    canvas.setPixel(ux, uy, src_color);
                } else {
                    // Compute blend weight based on distance from edge
                    const edge_dist_x = @min(@as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(img.width - x)));
                    const edge_dist_y = @min(@as(f32, @floatFromInt(y)), @as(f32, @floatFromInt(img.height - y)));
                    const edge_dist = @min(edge_dist_x, edge_dist_y);
                    const blend_weight = @min(1.0, edge_dist / @as(f32, @floatFromInt(options.blend_width)));

                    const blended = Color{
                        .r = @intFromFloat(@as(f32, @floatFromInt(existing.r)) * (1.0 - blend_weight) + @as(f32, @floatFromInt(src_color.r)) * blend_weight),
                        .g = @intFromFloat(@as(f32, @floatFromInt(existing.g)) * (1.0 - blend_weight) + @as(f32, @floatFromInt(src_color.g)) * blend_weight),
                        .b = @intFromFloat(@as(f32, @floatFromInt(existing.b)) * (1.0 - blend_weight) + @as(f32, @floatFromInt(src_color.b)) * blend_weight),
                        .a = 255,
                    };
                    canvas.setPixel(ux, uy, blended);
                }
            }
        }
    }

    _ = options;
}
