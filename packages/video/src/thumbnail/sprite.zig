// Home Video Library - Thumbnail Sprite Sheets
// Generate sprite sheets/contact sheets from multiple thumbnails

const std = @import("std");
const thumbnail = @import("thumbnail.zig");

pub const ThumbnailFormat = thumbnail.ThumbnailFormat;

// ============================================================================
// Sprite Sheet Layout
// ============================================================================

pub const SpriteLayout = enum {
    grid, // Regular grid
    horizontal, // Single row
    vertical, // Single column
    compact, // Pack as tightly as possible
};

pub const SpriteConfig = struct {
    layout: SpriteLayout = .grid,
    columns: ?u32 = null, // Auto-calculate if null
    rows: ?u32 = null, // Auto-calculate if null
    thumbnail_width: u32 = 160,
    thumbnail_height: u32 = 90,
    spacing: u32 = 4, // Pixels between thumbnails
    padding: u32 = 8, // Border padding
    background_color: [3]u8 = .{ 0, 0, 0 }, // RGB
    show_timestamps: bool = true,
    timestamp_color: [3]u8 = .{ 255, 255, 255 },
    format: ThumbnailFormat = .jpeg,
    quality: u8 = 85,
};

// ============================================================================
// Sprite Sheet Generator
// ============================================================================

pub const SpriteSheet = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGB24
    config: SpriteConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SpriteConfig, thumbnail_count: u32) !Self {
        // Calculate grid dimensions
        var cols = config.columns orelse blk: {
            const sqrt = std.math.sqrt(@as(f32, @floatFromInt(thumbnail_count)));
            break :blk @as(u32, @intFromFloat(@ceil(sqrt)));
        };

        var rows = config.rows orelse blk: {
            break :blk (thumbnail_count + cols - 1) / cols;
        };

        // Override for specific layouts
        switch (config.layout) {
            .horizontal => {
                cols = thumbnail_count;
                rows = 1;
            },
            .vertical => {
                cols = 1;
                rows = thumbnail_count;
            },
            else => {},
        }

        const width = config.padding * 2 +
                     cols * config.thumbnail_width +
                     (cols - 1) * config.spacing;

        const height = config.padding * 2 +
                      rows * config.thumbnail_height +
                      (rows - 1) * config.spacing;

        const pixels = try allocator.alloc(u8, width * height * 3);

        // Fill with background color
        var i: usize = 0;
        while (i < width * height) : (i += 1) {
            pixels[i * 3] = config.background_color[0];
            pixels[i * 3 + 1] = config.background_color[1];
            pixels[i * 3 + 2] = config.background_color[2];
        }

        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pixels);
    }

    /// Add thumbnail at grid position
    pub fn addThumbnail(
        self: *Self,
        thumb_pixels: []const u8,
        thumb_width: u32,
        thumb_height: u32,
        index: u32,
    ) void {
        const cols = if (self.config.layout == .horizontal)
            index + 1
        else if (self.config.columns) |c| c
        else blk: {
            const sqrt = std.math.sqrt(@as(f32, @floatFromInt(index + 1)));
            break :blk @as(u32, @intFromFloat(@ceil(sqrt)));
        };

        const col = index % cols;
        const row = index / cols;

        const x_offset = self.config.padding + col * (self.config.thumbnail_width + self.config.spacing);
        const y_offset = self.config.padding + row * (self.config.thumbnail_height + self.config.spacing);

        // Copy thumbnail pixels
        var y: u32 = 0;
        while (y < thumb_height and y < self.config.thumbnail_height) : (y += 1) {
            var x: u32 = 0;
            while (x < thumb_width and x < self.config.thumbnail_width) : (x += 1) {
                const src_idx = (y * thumb_width + x) * 3;
                const dst_idx = ((y_offset + y) * self.width + (x_offset + x)) * 3;

                if (dst_idx + 2 < self.pixels.len and src_idx + 2 < thumb_pixels.len) {
                    self.pixels[dst_idx] = thumb_pixels[src_idx];
                    self.pixels[dst_idx + 1] = thumb_pixels[src_idx + 1];
                    self.pixels[dst_idx + 2] = thumb_pixels[src_idx + 2];
                }
            }
        }
    }

    /// Draw timestamp text (simplified, uses basic bitmap font)
    pub fn drawTimestamp(self: *Self, timestamp_us: i64, index: u32) void {
        if (!self.config.show_timestamps) return;

        const hours = @divTrunc(timestamp_us, 3_600_000_000);
        const minutes = @divTrunc(@mod(timestamp_us, 3_600_000_000), 60_000_000);
        const seconds = @divTrunc(@mod(timestamp_us, 60_000_000), 1_000_000);

        // Calculate position (bottom of thumbnail)
        const cols = if (self.config.columns) |c| c else 4;
        const col = index % cols;
        const row = index / cols;

        const x_offset = self.config.padding + col * (self.config.thumbnail_width + self.config.spacing);
        const y_offset = self.config.padding + row * (self.config.thumbnail_height + self.config.spacing) +
                        self.config.thumbnail_height - 12;

        // Draw simple timestamp string (would integrate with real text rendering)
        _ = hours;
        _ = minutes;
        _ = seconds;
        _ = x_offset;
        _ = y_offset;
        // TODO: Integrate with bitmap font or text rendering library
    }
};

// ============================================================================
// Preview Strip Generator
// ============================================================================

pub const PreviewStrip = struct {
    frame_width: u32 = 160,
    frame_height: u32 = 90,
    frame_count: u32 = 10,
    spacing: u32 = 2,
    orientation: enum { horizontal, vertical } = .horizontal,

    pub fn calculateDimensions(self: PreviewStrip) struct { width: u32, height: u32 } {
        return switch (self.orientation) {
            .horizontal => .{
                .width = self.frame_count * self.frame_width + (self.frame_count - 1) * self.spacing,
                .height = self.frame_height,
            },
            .vertical => .{
                .width = self.frame_width,
                .height = self.frame_count * self.frame_height + (self.frame_count - 1) * self.spacing,
            },
        };
    }
};
