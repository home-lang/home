// Home Video Library - Animated Thumbnail Generation
// Generate animated GIFs or WebP from video sequences

const std = @import("std");

// ============================================================================
// Animated GIF Configuration
// ============================================================================

pub const AnimatedGifConfig = struct {
    width: u32 = 320,
    height: u32 = 180,
    fps: u8 = 10, // Target framerate
    max_frames: u32 = 50,
    max_duration_seconds: f32 = 5.0,
    loop_count: u16 = 0, // 0 = infinite
    dither: bool = true,
    quality: u8 = 80, // Color quantization quality (0-100)
    optimize: bool = true, // Optimize for file size
};

pub const AnimatedWebPConfig = struct {
    width: u32 = 320,
    height: u32 = 180,
    fps: u8 = 15,
    max_frames: u32 = 60,
    max_duration_seconds: f32 = 4.0,
    quality: f32 = 75.0, // 0-100
    lossless: bool = false,
};

// ============================================================================
// Frame Sampling Strategy
// ============================================================================

pub const SamplingStrategy = enum {
    uniform, // Sample frames at regular intervals
    scene_based, // Sample around scene changes
    adaptive, // Adapt sampling rate to motion
    keyframes, // Sample keyframes only
};

pub const FrameSampler = struct {
    strategy: SamplingStrategy = .uniform,

    pub fn calculateSamplePoints(
        self: FrameSampler,
        start_us: i64,
        duration_us: i64,
        target_count: u32,
    ) ![]i64 {
        _ = self;

        var samples = std.ArrayList(i64).init(std.heap.page_allocator);
        defer samples.deinit();

        const interval = @divTrunc(duration_us, @as(i64, @intCast(target_count)));

        var i: u32 = 0;
        while (i < target_count) : (i += 1) {
            const timestamp = start_us + @as(i64, @intCast(i)) * interval;
            try samples.append(timestamp);
        }

        return samples.toOwnedSlice();
    }
};

// ============================================================================
// GIF Palette Generation
// ============================================================================

pub const GifPalette = struct {
    colors: [256][3]u8, // RGB colors
    color_count: u16,

    pub fn fromFrame(pixels: []const u8, width: u32, height: u32, max_colors: u16) GifPalette {
        var palette: GifPalette = undefined;
        palette.color_count = @min(max_colors, 256);

        // Simple median cut algorithm (simplified)
        // In production, would use proper color quantization

        // For now, use a simple approach: sample colors uniformly
        const total_pixels = width * height;
        const step = total_pixels / @as(usize, @intCast(palette.color_count));

        var i: u16 = 0;
        var pixel_idx: usize = 0;
        while (i < palette.color_count and pixel_idx < total_pixels) : ({
            i += 1;
            pixel_idx += step;
        }) {
            palette.colors[i][0] = pixels[pixel_idx * 3];
            palette.colors[i][1] = pixels[pixel_idx * 3 + 1];
            palette.colors[i][2] = pixels[pixel_idx * 3 + 2];
        }

        return palette;
    }

    pub fn findClosestColor(self: *const GifPalette, r: u8, g: u8, b: u8) u8 {
        var min_dist: u32 = std.math.maxInt(u32);
        var closest: u8 = 0;

        for (0..self.color_count) |i| {
            const dr = @as(i32, @intCast(r)) - @as(i32, @intCast(self.colors[i][0]));
            const dg = @as(i32, @intCast(g)) - @as(i32, @intCast(self.colors[i][1]));
            const db = @as(i32, @intCast(b)) - @as(i32, @intCast(self.colors[i][2]));

            const dist = @as(u32, @intCast(dr * dr + dg * dg + db * db));

            if (dist < min_dist) {
                min_dist = dist;
                closest = @intCast(i);
            }
        }

        return closest;
    }
};

// ============================================================================
// Animated Thumbnail Metadata
// ============================================================================

pub const AnimatedMetadata = struct {
    format: enum { gif, webp },
    width: u32,
    height: u32,
    frame_count: u32,
    duration_ms: u32,
    loop_count: u16,
    file_size: usize,

    pub fn calculateBitrate(self: AnimatedMetadata) u32 {
        if (self.duration_ms == 0) return 0;
        return @as(u32, @intCast((self.file_size * 8 * 1000) / self.duration_ms));
    }
};
