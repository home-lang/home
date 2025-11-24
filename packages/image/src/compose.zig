const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;
const blend_ops = @import("blend.zig");

// ============================================================================
// Layer System
// ============================================================================

/// Layer blend mode (re-export from blend)
pub const BlendMode = blend_ops.BlendMode;

/// Layer in a composition
pub const Layer = struct {
    name: []const u8,
    image: *Image,
    x: i32 = 0,
    y: i32 = 0,
    opacity: f32 = 1.0,
    blend_mode: BlendMode = .normal,
    visible: bool = true,
    locked: bool = false,
    mask: ?*Mask = null,
    clipping_mask: bool = false, // Clip to layer below
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, width: u32, height: u32) !*Layer {
        const layer = try allocator.create(Layer);
        const image = try allocator.create(Image);
        image.* = try Image.init(allocator, width, height, .rgba8);

        const name_copy = try allocator.dupe(u8, name);

        layer.* = Layer{
            .name = name_copy,
            .image = image,
            .allocator = allocator,
        };

        return layer;
    }

    pub fn initFromImage(allocator: std.mem.Allocator, name: []const u8, image: *Image) !*Layer {
        const layer = try allocator.create(Layer);
        const name_copy = try allocator.dupe(u8, name);

        layer.* = Layer{
            .name = name_copy,
            .image = image,
            .allocator = allocator,
        };

        return layer;
    }

    pub fn deinit(self: *Layer) void {
        self.image.deinit();
        self.allocator.destroy(self.image);
        self.allocator.free(@constCast(self.name));
        if (self.mask) |mask| {
            mask.deinit();
            self.allocator.destroy(mask);
        }
        self.allocator.destroy(self);
    }

    /// Create a mask for this layer
    pub fn createMask(self: *Layer, initial_value: u8) !void {
        if (self.mask != null) return;

        const mask = try self.allocator.create(Mask);
        mask.* = try Mask.init(self.allocator, self.image.width, self.image.height, initial_value);
        self.mask = mask;
    }

    /// Get effective opacity at a point (considering mask)
    pub fn getEffectiveOpacity(self: *const Layer, x: u32, y: u32) f32 {
        var opacity = self.opacity;

        if (self.mask) |mask| {
            const mask_value = mask.getValue(x, y);
            opacity *= @as(f32, @floatFromInt(mask_value)) / 255.0;
        }

        return opacity;
    }
};

// ============================================================================
// Mask
// ============================================================================

/// Mask types
pub const MaskType = enum {
    alpha, // Standard alpha mask
    luminosity, // Based on image brightness
    channel, // Based on specific channel
};

/// Layer mask
pub const Mask = struct {
    data: []u8,
    width: u32,
    height: u32,
    inverted: bool = false,
    feather: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, initial_value: u8) !Mask {
        const data = try allocator.alloc(u8, width * height);
        @memset(data, initial_value);

        return Mask{
            .data = data,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Mask) void {
        self.allocator.free(self.data);
    }

    pub fn getValue(self: *const Mask, x: u32, y: u32) u8 {
        if (x >= self.width or y >= self.height) return 0;
        var value = self.data[y * self.width + x];
        if (self.inverted) value = 255 - value;
        return value;
    }

    pub fn setValue(self: *Mask, x: u32, y: u32, value: u8) void {
        if (x >= self.width or y >= self.height) return;
        self.data[y * self.width + x] = value;
    }

    /// Create mask from image luminosity
    pub fn fromLuminosity(allocator: std.mem.Allocator, image: *const Image) !Mask {
        var mask = try Mask.init(allocator, image.width, image.height, 0);

        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const color = image.getPixel(x, y) orelse Color.BLACK;
                mask.setValue(x, y, color.toGrayscale());
            }
        }

        return mask;
    }

    /// Create mask from image alpha channel
    pub fn fromAlpha(allocator: std.mem.Allocator, image: *const Image) !Mask {
        var mask = try Mask.init(allocator, image.width, image.height, 0);

        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const color = image.getPixel(x, y) orelse Color.BLACK;
                mask.setValue(x, y, color.a);
            }
        }

        return mask;
    }

    /// Create mask from specific color channel
    pub fn fromChannel(allocator: std.mem.Allocator, image: *const Image, channel: enum { red, green, blue }) !Mask {
        var mask = try Mask.init(allocator, image.width, image.height, 0);

        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const color = image.getPixel(x, y) orelse Color.BLACK;
                const value = switch (channel) {
                    .red => color.r,
                    .green => color.g,
                    .blue => color.b,
                };
                mask.setValue(x, y, value);
            }
        }

        return mask;
    }

    /// Apply gaussian blur to mask (feathering)
    pub fn blur(self: *Mask, radius: u32, allocator: std.mem.Allocator) !void {
        if (radius == 0) return;

        const temp = try allocator.alloc(u8, self.data.len);
        defer allocator.free(temp);
        @memcpy(temp, self.data);

        const size = 2 * radius + 1;
        const sigma = @as(f32, @floatFromInt(radius)) / 3.0;

        // Generate 1D kernel
        var kernel = try allocator.alloc(f32, size);
        defer allocator.free(kernel);

        var sum: f32 = 0;
        for (0..size) |i| {
            const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
            kernel[i] = @exp(-(x * x) / (2 * sigma * sigma));
            sum += kernel[i];
        }
        for (kernel) |*k| k.* /= sum;

        // Horizontal pass
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                var val: f32 = 0;

                for (0..size) |k| {
                    const px_i = @as(i32, @intCast(x)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                    const px: u32 = @intCast(std.math.clamp(px_i, 0, @as(i32, @intCast(self.width)) - 1));
                    val += @as(f32, @floatFromInt(temp[y * self.width + px])) * kernel[k];
                }

                self.data[y * self.width + x] = @intFromFloat(std.math.clamp(val, 0, 255));
            }
        }

        @memcpy(temp, self.data);

        // Vertical pass
        y = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                var val: f32 = 0;

                for (0..size) |k| {
                    const py_i = @as(i32, @intCast(y)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                    const py: u32 = @intCast(std.math.clamp(py_i, 0, @as(i32, @intCast(self.height)) - 1));
                    val += @as(f32, @floatFromInt(temp[py * self.width + x])) * kernel[k];
                }

                self.data[y * self.width + x] = @intFromFloat(std.math.clamp(val, 0, 255));
            }
        }
    }

    /// Apply levels adjustment to mask
    pub fn levels(self: *Mask, black_point: u8, white_point: u8) void {
        const range: f32 = @floatFromInt(white_point - black_point);

        for (self.data) |*v| {
            if (v.* <= black_point) {
                v.* = 0;
            } else if (v.* >= white_point) {
                v.* = 255;
            } else {
                v.* = @intFromFloat((@as(f32, @floatFromInt(v.* - black_point)) / range) * 255.0);
            }
        }
    }
};

// ============================================================================
// Composition
// ============================================================================

/// Image composition (like a Photoshop document)
pub const Composition = struct {
    width: u32,
    height: u32,
    background_color: Color,
    layers: std.ArrayList(*Layer),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Composition {
        return Composition{
            .width = width,
            .height = height,
            .background_color = Color.WHITE,
            .layers = std.ArrayList(*Layer).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Composition) void {
        for (self.layers.items) |layer| {
            layer.deinit();
        }
        self.layers.deinit();
    }

    /// Add a new empty layer
    pub fn addLayer(self: *Composition, name: []const u8) !*Layer {
        const layer = try Layer.init(self.allocator, name, self.width, self.height);
        try self.layers.append(layer);
        return layer;
    }

    /// Add an existing image as a layer
    pub fn addImageAsLayer(self: *Composition, name: []const u8, image: *Image) !*Layer {
        const layer = try Layer.initFromImage(self.allocator, name, image);
        try self.layers.append(layer);
        return layer;
    }

    /// Insert layer at specific index
    pub fn insertLayer(self: *Composition, index: usize, layer: *Layer) !void {
        try self.layers.insert(index, layer);
    }

    /// Remove layer by index
    pub fn removeLayer(self: *Composition, index: usize) void {
        if (index >= self.layers.items.len) return;
        const layer = self.layers.orderedRemove(index);
        layer.deinit();
    }

    /// Move layer to new position
    pub fn moveLayer(self: *Composition, from: usize, to: usize) void {
        if (from >= self.layers.items.len or to >= self.layers.items.len) return;
        const layer = self.layers.orderedRemove(from);
        self.layers.insert(to, layer) catch {};
    }

    /// Get layer by name
    pub fn getLayerByName(self: *const Composition, name: []const u8) ?*Layer {
        for (self.layers.items) |layer| {
            if (std.mem.eql(u8, layer.name, name)) {
                return layer;
            }
        }
        return null;
    }

    /// Flatten composition to single image
    pub fn flatten(self: *const Composition) !Image {
        var result = try Image.init(self.allocator, self.width, self.height, .rgba8);

        // Fill with background
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                result.setPixel(x, y, self.background_color);
            }
        }

        // Composite layers from bottom to top
        var clipping_base: ?*Layer = null;

        for (self.layers.items) |layer| {
            if (!layer.visible) continue;

            // Handle clipping masks
            if (layer.clipping_mask) {
                if (clipping_base == null) continue; // No base to clip to
            } else {
                clipping_base = layer;
            }

            self.compositeLayer(&result, layer, clipping_base);
        }

        return result;
    }

    /// Composite a single layer onto the result
    fn compositeLayer(self: *const Composition, result: *Image, layer: *const Layer, clipping_base: ?*const Layer) void {
        const layer_left = @max(0, layer.x);
        const layer_top = @max(0, layer.y);
        const layer_right = @min(@as(i32, @intCast(self.width)), layer.x + @as(i32, @intCast(layer.image.width)));
        const layer_bottom = @min(@as(i32, @intCast(self.height)), layer.y + @as(i32, @intCast(layer.image.height)));

        if (layer_right <= layer_left or layer_bottom <= layer_top) return;

        var y: i32 = layer_top;
        while (y < layer_bottom) : (y += 1) {
            var x: i32 = layer_left;
            while (x < layer_right) : (x += 1) {
                const ux: u32 = @intCast(x);
                const uy: u32 = @intCast(y);
                const lx: u32 = @intCast(x - layer.x);
                const ly: u32 = @intCast(y - layer.y);

                const layer_color = layer.image.getPixel(lx, ly) orelse continue;
                if (layer_color.a == 0) continue;

                // Get effective opacity
                var opacity = layer.getEffectiveOpacity(lx, ly);

                // Apply clipping mask
                if (layer.clipping_mask) {
                    if (clipping_base) |base| {
                        const base_opacity = base.getEffectiveOpacity(lx, ly);
                        opacity *= base_opacity;
                    }
                }

                if (opacity <= 0) continue;

                const dst_color = result.getPixel(ux, uy) orelse Color.TRANSPARENT;

                // Apply blend mode
                const blended = blend_ops.blend(
                    .{ dst_color.r, dst_color.g, dst_color.b, dst_color.a },
                    .{ layer_color.r, layer_color.g, layer_color.b, layer_color.a },
                    layer.blend_mode,
                    opacity,
                );

                result.setPixel(ux, uy, Color{
                    .r = blended[0],
                    .g = blended[1],
                    .b = blended[2],
                    .a = blended[3],
                });
            }
        }
    }

    /// Merge visible layers
    pub fn mergeVisible(self: *Composition) !void {
        const flattened = try self.flatten();

        // Remove all layers
        for (self.layers.items) |layer| {
            layer.deinit();
        }
        self.layers.clearRetainingCapacity();

        // Add flattened as new layer
        const image = try self.allocator.create(Image);
        image.* = flattened;
        const layer = try Layer.initFromImage(self.allocator, "Merged", image);
        try self.layers.append(layer);
    }

    /// Merge layer down (merge with layer below)
    pub fn mergeDown(self: *Composition, index: usize) !void {
        if (index == 0 or index >= self.layers.items.len) return;

        const upper = self.layers.items[index];
        const lower = self.layers.items[index - 1];

        // Composite upper onto lower
        self.compositeLayer(lower.image, upper, null);

        // Remove upper layer
        _ = self.layers.orderedRemove(index);
        upper.deinit();
    }
};

// ============================================================================
// Clipping Paths
// ============================================================================

/// Point in a path
pub const PathPoint = struct {
    x: f32,
    y: f32,
    on_curve: bool = true, // false for control points
};

/// Path segment types
pub const PathSegment = enum {
    move_to,
    line_to,
    quad_to, // Quadratic bezier
    cubic_to, // Cubic bezier
    close,
};

/// Clipping path
pub const ClippingPath = struct {
    points: std.ArrayList(PathPoint),
    segments: std.ArrayList(PathSegment),
    closed: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ClippingPath {
        return ClippingPath{
            .points = std.ArrayList(PathPoint).init(allocator),
            .segments = std.ArrayList(PathSegment).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClippingPath) void {
        self.points.deinit();
        self.segments.deinit();
    }

    pub fn moveTo(self: *ClippingPath, x: f32, y: f32) !void {
        try self.points.append(.{ .x = x, .y = y });
        try self.segments.append(.move_to);
    }

    pub fn lineTo(self: *ClippingPath, x: f32, y: f32) !void {
        try self.points.append(.{ .x = x, .y = y });
        try self.segments.append(.line_to);
    }

    pub fn quadTo(self: *ClippingPath, cx: f32, cy: f32, x: f32, y: f32) !void {
        try self.points.append(.{ .x = cx, .y = cy, .on_curve = false });
        try self.points.append(.{ .x = x, .y = y });
        try self.segments.append(.quad_to);
    }

    pub fn cubicTo(self: *ClippingPath, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) !void {
        try self.points.append(.{ .x = c1x, .y = c1y, .on_curve = false });
        try self.points.append(.{ .x = c2x, .y = c2y, .on_curve = false });
        try self.points.append(.{ .x = x, .y = y });
        try self.segments.append(.cubic_to);
    }

    pub fn close(self: *ClippingPath) !void {
        try self.segments.append(.close);
        self.closed = true;
    }

    /// Check if point is inside path (using even-odd rule)
    pub fn contains(self: *const ClippingPath, x: f32, y: f32) bool {
        if (self.points.items.len < 3) return false;

        var crossings: i32 = 0;
        var point_idx: usize = 0;
        var start_x: f32 = 0;
        var start_y: f32 = 0;
        var prev_x: f32 = 0;
        var prev_y: f32 = 0;

        for (self.segments.items) |segment| {
            switch (segment) {
                .move_to => {
                    start_x = self.points.items[point_idx].x;
                    start_y = self.points.items[point_idx].y;
                    prev_x = start_x;
                    prev_y = start_y;
                    point_idx += 1;
                },
                .line_to => {
                    const curr_x = self.points.items[point_idx].x;
                    const curr_y = self.points.items[point_idx].y;

                    if (lineIntersectsRay(prev_x, prev_y, curr_x, curr_y, x, y)) {
                        crossings += 1;
                    }

                    prev_x = curr_x;
                    prev_y = curr_y;
                    point_idx += 1;
                },
                .quad_to => {
                    // Approximate with line for simplicity
                    const curr_x = self.points.items[point_idx + 1].x;
                    const curr_y = self.points.items[point_idx + 1].y;

                    if (lineIntersectsRay(prev_x, prev_y, curr_x, curr_y, x, y)) {
                        crossings += 1;
                    }

                    prev_x = curr_x;
                    prev_y = curr_y;
                    point_idx += 2;
                },
                .cubic_to => {
                    const curr_x = self.points.items[point_idx + 2].x;
                    const curr_y = self.points.items[point_idx + 2].y;

                    if (lineIntersectsRay(prev_x, prev_y, curr_x, curr_y, x, y)) {
                        crossings += 1;
                    }

                    prev_x = curr_x;
                    prev_y = curr_y;
                    point_idx += 3;
                },
                .close => {
                    if (lineIntersectsRay(prev_x, prev_y, start_x, start_y, x, y)) {
                        crossings += 1;
                    }
                    prev_x = start_x;
                    prev_y = start_y;
                },
            }
        }

        return @mod(crossings, 2) == 1;
    }

    /// Convert path to mask
    pub fn toMask(self: *const ClippingPath, width: u32, height: u32, allocator: std.mem.Allocator) !Mask {
        var mask = try Mask.init(allocator, width, height, 0);

        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                if (self.contains(@floatFromInt(x), @floatFromInt(y))) {
                    mask.setValue(x, y, 255);
                }
            }
        }

        return mask;
    }
};

fn lineIntersectsRay(x1: f32, y1: f32, x2: f32, y2: f32, px: f32, py: f32) bool {
    // Check if horizontal ray from (px, py) going right intersects line segment
    if ((y1 <= py and y2 > py) or (y2 <= py and y1 > py)) {
        const t = (py - y1) / (y2 - y1);
        const ix = x1 + t * (x2 - x1);
        if (ix > px) return true;
    }
    return false;
}

// ============================================================================
// Smart Object-like Compositing
// ============================================================================

/// Smart object that maintains original source
pub const SmartObject = struct {
    original: *Image,
    transformed: ?*Image,
    transform: Transform,
    allocator: std.mem.Allocator,

    pub const Transform = struct {
        scale_x: f32 = 1.0,
        scale_y: f32 = 1.0,
        rotation: f32 = 0, // radians
        translate_x: f32 = 0,
        translate_y: f32 = 0,
        flip_h: bool = false,
        flip_v: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, image: *Image) !SmartObject {
        return SmartObject{
            .original = image,
            .transformed = null,
            .transform = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SmartObject) void {
        if (self.transformed) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
    }

    /// Apply transforms and get result
    pub fn getTransformed(self: *SmartObject) !*Image {
        // If no transform needed, return original
        if (self.transform.scale_x == 1.0 and self.transform.scale_y == 1.0 and
            self.transform.rotation == 0 and !self.transform.flip_h and !self.transform.flip_v)
        {
            return self.original;
        }

        // Create or update transformed version
        if (self.transformed) |t| {
            t.deinit();
        } else {
            self.transformed = try self.allocator.create(Image);
        }

        // Calculate new dimensions
        const new_width: u32 = @intFromFloat(@as(f32, @floatFromInt(self.original.width)) * @abs(self.transform.scale_x));
        const new_height: u32 = @intFromFloat(@as(f32, @floatFromInt(self.original.height)) * @abs(self.transform.scale_y));

        self.transformed.?.* = try Image.init(self.allocator, new_width, new_height, self.original.format);

        // Apply transforms
        const center_x: f32 = @as(f32, @floatFromInt(new_width)) / 2.0;
        const center_y: f32 = @as(f32, @floatFromInt(new_height)) / 2.0;
        const orig_center_x: f32 = @as(f32, @floatFromInt(self.original.width)) / 2.0;
        const orig_center_y: f32 = @as(f32, @floatFromInt(self.original.height)) / 2.0;

        const cos_r = @cos(self.transform.rotation);
        const sin_r = @sin(self.transform.rotation);

        var y: u32 = 0;
        while (y < new_height) : (y += 1) {
            var x: u32 = 0;
            while (x < new_width) : (x += 1) {
                // Transform back to source coordinates
                var sx = @as(f32, @floatFromInt(x)) - center_x;
                var sy = @as(f32, @floatFromInt(y)) - center_y;

                // Apply flip
                if (self.transform.flip_h) sx = -sx;
                if (self.transform.flip_v) sy = -sy;

                // Apply inverse rotation
                const rx = sx * cos_r + sy * sin_r;
                const ry = -sx * sin_r + sy * cos_r;

                // Apply inverse scale
                const ux = rx / self.transform.scale_x + orig_center_x;
                const uy = ry / self.transform.scale_y + orig_center_y;

                // Sample with bilinear interpolation
                if (ux >= 0 and ux < @as(f32, @floatFromInt(self.original.width)) - 1 and
                    uy >= 0 and uy < @as(f32, @floatFromInt(self.original.height)) - 1)
                {
                    const color = bilinearSample(self.original, ux, uy);
                    self.transformed.?.setPixel(x, y, color);
                }
            }
        }

        return self.transformed.?;
    }

    /// Reset to original
    pub fn reset(self: *SmartObject) void {
        self.transform = .{};
        if (self.transformed) |t| {
            t.deinit();
            self.allocator.destroy(t);
            self.transformed = null;
        }
    }
};

fn bilinearSample(image: *const Image, fx: f32, fy: f32) Color {
    const x0: u32 = @intFromFloat(fx);
    const y0: u32 = @intFromFloat(fy);
    const x1 = @min(x0 + 1, image.width - 1);
    const y1 = @min(y0 + 1, image.height - 1);

    const fx_frac = fx - @as(f32, @floatFromInt(x0));
    const fy_frac = fy - @as(f32, @floatFromInt(y0));

    const c00 = image.getPixel(x0, y0) orelse Color.TRANSPARENT;
    const c10 = image.getPixel(x1, y0) orelse Color.TRANSPARENT;
    const c01 = image.getPixel(x0, y1) orelse Color.TRANSPARENT;
    const c11 = image.getPixel(x1, y1) orelse Color.TRANSPARENT;

    const lerp = struct {
        fn call(a: u8, b: u8, t: f32) u8 {
            return @intFromFloat(@as(f32, @floatFromInt(a)) * (1.0 - t) + @as(f32, @floatFromInt(b)) * t);
        }
    }.call;

    return Color{
        .r = lerp(lerp(c00.r, c10.r, fx_frac), lerp(c01.r, c11.r, fx_frac), fy_frac),
        .g = lerp(lerp(c00.g, c10.g, fx_frac), lerp(c01.g, c11.g, fx_frac), fy_frac),
        .b = lerp(lerp(c00.b, c10.b, fx_frac), lerp(c01.b, c11.b, fx_frac), fy_frac),
        .a = lerp(lerp(c00.a, c10.a, fx_frac), lerp(c01.a, c11.a, fx_frac), fy_frac),
    };
}

// ============================================================================
// Adjustment Layers
// ============================================================================

/// Adjustment layer types
pub const AdjustmentType = enum {
    brightness_contrast,
    levels,
    curves,
    hue_saturation,
    color_balance,
    invert,
    posterize,
    threshold,
    gradient_map,
};

/// Adjustment layer (non-destructive)
pub const AdjustmentLayer = struct {
    adjustment_type: AdjustmentType,
    params: AdjustmentParams,
    opacity: f32 = 1.0,
    mask: ?*Mask = null,

    pub const AdjustmentParams = union(AdjustmentType) {
        brightness_contrast: struct { brightness: i16 = 0, contrast: f32 = 1.0 },
        levels: struct { black: u8 = 0, white: u8 = 255, gamma: f32 = 1.0 },
        curves: struct { points: [256]u8 }, // Curve lookup table
        hue_saturation: struct { hue: i16 = 0, saturation: f32 = 1.0, lightness: f32 = 0 },
        color_balance: struct { shadows: [3]i16 = .{ 0, 0, 0 }, midtones: [3]i16 = .{ 0, 0, 0 }, highlights: [3]i16 = .{ 0, 0, 0 } },
        invert: void,
        posterize: struct { levels: u8 = 4 },
        threshold: struct { level: u8 = 128 },
        gradient_map: struct { colors: []Color },
    };

    /// Apply adjustment to a color
    pub fn apply(self: *const AdjustmentLayer, color: Color) Color {
        var result = color;

        switch (self.params) {
            .brightness_contrast => |p| {
                // Brightness
                result.r = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(result.r)) + @as(f32, @floatFromInt(p.brightness)), 0, 255));
                result.g = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(result.g)) + @as(f32, @floatFromInt(p.brightness)), 0, 255));
                result.b = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(result.b)) + @as(f32, @floatFromInt(p.brightness)), 0, 255));

                // Contrast
                const factor = p.contrast;
                result.r = @intFromFloat(std.math.clamp((@as(f32, @floatFromInt(result.r)) - 128) * factor + 128, 0, 255));
                result.g = @intFromFloat(std.math.clamp((@as(f32, @floatFromInt(result.g)) - 128) * factor + 128, 0, 255));
                result.b = @intFromFloat(std.math.clamp((@as(f32, @floatFromInt(result.b)) - 128) * factor + 128, 0, 255));
            },
            .levels => |p| {
                const range: f32 = @floatFromInt(p.white - p.black);
                const applyLevels = struct {
                    fn call(v: u8, black: u8, rng: f32, gamma: f32) u8 {
                        if (v <= black) return 0;
                        const normalized = @as(f32, @floatFromInt(v - black)) / rng;
                        const gamma_corrected = std.math.pow(f32, std.math.clamp(normalized, 0, 1), 1.0 / gamma);
                        return @intFromFloat(gamma_corrected * 255.0);
                    }
                }.call;

                result.r = applyLevels(result.r, p.black, range, p.gamma);
                result.g = applyLevels(result.g, p.black, range, p.gamma);
                result.b = applyLevels(result.b, p.black, range, p.gamma);
            },
            .curves => |p| {
                result.r = p.points[result.r];
                result.g = p.points[result.g];
                result.b = p.points[result.b];
            },
            .invert => {
                result.r = 255 - result.r;
                result.g = 255 - result.g;
                result.b = 255 - result.b;
            },
            .posterize => |p| {
                const levels_f: f32 = @floatFromInt(p.levels);
                result.r = @intFromFloat(@floor(@as(f32, @floatFromInt(result.r)) / 255.0 * levels_f) / levels_f * 255.0);
                result.g = @intFromFloat(@floor(@as(f32, @floatFromInt(result.g)) / 255.0 * levels_f) / levels_f * 255.0);
                result.b = @intFromFloat(@floor(@as(f32, @floatFromInt(result.b)) / 255.0 * levels_f) / levels_f * 255.0);
            },
            .threshold => |p| {
                const lum = result.toGrayscale();
                const val: u8 = if (lum >= p.level) 255 else 0;
                result.r = val;
                result.g = val;
                result.b = val;
            },
            else => {},
        }

        return result;
    }
};

/// Create common shapes as clipping paths
pub const Shapes = struct {
    pub fn rectangle(x: f32, y: f32, width: f32, height: f32, allocator: std.mem.Allocator) !ClippingPath {
        var path = ClippingPath.init(allocator);
        try path.moveTo(x, y);
        try path.lineTo(x + width, y);
        try path.lineTo(x + width, y + height);
        try path.lineTo(x, y + height);
        try path.close();
        return path;
    }

    pub fn ellipse(cx: f32, cy: f32, rx: f32, ry: f32, segments: u32, allocator: std.mem.Allocator) !ClippingPath {
        var path = ClippingPath.init(allocator);
        const step = 2.0 * std.math.pi / @as(f32, @floatFromInt(segments));

        try path.moveTo(cx + rx, cy);

        for (1..segments) |i| {
            const angle = @as(f32, @floatFromInt(i)) * step;
            try path.lineTo(cx + rx * @cos(angle), cy + ry * @sin(angle));
        }

        try path.close();
        return path;
    }

    pub fn roundedRectangle(x: f32, y: f32, width: f32, height: f32, radius: f32, allocator: std.mem.Allocator) !ClippingPath {
        var path = ClippingPath.init(allocator);
        const r = @min(radius, @min(width, height) / 2);

        try path.moveTo(x + r, y);
        try path.lineTo(x + width - r, y);
        try path.quadTo(x + width, y, x + width, y + r);
        try path.lineTo(x + width, y + height - r);
        try path.quadTo(x + width, y + height, x + width - r, y + height);
        try path.lineTo(x + r, y + height);
        try path.quadTo(x, y + height, x, y + height - r);
        try path.lineTo(x, y + r);
        try path.quadTo(x, y, x + r, y);
        try path.close();

        return path;
    }
};
