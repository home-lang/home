// Home Video Library - Thumbnail & Preview Generation
// Extract representative frames, generate contact sheets, and sprite sheets

const std = @import("std");
const core = @import("../core.zig");
const io = @import("../io.zig");

// ============================================================================
// Thumbnail Configuration
// ============================================================================

pub const ThumbnailConfig = struct {
    /// Output width (height computed from aspect ratio)
    width: u32 = 320,

    /// Output height (0 = auto from aspect ratio)
    height: u32 = 0,

    /// JPEG quality (1-100)
    quality: u8 = 85,

    /// Output format
    format: OutputFormat = .jpeg,

    /// Skip black frames when auto-detecting
    skip_black_frames: bool = true,

    /// Black frame threshold (0.0-1.0)
    black_threshold: f32 = 0.1,

    pub const OutputFormat = enum {
        jpeg,
        png,
        webp,
    };
};

// ============================================================================
// Thumbnail Generator
// ============================================================================

pub const ThumbnailGenerator = struct {
    config: ThumbnailConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ThumbnailConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Extract thumbnail at specific timestamp
    pub fn extractAtTime(self: *Self, video_path: []const u8, timestamp: f64) !*core.VideoFrame {
        _ = video_path;
        _ = timestamp;
        // Would integrate with video decoder to seek and extract frame
        return error.NotImplemented;
    }

    /// Extract representative thumbnail (smart scene detection)
    pub fn extractRepresentative(self: *Self, video_path: []const u8, duration: f64) !*core.VideoFrame {
        // Extract frame at 1/4 of video duration (good heuristic)
        const timestamp = duration * 0.25;

        if (self.config.skip_black_frames) {
            // Try multiple positions if we hit black frames
            const positions = [_]f64{ 0.25, 0.5, 0.75, 0.1, 0.9 };
            for (positions) |pos| {
                const frame = try self.extractAtTime(video_path, duration * pos);
                if (!self.isBlackFrame(frame)) {
                    return frame;
                }
                frame.deinit();
                self.allocator.destroy(frame);
            }
        }

        return self.extractAtTime(video_path, timestamp);
    }

    /// Extract multiple evenly-spaced thumbnails
    pub fn extractMultiple(self: *Self, video_path: []const u8, duration: f64, count: u32) !std.ArrayList(*core.VideoFrame) {
        var thumbnails = std.ArrayList(*core.VideoFrame).init(self.allocator);
        errdefer {
            for (thumbnails.items) |thumb| {
                thumb.deinit();
                self.allocator.destroy(thumb);
            }
            thumbnails.deinit();
        }

        const interval = duration / @as(f64, @floatFromInt(count + 1));

        var i: u32 = 1;
        while (i <= count) : (i += 1) {
            const timestamp = interval * @as(f64, @floatFromInt(i));
            const frame = try self.extractAtTime(video_path, timestamp);
            try thumbnails.append(frame);
        }

        return thumbnails;
    }

    /// Check if frame is mostly black
    fn isBlackFrame(self: *Self, frame: *const core.VideoFrame) bool {
        const pixel_count = frame.width * frame.height;
        var sum: u64 = 0;

        // Sample luma channel
        for (0..pixel_count) |i| {
            sum += frame.data[0][i];
        }

        const avg_brightness = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(pixel_count));
        const normalized = avg_brightness / 255.0;

        return normalized < self.config.black_threshold;
    }

    /// Resize frame to thumbnail size
    pub fn resizeFrame(self: *Self, frame: *const core.VideoFrame) !*core.VideoFrame {
        const output = try self.allocator.create(core.VideoFrame);

        // Calculate output dimensions maintaining aspect ratio
        const aspect_ratio = @as(f32, @floatFromInt(frame.width)) / @as(f32, @floatFromInt(frame.height));
        const out_width = self.config.width;
        const out_height = if (self.config.height > 0)
            self.config.height
        else
            @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_width)) / aspect_ratio));

        output.* = try core.VideoFrame.init(self.allocator, out_width, out_height, frame.format);

        // Simple nearest-neighbor resize (would use better scaling in production)
        const x_ratio = @as(f32, @floatFromInt(frame.width)) / @as(f32, @floatFromInt(out_width));
        const y_ratio = @as(f32, @floatFromInt(frame.height)) / @as(f32, @floatFromInt(out_height));

        for (0..out_height) |y| {
            for (0..out_width) |x| {
                const src_x: usize = @intFromFloat(@as(f32, @floatFromInt(x)) * x_ratio);
                const src_y: usize = @intFromFloat(@as(f32, @floatFromInt(y)) * y_ratio);
                const src_idx = src_y * frame.width + src_x;
                const dst_idx = y * out_width + x;

                output.data[0][dst_idx] = frame.data[0][src_idx];
            }
        }

        return output;
    }
};

// ============================================================================
// Contact Sheet / Grid Generator
// ============================================================================

pub const ContactSheetConfig = struct {
    rows: u32 = 4,
    cols: u32 = 4,
    thumbnail_width: u32 = 240,
    thumbnail_height: u32 = 135,
    spacing: u32 = 10,
    background_color: [3]u8 = .{ 0, 0, 0 },
};

pub const ContactSheet = struct {
    config: ContactSheetConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ContactSheetConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Generate contact sheet from video
    pub fn generate(self: *Self, video_path: []const u8, duration: f64) !*core.VideoFrame {
        const thumb_count = self.config.rows * self.config.cols;

        // Extract thumbnails
        var thumb_gen = ThumbnailGenerator.init(self.allocator, .{
            .width = self.config.thumbnail_width,
            .height = self.config.thumbnail_height,
        });

        var thumbnails = try thumb_gen.extractMultiple(video_path, duration, thumb_count);
        defer {
            for (thumbnails.items) |thumb| {
                thumb.deinit();
                self.allocator.destroy(thumb);
            }
            thumbnails.deinit();
        }

        // Create output frame
        const output_width = self.config.cols * self.config.thumbnail_width +
                           (self.config.cols + 1) * self.config.spacing;
        const output_height = self.config.rows * self.config.thumbnail_height +
                            (self.config.rows + 1) * self.config.spacing;

        const output = try self.allocator.create(core.VideoFrame);
        output.* = try core.VideoFrame.init(self.allocator, output_width, output_height, .rgb24);

        // Fill background
        const bg = self.config.background_color;
        for (0..output_height) |y| {
            for (0..output_width) |x| {
                const idx = (y * output_width + x) * 3;
                output.data[0][idx + 0] = bg[0];
                output.data[0][idx + 1] = bg[1];
                output.data[0][idx + 2] = bg[2];
            }
        }

        // Place thumbnails
        for (0..self.config.rows) |row| {
            for (0..self.config.cols) |col| {
                const thumb_idx = row * self.config.cols + col;
                if (thumb_idx >= thumbnails.items.len) break;

                const thumb = thumbnails.items[thumb_idx];
                const x_offset = (col + 1) * self.config.spacing + col * self.config.thumbnail_width;
                const y_offset = (row + 1) * self.config.spacing + row * self.config.thumbnail_height;

                // Copy thumbnail to output (simplified - would handle format conversion)
                for (0..thumb.height) |ty| {
                    for (0..thumb.width) |tx| {
                        const src_idx = ty * thumb.width + tx;
                        const dst_x = x_offset + tx;
                        const dst_y = y_offset + ty;
                        const dst_idx = (dst_y * output_width + dst_x) * 3;

                        if (dst_y < output_height and dst_x < output_width) {
                            output.data[0][dst_idx] = thumb.data[0][src_idx];
                            output.data[0][dst_idx + 1] = thumb.data[0][src_idx];
                            output.data[0][dst_idx + 2] = thumb.data[0][src_idx];
                        }
                    }
                }
            }
        }

        return output;
    }
};

// ============================================================================
// Sprite Sheet Generator
// ============================================================================

pub const SpriteSheetConfig = struct {
    /// Interval between frames (seconds)
    interval: f64 = 5.0,

    /// Thumbnail dimensions
    thumb_width: u32 = 160,
    thumb_height: u32 = 90,

    /// Grid layout
    cols: u32 = 10,
    rows: u32 = 10,

    /// Maximum sprites per sheet
    max_sprites_per_sheet: u32 = 100,

    /// Output format
    format: ThumbnailConfig.OutputFormat = .jpeg,

    /// JPEG quality
    quality: u8 = 80,

    /// Generate WebVTT metadata
    generate_webvtt: bool = true,

    /// Generate JSON metadata
    generate_json: bool = true,
};

pub const SpriteMetadata = struct {
    timestamp: f64,
    sheet_index: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const SpriteSheet = struct {
    config: SpriteSheetConfig,
    allocator: std.mem.Allocator,
    metadata: std.ArrayList(SpriteMetadata),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SpriteSheetConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
            .metadata = std.ArrayList(SpriteMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.metadata.deinit();
    }

    /// Generate sprite sheets from video
    pub fn generate(self: *Self, video_path: []const u8, duration: f64, output_dir: []const u8) !void {
        const sprite_count = @as(u32, @intFromFloat(duration / self.config.interval));
        const sheets_needed = (sprite_count + self.config.max_sprites_per_sheet - 1) /
                             self.config.max_sprites_per_sheet;

        var thumb_gen = ThumbnailGenerator.init(self.allocator, .{
            .width = self.config.thumb_width,
            .height = self.config.thumb_height,
        });

        // Generate each sheet
        var sheet_idx: u32 = 0;
        while (sheet_idx < sheets_needed) : (sheet_idx += 1) {
            try self.generateSheet(video_path, duration, sheet_idx, &thumb_gen);
        }

        // Generate metadata files
        if (self.config.generate_webvtt) {
            try self.generateWebVTT(output_dir);
        }

        if (self.config.generate_json) {
            try self.generateJSON(output_dir);
        }
    }

    fn generateSheet(self: *Self, video_path: []const u8, duration: f64, sheet_index: u32, thumb_gen: *ThumbnailGenerator) !void {
        _ = video_path;
        _ = duration;
        _ = thumb_gen;

        const sprites_per_sheet = self.config.cols * self.config.rows;
        const start_sprite = sheet_index * self.config.max_sprites_per_sheet;
        const end_sprite = @min(start_sprite + self.config.max_sprites_per_sheet,
                               @as(u32, @intFromFloat(duration / self.config.interval)));

        // Create sheet canvas
        const sheet_width = self.config.cols * self.config.thumb_width;
        const sheet_height = self.config.rows * self.config.thumb_height;

        const sheet = try self.allocator.create(core.VideoFrame);
        defer {
            sheet.deinit();
            self.allocator.destroy(sheet);
        }

        sheet.* = try core.VideoFrame.init(self.allocator, sheet_width, sheet_height, .rgb24);

        // Extract and place sprites
        var sprite_idx = start_sprite;
        while (sprite_idx < end_sprite and sprite_idx < sprites_per_sheet) : (sprite_idx += 1) {
            const timestamp = @as(f64, @floatFromInt(sprite_idx)) * self.config.interval;
            const grid_idx = sprite_idx - start_sprite;
            const row = grid_idx / self.config.cols;
            const col = grid_idx % self.config.cols;

            const x = col * self.config.thumb_width;
            const y = row * self.config.thumb_height;

            // Store metadata
            try self.metadata.append(.{
                .timestamp = timestamp,
                .sheet_index = sheet_index,
                .x = x,
                .y = y,
                .width = self.config.thumb_width,
                .height = self.config.thumb_height,
            });
        }

        // Would save sheet to file here
    }

    /// Generate WebVTT metadata for video.js compatibility
    fn generateWebVTT(self: *Self, output_dir: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/sprites.vtt", .{output_dir});
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        try writer.writeAll("WEBVTT\n\n");

        for (self.metadata.items, 0..) |sprite, i| {
            const start_time = sprite.timestamp;
            const end_time = if (i + 1 < self.metadata.items.len)
                self.metadata.items[i + 1].timestamp
            else
                start_time + self.config.interval;

            // Write cue
            try writer.print("{d:0>2}:{d:0>2}:{d:0>6.3} --> {d:0>2}:{d:0>2}:{d:0>6.3}\n", .{
                @as(u32, @intFromFloat(start_time)) / 3600,
                (@as(u32, @intFromFloat(start_time)) % 3600) / 60,
                @mod(@as(f64, start_time), 60.0),
                @as(u32, @intFromFloat(end_time)) / 3600,
                (@as(u32, @intFromFloat(end_time)) % 3600) / 60,
                @mod(@as(f64, end_time), 60.0),
            });

            try writer.print("sprite_{d}.jpg#xywh={d},{d},{d},{d}\n\n", .{
                sprite.sheet_index,
                sprite.x,
                sprite.y,
                sprite.width,
                sprite.height,
            });
        }
    }

    /// Generate JSON metadata for custom implementations
    fn generateJSON(self: *Self, output_dir: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/sprites.json", .{output_dir});
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        try writer.writeAll("{\n  \"sprites\": [\n");

        for (self.metadata.items, 0..) |sprite, i| {
            try writer.print("    {{\n", .{});
            try writer.print("      \"timestamp\": {d},\n", .{sprite.timestamp});
            try writer.print("      \"sheet\": {d},\n", .{sprite.sheet_index});
            try writer.print("      \"x\": {d},\n", .{sprite.x});
            try writer.print("      \"y\": {d},\n", .{sprite.y});
            try writer.print("      \"width\": {d},\n", .{sprite.width});
            try writer.print("      \"height\": {d}\n", .{sprite.height});

            if (i < self.metadata.items.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }

        try writer.writeAll("  ]\n}\n");
    }
};

// ============================================================================
// Preview Video Generator
// ============================================================================

pub const PreviewConfig = struct {
    /// Target width (maintains aspect ratio)
    width: u32 = 640,

    /// Target bitrate (bits/sec)
    bitrate: u32 = 500_000,

    /// Frame rate (0 = same as source)
    fps: f64 = 0,

    /// Maximum duration (0 = no limit)
    max_duration: f64 = 0,
};

pub const PreviewGenerator = struct {
    config: PreviewConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PreviewConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Generate low-res preview video for scrubbing
    pub fn generate(self: *Self, input_path: []const u8, output_path: []const u8) !void {
        _ = self;
        _ = input_path;
        _ = output_path;

        // Would:
        // 1. Open input video
        // 2. Create output encoder with preview settings
        // 3. Decode, scale down, re-encode each frame
        // 4. Write preview video

        return error.NotImplemented;
    }
};
