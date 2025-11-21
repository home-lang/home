// Home Game Development Framework - Asset Loading System
// Supports textures, audio, fonts, and data files

const std = @import("std");

// ============================================================================
// Asset Types
// ============================================================================

pub const AssetType = enum {
    texture,
    audio,
    font,
    data,
    shader,
    model,
    animation,
    tilemap,
    sprite_sheet,
};

pub const AssetState = enum {
    unloaded,
    loading,
    loaded,
    failed,
};

// ============================================================================
// Asset Handle
// ============================================================================

pub fn AssetHandle(comptime T: type) type {
    return struct {
        id: u64,
        data: ?*T,
        state: AssetState,
        ref_count: u32,
    };
}

// ============================================================================
// Texture Asset
// ============================================================================

pub const TextureFormat = enum {
    rgba8,
    rgb8,
    rgba16f,
    r8,
    rg8,
};

pub const Texture = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: TextureFormat) !Texture {
        const bytes_per_pixel: u32 = switch (format) {
            .rgba8 => 4,
            .rgb8 => 3,
            .rgba16f => 8,
            .r8 => 1,
            .rg8 => 2,
        };
        const size = width * height * bytes_per_pixel;
        const pixels = try allocator.alloc(u8, size);

        return Texture{
            .width = width,
            .height = height,
            .format = format,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Texture) void {
        self.allocator.free(self.pixels);
    }

    pub fn getPixel(self: *const Texture, x: u32, y: u32) ?[4]u8 {
        if (x >= self.width or y >= self.height) return null;

        const bpp: u32 = switch (self.format) {
            .rgba8 => 4,
            .rgb8 => 3,
            .r8 => 1,
            .rg8 => 2,
            .rgba16f => 8,
        };
        const idx = (y * self.width + x) * bpp;

        return switch (self.format) {
            .rgba8 => .{
                self.pixels[idx],
                self.pixels[idx + 1],
                self.pixels[idx + 2],
                self.pixels[idx + 3],
            },
            .rgb8 => .{
                self.pixels[idx],
                self.pixels[idx + 1],
                self.pixels[idx + 2],
                255,
            },
            .r8 => .{
                self.pixels[idx],
                self.pixels[idx],
                self.pixels[idx],
                255,
            },
            else => null,
        };
    }

    pub fn setPixel(self: *Texture, x: u32, y: u32, color: [4]u8) void {
        if (x >= self.width or y >= self.height) return;

        const bpp: u32 = switch (self.format) {
            .rgba8 => 4,
            .rgb8 => 3,
            .r8 => 1,
            .rg8 => 2,
            .rgba16f => 8,
        };
        const idx = (y * self.width + x) * bpp;

        switch (self.format) {
            .rgba8 => {
                self.pixels[idx] = color[0];
                self.pixels[idx + 1] = color[1];
                self.pixels[idx + 2] = color[2];
                self.pixels[idx + 3] = color[3];
            },
            .rgb8 => {
                self.pixels[idx] = color[0];
                self.pixels[idx + 1] = color[1];
                self.pixels[idx + 2] = color[2];
            },
            .r8 => {
                self.pixels[idx] = color[0];
            },
            else => {},
        }
    }
};

// ============================================================================
// Audio Asset
// ============================================================================

pub const AudioFormat = enum {
    mono8,
    mono16,
    stereo8,
    stereo16,
    mono_f32,
    stereo_f32,
};

pub const AudioClip = struct {
    samples: []u8,
    sample_rate: u32,
    format: AudioFormat,
    duration_ms: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, format: AudioFormat, num_samples: usize) !AudioClip {
        const bytes_per_sample: usize = switch (format) {
            .mono8 => 1,
            .mono16, .stereo8 => 2,
            .stereo16 => 4,
            .mono_f32 => 4,
            .stereo_f32 => 8,
        };
        const size = num_samples * bytes_per_sample;
        const samples = try allocator.alloc(u8, size);

        const duration_ms = (num_samples * 1000) / sample_rate;

        return AudioClip{
            .samples = samples,
            .sample_rate = sample_rate,
            .format = format,
            .duration_ms = duration_ms,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AudioClip) void {
        self.allocator.free(self.samples);
    }
};

// ============================================================================
// Font Asset
// ============================================================================

pub const GlyphInfo = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    x_offset: i32,
    y_offset: i32,
    x_advance: i32,
};

pub const Font = struct {
    texture: ?Texture,
    glyphs: std.AutoHashMap(u32, GlyphInfo),
    size: f32,
    line_height: f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: f32) Font {
        return Font{
            .texture = null,
            .glyphs = std.AutoHashMap(u32, GlyphInfo).init(allocator),
            .size = size,
            .line_height = size * 1.2,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Font) void {
        if (self.texture) |*tex| {
            tex.deinit();
        }
        self.glyphs.deinit();
    }

    pub fn getGlyph(self: *const Font, codepoint: u32) ?GlyphInfo {
        return self.glyphs.get(codepoint);
    }

    pub fn measureText(self: *const Font, text: []const u8) struct { width: f32, height: f32 } {
        var width: f32 = 0;
        var max_height: f32 = self.line_height;

        for (text) |char| {
            if (self.glyphs.get(char)) |glyph| {
                width += @as(f32, @floatFromInt(glyph.x_advance));
                const h = @as(f32, @floatFromInt(glyph.height));
                if (h > max_height) max_height = h;
            }
        }

        return .{ .width = width, .height = max_height };
    }
};

// ============================================================================
// Sprite Sheet
// ============================================================================

pub const SpriteFrame = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    pivot_x: f32 = 0.5,
    pivot_y: f32 = 0.5,
    duration_ms: u32 = 100,
};

pub const SpriteAnimation = struct {
    name: []const u8,
    frames: []const u32, // Indices into sprite sheet
    loop: bool = true,
    frame_time_ms: u32 = 100,
};

pub const SpriteSheet = struct {
    texture: ?Texture,
    frames: std.ArrayList(SpriteFrame),
    animations: std.StringHashMap(SpriteAnimation),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpriteSheet {
        return SpriteSheet{
            .texture = null,
            .frames = std.ArrayList(SpriteFrame).init(allocator),
            .animations = std.StringHashMap(SpriteAnimation).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpriteSheet) void {
        if (self.texture) |*tex| {
            tex.deinit();
        }
        self.frames.deinit(self.allocator);
        self.animations.deinit();
    }

    pub fn addFrame(self: *SpriteSheet, frame: SpriteFrame) !u32 {
        const index = @as(u32, @intCast(self.frames.items.len));
        try self.frames.append(frame);
        return index;
    }

    pub fn getFrame(self: *const SpriteSheet, index: u32) ?SpriteFrame {
        if (index >= self.frames.items.len) return null;
        return self.frames.items[index];
    }
};

// ============================================================================
// Asset Manager
// ============================================================================

pub const AssetManager = struct {
    allocator: std.mem.Allocator,
    textures: std.StringHashMap(*Texture),
    audio_clips: std.StringHashMap(*AudioClip),
    fonts: std.StringHashMap(*Font),
    sprite_sheets: std.StringHashMap(*SpriteSheet),
    base_path: []const u8,
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) !*AssetManager {
        const self = try allocator.create(AssetManager);
        self.* = AssetManager{
            .allocator = allocator,
            .textures = std.StringHashMap(*Texture).init(allocator),
            .audio_clips = std.StringHashMap(*AudioClip).init(allocator),
            .fonts = std.StringHashMap(*Font).init(allocator),
            .sprite_sheets = std.StringHashMap(*SpriteSheet).init(allocator),
            .base_path = "",
            .next_id = 1,
        };
        return self;
    }

    pub fn deinit(self: *AssetManager) void {
        // Clean up textures
        var tex_iter = self.textures.iterator();
        while (tex_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.textures.deinit();

        // Clean up audio clips
        var audio_iter = self.audio_clips.iterator();
        while (audio_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.audio_clips.deinit();

        // Clean up fonts
        var font_iter = self.fonts.iterator();
        while (font_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.fonts.deinit();

        // Clean up sprite sheets
        var sheet_iter = self.sprite_sheets.iterator();
        while (sheet_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sprite_sheets.deinit();

        self.allocator.destroy(self);
    }

    pub fn setBasePath(self: *AssetManager, path: []const u8) void {
        self.base_path = path;
    }

    pub fn loadTexture(self: *AssetManager, name: []const u8, width: u32, height: u32) !*Texture {
        if (self.textures.get(name)) |tex| {
            return tex;
        }

        const texture = try self.allocator.create(Texture);
        texture.* = try Texture.init(self.allocator, width, height, .rgba8);
        try self.textures.put(name, texture);
        return texture;
    }

    pub fn getTexture(self: *const AssetManager, name: []const u8) ?*Texture {
        return self.textures.get(name);
    }

    pub fn loadFont(self: *AssetManager, name: []const u8, size: f32) !*Font {
        if (self.fonts.get(name)) |font| {
            return font;
        }

        const font = try self.allocator.create(Font);
        font.* = Font.init(self.allocator, size);
        try self.fonts.put(name, font);
        return font;
    }

    pub fn getFont(self: *const AssetManager, name: []const u8) ?*Font {
        return self.fonts.get(name);
    }

    pub fn loadAudioClip(self: *AssetManager, name: []const u8, sample_rate: u32, num_samples: usize) !*AudioClip {
        if (self.audio_clips.get(name)) |clip| {
            return clip;
        }

        const clip = try self.allocator.create(AudioClip);
        clip.* = try AudioClip.init(self.allocator, sample_rate, .stereo16, num_samples);
        try self.audio_clips.put(name, clip);
        return clip;
    }

    pub fn getAudioClip(self: *const AssetManager, name: []const u8) ?*AudioClip {
        return self.audio_clips.get(name);
    }

    pub fn createSpriteSheet(self: *AssetManager, name: []const u8) !*SpriteSheet {
        if (self.sprite_sheets.get(name)) |sheet| {
            return sheet;
        }

        const sheet = try self.allocator.create(SpriteSheet);
        sheet.* = SpriteSheet.init(self.allocator);
        try self.sprite_sheets.put(name, sheet);
        return sheet;
    }

    pub fn getSpriteSheet(self: *const AssetManager, name: []const u8) ?*SpriteSheet {
        return self.sprite_sheets.get(name);
    }

    pub fn unloadTexture(self: *AssetManager, name: []const u8) void {
        if (self.textures.fetchRemove(name)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    pub fn unloadAll(self: *AssetManager) void {
        // Unload all textures
        var tex_iter = self.textures.iterator();
        while (tex_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.textures.clearRetainingCapacity();

        // Unload all audio
        var audio_iter = self.audio_clips.iterator();
        while (audio_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.audio_clips.clearRetainingCapacity();
    }
};

// ============================================================================
// File Loaders (Stub implementations - would load actual file formats)
// ============================================================================

pub fn loadPNG(_: std.mem.Allocator, _: []const u8) !Texture {
    // Would parse PNG file
    return error.NotImplemented;
}

pub fn loadWAV(_: std.mem.Allocator, _: []const u8) !AudioClip {
    // Would parse WAV file
    return error.NotImplemented;
}

pub fn loadOGG(_: std.mem.Allocator, _: []const u8) !AudioClip {
    // Would parse OGG file
    return error.NotImplemented;
}

pub fn loadTTF(_: std.mem.Allocator, _: []const u8, _: f32) !Font {
    // Would parse TTF file
    return error.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "Texture creation" {
    var texture = try Texture.init(std.testing.allocator, 64, 64, .rgba8);
    defer texture.deinit();

    try std.testing.expectEqual(@as(u32, 64), texture.width);
    try std.testing.expectEqual(@as(u32, 64), texture.height);
}

test "Texture get/set pixel" {
    var texture = try Texture.init(std.testing.allocator, 64, 64, .rgba8);
    defer texture.deinit();

    texture.setPixel(10, 10, .{ 255, 128, 64, 255 });
    const pixel = texture.getPixel(10, 10);

    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?[0]);
    try std.testing.expectEqual(@as(u8, 128), pixel.?[1]);
}

test "AssetManager" {
    var manager = try AssetManager.init(std.testing.allocator);
    defer manager.deinit();

    const tex = try manager.loadTexture("test", 32, 32);
    try std.testing.expectEqual(@as(u32, 32), tex.width);

    const retrieved = manager.getTexture("test");
    try std.testing.expect(retrieved != null);
}

test "Font measurement" {
    var font = Font.init(std.testing.allocator, 16.0);
    defer font.deinit();

    try font.glyphs.put('A', .{
        .x = 0,
        .y = 0,
        .width = 10,
        .height = 16,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 12,
    });

    const size = font.measureText("A");
    try std.testing.expectEqual(@as(f32, 12), size.width);
}
