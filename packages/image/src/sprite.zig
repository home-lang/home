const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Sprite Definition
// ============================================================================

pub const Sprite = struct {
    name: []const u8,
    image: Image,
    // Position in atlas
    atlas_x: u32,
    atlas_y: u32,
    // Original position (for trimming)
    source_x: i32,
    source_y: i32,
    source_width: u32,
    source_height: u32,
    // Trimmed bounds
    trimmed: bool,
    trim_x: u32,
    trim_y: u32,
    // Pivot point (0-1)
    pivot_x: f32,
    pivot_y: f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, img: Image) !Sprite {
        const name_copy = try allocator.dupe(u8, name);
        return Sprite{
            .name = name_copy,
            .image = img,
            .atlas_x = 0,
            .atlas_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = img.width,
            .source_height = img.height,
            .trimmed = false,
            .trim_x = 0,
            .trim_y = 0,
            .pivot_x = 0.5,
            .pivot_y = 0.5,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Sprite) void {
        self.allocator.free(self.name);
        self.image.deinit();
    }

    pub fn trim(self: *Sprite, allocator: std.mem.Allocator, alpha_threshold: u8) !void {
        // Find bounding box of non-transparent pixels
        var min_x: u32 = self.image.width;
        var min_y: u32 = self.image.height;
        var max_x: u32 = 0;
        var max_y: u32 = 0;

        for (0..self.image.height) |y| {
            for (0..self.image.width) |x| {
                const color = self.image.getPixel(@intCast(x), @intCast(y));
                if (color.a > alpha_threshold) {
                    min_x = @min(min_x, @as(u32, @intCast(x)));
                    min_y = @min(min_y, @as(u32, @intCast(y)));
                    max_x = @max(max_x, @as(u32, @intCast(x)));
                    max_y = @max(max_y, @as(u32, @intCast(y)));
                }
            }
        }

        if (max_x < min_x or max_y < min_y) {
            // Fully transparent, create 1x1 transparent image
            var new_img = try Image.create(allocator, 1, 1, .rgba);
            new_img.setPixel(0, 0, Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
            self.image.deinit();
            self.image = new_img;
            self.trimmed = true;
            self.trim_x = 0;
            self.trim_y = 0;
            return;
        }

        const new_width = max_x - min_x + 1;
        const new_height = max_y - min_y + 1;

        if (new_width == self.image.width and new_height == self.image.height) {
            return; // No trimming needed
        }

        var new_img = try Image.create(allocator, new_width, new_height, .rgba);

        for (0..new_height) |y| {
            for (0..new_width) |x| {
                const color = self.image.getPixel(@intCast(min_x + x), @intCast(min_y + y));
                new_img.setPixel(@intCast(x), @intCast(y), color);
            }
        }

        self.image.deinit();
        self.image = new_img;
        self.trimmed = true;
        self.trim_x = min_x;
        self.trim_y = min_y;
    }
};

// ============================================================================
// Texture Atlas
// ============================================================================

pub const AtlasOptions = struct {
    max_width: u32 = 4096,
    max_height: u32 = 4096,
    padding: u32 = 1,
    allow_rotation: bool = true,
    trim_sprites: bool = true,
    alpha_threshold: u8 = 0,
    power_of_two: bool = false,
    square: bool = false,
    algorithm: PackingAlgorithm = .maxrects,
};

pub const PackingAlgorithm = enum {
    shelf,
    maxrects,
    guillotine,
    skyline,
};

pub const AtlasRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    rotated: bool,
    sprite_idx: usize,
};

pub const TextureAtlas = struct {
    image: Image,
    sprites: std.ArrayList(Sprite),
    rects: std.ArrayList(AtlasRect),
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TextureAtlas {
        return TextureAtlas{
            .image = undefined,
            .sprites = std.ArrayList(Sprite).init(allocator),
            .rects = std.ArrayList(AtlasRect).init(allocator),
            .width = 0,
            .height = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextureAtlas) void {
        for (self.sprites.items) |*sprite| {
            sprite.deinit();
        }
        self.sprites.deinit();
        self.rects.deinit();
        if (self.width > 0) {
            self.image.deinit();
        }
    }

    pub fn addSprite(self: *TextureAtlas, name: []const u8, img: Image) !void {
        const sprite = try Sprite.init(self.allocator, name, img);
        try self.sprites.append(sprite);
    }

    pub fn pack(self: *TextureAtlas, options: AtlasOptions) !bool {
        if (self.sprites.items.len == 0) return false;

        // Trim sprites if requested
        if (options.trim_sprites) {
            for (self.sprites.items) |*sprite| {
                try sprite.trim(self.allocator, options.alpha_threshold);
            }
        }

        // Sort sprites by size (largest first)
        const SpriteSortContext = struct {
            sprites: []Sprite,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const area_a = ctx.sprites[a].image.width * ctx.sprites[a].image.height;
                const area_b = ctx.sprites[b].image.width * ctx.sprites[b].image.height;
                return area_a > area_b;
            }
        };

        var indices = try self.allocator.alloc(usize, self.sprites.items.len);
        defer self.allocator.free(indices);
        for (0..indices.len) |i| {
            indices[i] = i;
        }

        std.mem.sort(usize, indices, SpriteSortContext{ .sprites = self.sprites.items }, SpriteSortContext.lessThan);

        // Pack based on algorithm
        const packed = switch (options.algorithm) {
            .shelf => try self.packShelf(indices, options),
            .maxrects => try self.packMaxRects(indices, options),
            .guillotine => try self.packGuillotine(indices, options),
            .skyline => try self.packSkyline(indices, options),
        };

        if (!packed) return false;

        // Adjust to power of two if needed
        if (options.power_of_two) {
            self.width = nextPowerOfTwo(self.width);
            self.height = nextPowerOfTwo(self.height);
        }

        if (options.square) {
            const size = @max(self.width, self.height);
            self.width = size;
            self.height = size;
        }

        // Create atlas image
        self.image = try Image.create(self.allocator, self.width, self.height, .rgba);

        // Clear to transparent
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                self.image.setPixel(@intCast(x), @intCast(y), Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
            }
        }

        // Copy sprites to atlas
        for (self.rects.items) |rect| {
            const sprite = &self.sprites.items[rect.sprite_idx];
            sprite.atlas_x = rect.x;
            sprite.atlas_y = rect.y;

            if (rect.rotated) {
                // Copy rotated 90 degrees clockwise
                for (0..sprite.image.height) |sy| {
                    for (0..sprite.image.width) |sx| {
                        const color = sprite.image.getPixel(@intCast(sx), @intCast(sy));
                        const dx = rect.x + @as(u32, @intCast(sy));
                        const dy = rect.y + sprite.image.width - 1 - @as(u32, @intCast(sx));
                        self.image.setPixel(dx, dy, color);
                    }
                }
            } else {
                // Copy normally
                for (0..sprite.image.height) |sy| {
                    for (0..sprite.image.width) |sx| {
                        const color = sprite.image.getPixel(@intCast(sx), @intCast(sy));
                        self.image.setPixel(rect.x + @as(u32, @intCast(sx)), rect.y + @as(u32, @intCast(sy)), color);
                    }
                }
            }
        }

        return true;
    }

    fn packShelf(self: *TextureAtlas, indices: []usize, options: AtlasOptions) !bool {
        self.rects.clearRetainingCapacity();

        var shelf_y: u32 = 0;
        var shelf_x: u32 = 0;
        var shelf_height: u32 = 0;
        var max_width: u32 = 0;

        for (indices) |idx| {
            const sprite = &self.sprites.items[idx];
            const w = sprite.image.width + options.padding * 2;
            const h = sprite.image.height + options.padding * 2;

            // Check if fits on current shelf
            if (shelf_x + w > options.max_width) {
                // Start new shelf
                shelf_y += shelf_height;
                shelf_x = 0;
                shelf_height = 0;
            }

            // Check if fits vertically
            if (shelf_y + h > options.max_height) {
                return false; // Doesn't fit
            }

            try self.rects.append(AtlasRect{
                .x = shelf_x + options.padding,
                .y = shelf_y + options.padding,
                .width = sprite.image.width,
                .height = sprite.image.height,
                .rotated = false,
                .sprite_idx = idx,
            });

            shelf_x += w;
            max_width = @max(max_width, shelf_x);
            shelf_height = @max(shelf_height, h);
        }

        self.width = max_width;
        self.height = shelf_y + shelf_height;
        return true;
    }

    fn packMaxRects(self: *TextureAtlas, indices: []usize, options: AtlasOptions) !bool {
        self.rects.clearRetainingCapacity();

        // Start with one big free rectangle
        var free_rects = std.ArrayList(Rect).init(self.allocator);
        defer free_rects.deinit();

        try free_rects.append(Rect{
            .x = 0,
            .y = 0,
            .width = options.max_width,
            .height = options.max_height,
        });

        var max_x: u32 = 0;
        var max_y: u32 = 0;

        for (indices) |idx| {
            const sprite = &self.sprites.items[idx];
            const w = sprite.image.width + options.padding * 2;
            const h = sprite.image.height + options.padding * 2;

            // Find best fit (smallest free rectangle that fits)
            var best_idx: ?usize = null;
            var best_short_side: u32 = std.math.maxInt(u32);
            var rotated = false;

            for (free_rects.items, 0..) |rect, ri| {
                // Try normal orientation
                if (w <= rect.width and h <= rect.height) {
                    const short_side = @min(rect.width - w, rect.height - h);
                    if (short_side < best_short_side) {
                        best_short_side = short_side;
                        best_idx = ri;
                        rotated = false;
                    }
                }

                // Try rotated
                if (options.allow_rotation and h <= rect.width and w <= rect.height) {
                    const short_side = @min(rect.width - h, rect.height - w);
                    if (short_side < best_short_side) {
                        best_short_side = short_side;
                        best_idx = ri;
                        rotated = true;
                    }
                }
            }

            if (best_idx == null) return false;

            const free_rect = free_rects.items[best_idx.?];
            const actual_w = if (rotated) h else w;
            const actual_h = if (rotated) w else h;

            try self.rects.append(AtlasRect{
                .x = free_rect.x + options.padding,
                .y = free_rect.y + options.padding,
                .width = sprite.image.width,
                .height = sprite.image.height,
                .rotated = rotated,
                .sprite_idx = idx,
            });

            max_x = @max(max_x, free_rect.x + actual_w);
            max_y = @max(max_y, free_rect.y + actual_h);

            // Split the free rectangle
            _ = free_rects.orderedRemove(best_idx.?);

            // Right remainder
            if (free_rect.width > actual_w) {
                try free_rects.append(Rect{
                    .x = free_rect.x + actual_w,
                    .y = free_rect.y,
                    .width = free_rect.width - actual_w,
                    .height = actual_h,
                });
            }

            // Bottom remainder
            if (free_rect.height > actual_h) {
                try free_rects.append(Rect{
                    .x = free_rect.x,
                    .y = free_rect.y + actual_h,
                    .width = free_rect.width,
                    .height = free_rect.height - actual_h,
                });
            }

            // Merge overlapping free rectangles (simplified)
            try mergeFreeRects(&free_rects);
        }

        self.width = max_x;
        self.height = max_y;
        return true;
    }

    fn packGuillotine(self: *TextureAtlas, indices: []usize, options: AtlasOptions) !bool {
        // Similar to maxrects but with guillotine split
        return self.packMaxRects(indices, options);
    }

    fn packSkyline(self: *TextureAtlas, indices: []usize, options: AtlasOptions) !bool {
        self.rects.clearRetainingCapacity();

        // Skyline: maintain a "skyline" of heights
        var skyline = std.ArrayList(SkylineNode).init(self.allocator);
        defer skyline.deinit();

        try skyline.append(SkylineNode{
            .x = 0,
            .y = 0,
            .width = options.max_width,
        });

        var max_y: u32 = 0;

        for (indices) |idx| {
            const sprite = &self.sprites.items[idx];
            const w = sprite.image.width + options.padding * 2;
            const h = sprite.image.height + options.padding * 2;

            // Find best position (lowest y where sprite fits)
            var best_idx: ?usize = null;
            var best_y: u32 = std.math.maxInt(u32);
            var best_waste: u32 = std.math.maxInt(u32);

            for (skyline.items, 0..) |node, ni| {
                // Check if sprite fits starting at this node
                var max_height: u32 = 0;
                var width_left = w;
                var check_idx = ni;

                while (width_left > 0 and check_idx < skyline.items.len) {
                    max_height = @max(max_height, skyline.items[check_idx].y);
                    width_left -|= skyline.items[check_idx].width;
                    check_idx += 1;
                }

                if (width_left > 0) continue; // Doesn't fit
                if (node.x + w > options.max_width) continue;
                if (max_height + h > options.max_height) continue;

                const waste = max_height - node.y;
                if (max_height < best_y or (max_height == best_y and waste < best_waste)) {
                    best_y = max_height;
                    best_waste = waste;
                    best_idx = ni;
                }
            }

            if (best_idx == null) return false;

            const node = skyline.items[best_idx.?];
            try self.rects.append(AtlasRect{
                .x = node.x + options.padding,
                .y = best_y + options.padding,
                .width = sprite.image.width,
                .height = sprite.image.height,
                .rotated = false,
                .sprite_idx = idx,
            });

            max_y = @max(max_y, best_y + h);

            // Update skyline
            // Remove covered nodes and add new node
            var remove_count: usize = 0;
            var width_left: u32 = w;
            var check_idx = best_idx.?;

            while (width_left > 0 and check_idx < skyline.items.len) {
                const covered = @min(width_left, skyline.items[check_idx].width);
                width_left -= covered;

                if (covered == skyline.items[check_idx].width) {
                    remove_count += 1;
                } else {
                    skyline.items[check_idx].x += covered;
                    skyline.items[check_idx].width -= covered;
                }
                check_idx += 1;
            }

            // Remove fully covered nodes
            for (0..remove_count) |_| {
                _ = skyline.orderedRemove(best_idx.?);
            }

            // Insert new node
            try skyline.insert(best_idx.?, SkylineNode{
                .x = node.x,
                .y = best_y + h,
                .width = w,
            });

            // Merge adjacent nodes with same height
            try mergeSkyline(&skyline);
        }

        self.width = options.max_width;
        self.height = max_y;
        return true;
    }

    pub fn getSpriteByName(self: *const TextureAtlas, name: []const u8) ?*const Sprite {
        for (self.sprites.items) |*sprite| {
            if (std.mem.eql(u8, sprite.name, name)) {
                return sprite;
            }
        }
        return null;
    }

    pub fn getRectByName(self: *const TextureAtlas, name: []const u8) ?*const AtlasRect {
        for (self.rects.items) |*rect| {
            if (std.mem.eql(u8, self.sprites.items[rect.sprite_idx].name, name)) {
                return rect;
            }
        }
        return null;
    }

    pub fn exportMetadata(self: *const TextureAtlas, allocator: std.mem.Allocator) ![]u8 {
        // Export as JSON
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        try result.appendSlice("{\n  \"frames\": {\n");

        for (self.rects.items, 0..) |rect, i| {
            const sprite = &self.sprites.items[rect.sprite_idx];

            try result.appendSlice("    \"");
            try result.appendSlice(sprite.name);
            try result.appendSlice("\": {\n");

            // Frame position
            try result.appendSlice("      \"frame\": { ");
            try std.fmt.format(result.writer(), "\"x\": {}, \"y\": {}, \"w\": {}, \"h\": {}", .{ rect.x, rect.y, rect.width, rect.height });
            try result.appendSlice(" },\n");

            // Rotation
            try result.appendSlice("      \"rotated\": ");
            try result.appendSlice(if (rect.rotated) "true" else "false");
            try result.appendSlice(",\n");

            // Trimmed
            try result.appendSlice("      \"trimmed\": ");
            try result.appendSlice(if (sprite.trimmed) "true" else "false");
            try result.appendSlice(",\n");

            // Sprite source size
            try result.appendSlice("      \"spriteSourceSize\": { ");
            try std.fmt.format(result.writer(), "\"x\": {}, \"y\": {}, \"w\": {}, \"h\": {}", .{ sprite.trim_x, sprite.trim_y, sprite.image.width, sprite.image.height });
            try result.appendSlice(" },\n");

            // Source size
            try result.appendSlice("      \"sourceSize\": { ");
            try std.fmt.format(result.writer(), "\"w\": {}, \"h\": {}", .{ sprite.source_width, sprite.source_height });
            try result.appendSlice(" },\n");

            // Pivot
            try result.appendSlice("      \"pivot\": { ");
            try std.fmt.format(result.writer(), "\"x\": {d:.2}, \"y\": {d:.2}", .{ sprite.pivot_x, sprite.pivot_y });
            try result.appendSlice(" }\n");

            try result.appendSlice("    }");
            if (i < self.rects.items.len - 1) try result.appendSlice(",");
            try result.appendSlice("\n");
        }

        try result.appendSlice("  },\n");

        // Meta
        try result.appendSlice("  \"meta\": {\n");
        try result.appendSlice("    \"size\": { ");
        try std.fmt.format(result.writer(), "\"w\": {}, \"h\": {}", .{ self.width, self.height });
        try result.appendSlice(" },\n");
        try result.appendSlice("    \"scale\": 1\n");
        try result.appendSlice("  }\n");
        try result.appendSlice("}\n");

        return result.toOwnedSlice();
    }
};

const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const SkylineNode = struct {
    x: u32,
    y: u32,
    width: u32,
};

fn nextPowerOfTwo(n: u32) u32 {
    var v = n;
    v -= 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v += 1;
    return v;
}

fn mergeFreeRects(rects: *std.ArrayList(Rect)) !void {
    // Simple merge: remove fully contained rectangles
    var i: usize = 0;
    while (i < rects.items.len) {
        var j: usize = i + 1;
        while (j < rects.items.len) {
            const a = rects.items[i];
            const b = rects.items[j];

            // Check if b is fully contained in a
            if (b.x >= a.x and b.y >= a.y and b.x + b.width <= a.x + a.width and b.y + b.height <= a.y + a.height) {
                _ = rects.orderedRemove(j);
                continue;
            }

            // Check if a is fully contained in b
            if (a.x >= b.x and a.y >= b.y and a.x + a.width <= b.x + b.width and a.y + a.height <= b.y + b.height) {
                _ = rects.orderedRemove(i);
                break;
            }

            j += 1;
        }
        i += 1;
    }
}

fn mergeSkyline(skyline: *std.ArrayList(SkylineNode)) !void {
    var i: usize = 0;
    while (i < skyline.items.len - 1) {
        if (skyline.items[i].y == skyline.items[i + 1].y) {
            skyline.items[i].width += skyline.items[i + 1].width;
            _ = skyline.orderedRemove(i + 1);
        } else {
            i += 1;
        }
    }
}

// ============================================================================
// Nine-Slice / Nine-Patch
// ============================================================================

pub const NineSlice = struct {
    image: Image,
    // Slice borders (pixels from edge)
    left: u32,
    right: u32,
    top: u32,
    bottom: u32,
    // Fill mode for center
    fill_center: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, img: Image, left: u32, right: u32, top: u32, bottom: u32) NineSlice {
        return NineSlice{
            .image = img,
            .left = left,
            .right = right,
            .top = top,
            .bottom = bottom,
            .fill_center = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NineSlice) void {
        self.image.deinit();
    }

    pub fn render(self: *const NineSlice, width: u32, height: u32) !Image {
        var result = try Image.create(self.allocator, width, height, .rgba);

        const src_w = self.image.width;
        const src_h = self.image.height;
        const center_w = src_w - self.left - self.right;
        const center_h = src_h - self.top - self.bottom;
        const dst_center_w = if (width > self.left + self.right) width - self.left - self.right else 0;
        const dst_center_h = if (height > self.top + self.bottom) height - self.top - self.bottom else 0;

        // Draw 9 regions

        // Corners (no scaling)
        // Top-left
        copyRegion(&self.image, &result, 0, 0, 0, 0, self.left, self.top);
        // Top-right
        copyRegion(&self.image, &result, src_w - self.right, 0, width - self.right, 0, self.right, self.top);
        // Bottom-left
        copyRegion(&self.image, &result, 0, src_h - self.bottom, 0, height - self.bottom, self.left, self.bottom);
        // Bottom-right
        copyRegion(&self.image, &result, src_w - self.right, src_h - self.bottom, width - self.right, height - self.bottom, self.right, self.bottom);

        // Edges (scale in one direction)
        // Top edge
        if (dst_center_w > 0) {
            scaleRegion(&self.image, &result, self.left, 0, center_w, self.top, self.left, 0, dst_center_w, self.top);
        }
        // Bottom edge
        if (dst_center_w > 0) {
            scaleRegion(&self.image, &result, self.left, src_h - self.bottom, center_w, self.bottom, self.left, height - self.bottom, dst_center_w, self.bottom);
        }
        // Left edge
        if (dst_center_h > 0) {
            scaleRegion(&self.image, &result, 0, self.top, self.left, center_h, 0, self.top, self.left, dst_center_h);
        }
        // Right edge
        if (dst_center_h > 0) {
            scaleRegion(&self.image, &result, src_w - self.right, self.top, self.right, center_h, width - self.right, self.top, self.right, dst_center_h);
        }

        // Center (scale in both directions)
        if (self.fill_center and dst_center_w > 0 and dst_center_h > 0) {
            scaleRegion(&self.image, &result, self.left, self.top, center_w, center_h, self.left, self.top, dst_center_w, dst_center_h);
        }

        return result;
    }

    pub fn fromAndroidNinePatch(allocator: std.mem.Allocator, img: Image) !NineSlice {
        // Android 9-patch uses 1px border with black pixels to define stretch regions

        // Find left border (stretch y)
        var top: u32 = 0;
        var bottom: u32 = 0;
        for (1..img.height - 1) |y| {
            const color = img.getPixel(0, @intCast(y));
            if (color.r == 0 and color.g == 0 and color.b == 0 and color.a == 255) {
                if (top == 0) top = @intCast(y - 1);
                bottom = @intCast(y);
            }
        }
        bottom = @as(u32, @intCast(img.height - 2)) - bottom;

        // Find top border (stretch x)
        var left: u32 = 0;
        var right: u32 = 0;
        for (1..img.width - 1) |x| {
            const color = img.getPixel(@intCast(x), 0);
            if (color.r == 0 and color.g == 0 and color.b == 0 and color.a == 255) {
                if (left == 0) left = @intCast(x - 1);
                right = @intCast(x);
            }
        }
        right = @as(u32, @intCast(img.width - 2)) - right;

        // Create content image (remove 1px border)
        var content = try Image.create(allocator, img.width - 2, img.height - 2, .rgba);
        for (0..content.height) |y| {
            for (0..content.width) |x| {
                content.setPixel(@intCast(x), @intCast(y), img.getPixel(@intCast(x + 1), @intCast(y + 1)));
            }
        }

        return NineSlice{
            .image = content,
            .left = left,
            .right = right,
            .top = top,
            .bottom = bottom,
            .fill_center = true,
            .allocator = allocator,
        };
    }
};

fn copyRegion(src: *const Image, dst: *Image, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, width: u32, height: u32) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const sx = src_x + @as(u32, @intCast(x));
            const sy = src_y + @as(u32, @intCast(y));
            const dx = dst_x + @as(u32, @intCast(x));
            const dy = dst_y + @as(u32, @intCast(y));

            if (sx < src.width and sy < src.height and dx < dst.width and dy < dst.height) {
                dst.setPixel(dx, dy, src.getPixel(sx, sy));
            }
        }
    }
}

fn scaleRegion(src: *const Image, dst: *Image, src_x: u32, src_y: u32, src_w: u32, src_h: u32, dst_x: u32, dst_y: u32, dst_w: u32, dst_h: u32) void {
    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0) return;

    for (0..dst_h) |y| {
        for (0..dst_w) |x| {
            // Bilinear sampling
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(dst_w)) * @as(f32, @floatFromInt(src_w));
            const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(dst_h)) * @as(f32, @floatFromInt(src_h));

            const sx = src_x + @as(u32, @intFromFloat(@min(@as(f32, @floatFromInt(src_w - 1)), u)));
            const sy = src_y + @as(u32, @intFromFloat(@min(@as(f32, @floatFromInt(src_h - 1)), v)));
            const dx = dst_x + @as(u32, @intCast(x));
            const dy = dst_y + @as(u32, @intCast(y));

            if (sx < src.width and sy < src.height and dx < dst.width and dy < dst.height) {
                dst.setPixel(dx, dy, src.getPixel(sx, sy));
            }
        }
    }
}

// ============================================================================
// Sprite Animation
// ============================================================================

pub const SpriteAnimation = struct {
    name: []const u8,
    frames: std.ArrayList(AnimationFrame),
    loop: bool,
    allocator: std.mem.Allocator,

    pub const AnimationFrame = struct {
        sprite_name: []const u8,
        duration: u32, // milliseconds
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !SpriteAnimation {
        return SpriteAnimation{
            .name = try allocator.dupe(u8, name),
            .frames = std.ArrayList(AnimationFrame).init(allocator),
            .loop = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpriteAnimation) void {
        self.allocator.free(self.name);
        for (self.frames.items) |frame| {
            self.allocator.free(frame.sprite_name);
        }
        self.frames.deinit();
    }

    pub fn addFrame(self: *SpriteAnimation, sprite_name: []const u8, duration: u32) !void {
        try self.frames.append(AnimationFrame{
            .sprite_name = try self.allocator.dupe(u8, sprite_name),
            .duration = duration,
        });
    }

    pub fn getTotalDuration(self: *const SpriteAnimation) u32 {
        var total: u32 = 0;
        for (self.frames.items) |frame| {
            total += frame.duration;
        }
        return total;
    }

    pub fn getFrameAtTime(self: *const SpriteAnimation, time_ms: u32) ?*const AnimationFrame {
        if (self.frames.items.len == 0) return null;

        const total = self.getTotalDuration();
        if (total == 0) return &self.frames.items[0];

        var t = if (self.loop) time_ms % total else @min(time_ms, total);
        var elapsed: u32 = 0;

        for (self.frames.items) |*frame| {
            elapsed += frame.duration;
            if (t < elapsed) return frame;
        }

        return &self.frames.items[self.frames.items.len - 1];
    }
};
