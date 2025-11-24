const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Mesh Warping
// ============================================================================

pub const Point2D = struct {
    x: f32,
    y: f32,

    pub fn distance(self: Point2D, other: Point2D) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }

    pub fn lerp(self: Point2D, other: Point2D, t: f32) Point2D {
        return Point2D{
            .x = self.x + (other.x - self.x) * t,
            .y = self.y + (other.y - self.y) * t,
        };
    }
};

pub const ControlPoint = struct {
    source: Point2D,
    target: Point2D,
};

pub const WarpMesh = struct {
    grid_width: u32,
    grid_height: u32,
    control_points: []Point2D, // (grid_width + 1) * (grid_height + 1) points
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, grid_width: u32, grid_height: u32, img_width: u32, img_height: u32) !WarpMesh {
        const num_points = (grid_width + 1) * (grid_height + 1);
        var points = try allocator.alloc(Point2D, num_points);

        // Initialize grid
        for (0..grid_height + 1) |row| {
            for (0..grid_width + 1) |col| {
                const idx = row * (grid_width + 1) + col;
                points[idx] = Point2D{
                    .x = @as(f32, @floatFromInt(col)) * @as(f32, @floatFromInt(img_width)) / @as(f32, @floatFromInt(grid_width)),
                    .y = @as(f32, @floatFromInt(row)) * @as(f32, @floatFromInt(img_height)) / @as(f32, @floatFromInt(grid_height)),
                };
            }
        }

        return WarpMesh{
            .grid_width = grid_width,
            .grid_height = grid_height,
            .control_points = points,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WarpMesh) void {
        self.allocator.free(self.control_points);
    }

    pub fn setControlPoint(self: *WarpMesh, row: u32, col: u32, point: Point2D) void {
        if (row <= self.grid_height and col <= self.grid_width) {
            const idx = row * (self.grid_width + 1) + col;
            self.control_points[idx] = point;
        }
    }

    pub fn getControlPoint(self: *const WarpMesh, row: u32, col: u32) Point2D {
        const idx = row * (self.grid_width + 1) + col;
        return self.control_points[idx];
    }
};

pub const WarpOptions = struct {
    interpolation: enum { nearest, bilinear, bicubic } = .bilinear,
    edge_mode: enum { clamp, wrap, transparent } = .clamp,
};

/// Warps an image according to a control mesh
pub fn warpImage(allocator: std.mem.Allocator, img: *const Image, mesh: *const WarpMesh, options: WarpOptions) !Image {
    var result = try Image.init(allocator, img.width, img.height, img.format);

    // Fill with transparent or background
    for (0..result.height) |y| {
        for (0..result.width) |x| {
            result.setPixel(@intCast(x), @intCast(y), Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        }
    }

    // For each output pixel, find source pixel using inverse warping
    for (0..result.height) |y| {
        for (0..result.width) |x| {
            const target_point = Point2D{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
            };

            // Find which mesh cell this point is in
            const cell_x = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(img.width)) * @as(f32, @floatFromInt(mesh.grid_width));
            const cell_y = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(img.height)) * @as(f32, @floatFromInt(mesh.grid_height));

            const grid_x = @as(u32, @intFromFloat(@floor(cell_x)));
            const grid_y = @as(u32, @intFromFloat(@floor(cell_y)));

            if (grid_x >= mesh.grid_width or grid_y >= mesh.grid_height) continue;

            // Get the 4 control points of this cell
            const p00 = mesh.getControlPoint(grid_y, grid_x);
            const p10 = mesh.getControlPoint(grid_y, grid_x + 1);
            const p01 = mesh.getControlPoint(grid_y + 1, grid_x);
            const p11 = mesh.getControlPoint(grid_y + 1, grid_x + 1);

            // Bilinear interpolation to find source point
            const tx = cell_x - @floor(cell_x);
            const ty = cell_y - @floor(cell_y);

            const top = p00.lerp(p10, tx);
            const bottom = p01.lerp(p11, tx);
            const source_point = top.lerp(bottom, ty);

            // Sample from source image
            const color = sampleImage(img, source_point.x, source_point.y, options);
            result.setPixel(@intCast(x), @intCast(y), color);
        }
    }

    return result;
}

fn sampleImage(img: *const Image, x: f32, y: f32, options: WarpOptions) Color {
    // Handle out of bounds
    if (x < 0 or y < 0 or x >= @as(f32, @floatFromInt(img.width)) or y >= @as(f32, @floatFromInt(img.height))) {
        return switch (options.edge_mode) {
            .transparent => Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .clamp => {
                const cx = @min(@as(u32, @intFromFloat(@max(0, x))), img.width - 1);
                const cy = @min(@as(u32, @intFromFloat(@max(0, y))), img.height - 1);
                return img.getPixel(cx, cy);
            },
            .wrap => {
                const wx = @as(u32, @intFromFloat(@mod(x, @as(f32, @floatFromInt(img.width)))));
                const wy = @as(u32, @intFromFloat(@mod(y, @as(f32, @floatFromInt(img.height)))));
                return img.getPixel(wx, wy);
            },
        };
    }

    return switch (options.interpolation) {
        .nearest => {
            const ix = @as(u32, @intFromFloat(@round(x)));
            const iy = @as(u32, @intFromFloat(@round(y)));
            return img.getPixel(@min(ix, img.width - 1), @min(iy, img.height - 1));
        },
        .bilinear => bilinearSample(img, x, y),
        .bicubic => bicubicSample(img, x, y),
    };
}

fn bilinearSample(img: *const Image, x: f32, y: f32) Color {
    const x0 = @as(u32, @intFromFloat(@floor(x)));
    const y0 = @as(u32, @intFromFloat(@floor(y)));
    const x1 = @min(x0 + 1, img.width - 1);
    const y1 = @min(y0 + 1, img.height - 1);

    const tx = x - @floor(x);
    const ty = y - @floor(y);

    const c00 = img.getPixel(x0, y0);
    const c10 = img.getPixel(x1, y0);
    const c01 = img.getPixel(x0, y1);
    const c11 = img.getPixel(x1, y1);

    return Color{
        .r = @intFromFloat(lerp(lerp(@as(f32, @floatFromInt(c00.r)), @as(f32, @floatFromInt(c10.r)), tx), lerp(@as(f32, @floatFromInt(c01.r)), @as(f32, @floatFromInt(c11.r)), tx), ty)),
        .g = @intFromFloat(lerp(lerp(@as(f32, @floatFromInt(c00.g)), @as(f32, @floatFromInt(c10.g)), tx), lerp(@as(f32, @floatFromInt(c01.g)), @as(f32, @floatFromInt(c11.g)), tx), ty)),
        .b = @intFromFloat(lerp(lerp(@as(f32, @floatFromInt(c00.b)), @as(f32, @floatFromInt(c10.b)), tx), lerp(@as(f32, @floatFromInt(c01.b)), @as(f32, @floatFromInt(c11.b)), tx), ty)),
        .a = @intFromFloat(lerp(lerp(@as(f32, @floatFromInt(c00.a)), @as(f32, @floatFromInt(c10.a)), tx), lerp(@as(f32, @floatFromInt(c01.a)), @as(f32, @floatFromInt(c11.a)), tx), ty)),
    };
}

fn bicubicSample(img: *const Image, x: f32, y: f32) Color {
    // Simplified bicubic - real implementation would use cubic kernel
    return bilinearSample(img, x, y);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// ============================================================================
// Image Morphing (Cross-Dissolve with Field Warping)
// ============================================================================

pub const MorphOptions = struct {
    control_points: []ControlPoint,
    alpha: f32 = 0.5, // 0.0 = source, 1.0 = target
    warp_strength: f32 = 1.0,
    blend_mode: enum { linear, smoothstep } = .linear,
};

/// Morphs between two images using control points
pub fn morphImages(
    allocator: std.mem.Allocator,
    source: *const Image,
    target: *const Image,
    options: MorphOptions,
) !Image {
    if (source.width != target.width or source.height != target.height) {
        return error.DimensionMismatch;
    }

    var result = try Image.init(allocator, source.width, source.height, source.format);

    // Calculate blend factor
    const blend = switch (options.blend_mode) {
        .linear => options.alpha,
        .smoothstep => smoothstep(options.alpha),
    };

    // For each output pixel
    for (0..result.height) |y| {
        for (0..result.width) |x| {
            const current = Point2D{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
            };

            // Calculate warped positions using all control points
            var source_pos = current;
            var target_pos = current;

            for (options.control_points) |cp| {
                const weight = calculateWeight(current, cp.source, cp.target);

                // Move source position away from control point
                const source_delta = Point2D{
                    .x = (cp.target.x - cp.source.x) * weight * options.warp_strength,
                    .y = (cp.target.y - cp.source.y) * weight * options.warp_strength,
                };
                source_pos.x += source_delta.x * (1.0 - blend);
                source_pos.y += source_delta.y * (1.0 - blend);

                // Move target position toward control point
                const target_delta = Point2D{
                    .x = (cp.source.x - cp.target.x) * weight * options.warp_strength,
                    .y = (cp.source.y - cp.target.y) * weight * options.warp_strength,
                };
                target_pos.x += target_delta.x * blend;
                target_pos.y += target_delta.y * blend;
            }

            // Sample both images
            const source_color = sampleImageSafe(source, source_pos.x, source_pos.y);
            const target_color = sampleImageSafe(target, target_pos.x, target_pos.y);

            // Blend the two samples
            const final_color = Color{
                .r = @intFromFloat(lerp(@as(f32, @floatFromInt(source_color.r)), @as(f32, @floatFromInt(target_color.r)), blend)),
                .g = @intFromFloat(lerp(@as(f32, @floatFromInt(source_color.g)), @as(f32, @floatFromInt(target_color.g)), blend)),
                .b = @intFromFloat(lerp(@as(f32, @floatFromInt(source_color.b)), @as(f32, @floatFromInt(target_color.b)), blend)),
                .a = @intFromFloat(lerp(@as(f32, @floatFromInt(source_color.a)), @as(f32, @floatFromInt(target_color.a)), blend)),
            };

            result.setPixel(@intCast(x), @intCast(y), final_color);
        }
    }

    return result;
}

fn calculateWeight(point: Point2D, cp_source: Point2D, cp_target: Point2D) f32 {
    // Use inverse distance weighting
    const dist_to_source = point.distance(cp_source);
    const dist_to_target = point.distance(cp_target);
    const avg_dist = (dist_to_source + dist_to_target) / 2.0;

    if (avg_dist < 1.0) return 1.0;

    // Gaussian falloff
    const sigma: f32 = 100.0;
    return @exp(-(avg_dist * avg_dist) / (2.0 * sigma * sigma));
}

fn sampleImageSafe(img: *const Image, x: f32, y: f32) Color {
    if (x < 0 or y < 0 or x >= @as(f32, @floatFromInt(img.width)) or y >= @as(f32, @floatFromInt(img.height))) {
        const cx = @min(@as(u32, @intFromFloat(@max(0, x))), img.width - 1);
        const cy = @min(@as(u32, @intFromFloat(@max(0, y))), img.height - 1);
        return img.getPixel(cx, cy);
    }

    return bilinearSample(img, x, y);
}

fn smoothstep(t: f32) f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

// ============================================================================
// Animation Generation
// ============================================================================

pub const MorphSequence = struct {
    frames: []Image,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MorphSequence) void {
        for (self.frames) |*frame| {
            frame.deinit();
        }
        self.allocator.free(self.frames);
    }
};

/// Generates a sequence of morphed frames between two images
pub fn generateMorphSequence(
    allocator: std.mem.Allocator,
    source: *const Image,
    target: *const Image,
    control_points: []ControlPoint,
    num_frames: u32,
    warp_strength: f32,
) !MorphSequence {
    var frames = try allocator.alloc(Image, num_frames);
    errdefer {
        for (frames) |*frame| frame.deinit();
        allocator.free(frames);
    }

    for (0..num_frames) |i| {
        const alpha = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_frames - 1));

        frames[i] = try morphImages(allocator, source, target, MorphOptions{
            .control_points = control_points,
            .alpha = alpha,
            .warp_strength = warp_strength,
            .blend_mode = .smoothstep,
        });
    }

    return MorphSequence{
        .frames = frames,
        .allocator = allocator,
    };
}

// ============================================================================
// Radial Basis Function Warping
// ============================================================================

pub const RBFWarp = struct {
    control_points: []ControlPoint,
    weights: []Point2D,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, control_points: []ControlPoint) !RBFWarp {
        const n = control_points.len;
        var weights = try allocator.alloc(Point2D, n);

        // Solve for RBF weights (simplified - real version would solve linear system)
        for (control_points, 0..) |cp, i| {
            weights[i] = Point2D{
                .x = cp.target.x - cp.source.x,
                .y = cp.target.y - cp.source.y,
            };
        }

        return RBFWarp{
            .control_points = control_points,
            .weights = weights,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RBFWarp) void {
        self.allocator.free(self.weights);
    }

    pub fn warp(self: *const RBFWarp, point: Point2D) Point2D {
        var result = point;

        for (self.control_points, 0..) |cp, i| {
            const dist = point.distance(cp.source);
            const rbf_value = rbfKernel(dist);

            result.x += self.weights[i].x * rbf_value;
            result.y += self.weights[i].y * rbf_value;
        }

        return result;
    }
};

fn rbfKernel(r: f32) f32 {
    // Thin plate spline kernel
    if (r < 0.0001) return 0.0;
    return r * r * @log(r);
}

/// Warps an image using Radial Basis Functions
pub fn warpImageRBF(
    allocator: std.mem.Allocator,
    img: *const Image,
    rbf: *const RBFWarp,
) !Image {
    var result = try Image.init(allocator, img.width, img.height, img.format);

    for (0..result.height) |y| {
        for (0..result.width) |x| {
            const target_point = Point2D{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
            };

            const source_point = rbf.warp(target_point);

            const color = sampleImageSafe(img, source_point.x, source_point.y);
            result.setPixel(@intCast(x), @intCast(y), color);
        }
    }

    return result;
}
