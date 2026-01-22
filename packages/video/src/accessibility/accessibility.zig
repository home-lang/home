// Home Video Library - Accessibility Features
// Support for audio descriptions, closed captions, and sign language tracks

const std = @import("std");
const packet = @import("../core/packet.zig");
const cea608 = @import("../captions/cea608.zig");
const cea708 = @import("../captions/cea708.zig");

// ============================================================================
// Track Disposition Flags (IETF RFC 8216 / ISO 14496-12)
// ============================================================================

/// Track disposition flags for accessibility features
pub const TrackDisposition = packed struct(u32) {
    default: bool = false,
    dub: bool = false,
    original: bool = false,
    comment: bool = false,
    lyrics: bool = false,
    karaoke: bool = false,
    forced: bool = false,
    hearing_impaired: bool = false,
    visual_impaired: bool = false,
    clean_effects: bool = false,
    attached_pic: bool = false,
    timed_thumbnails: bool = false,
    captions: bool = false,
    descriptions: bool = false,
    metadata: bool = false,
    dependent: bool = false,
    still_image: bool = false,
    sign_language: bool = false,
    _reserved: u14 = 0,

    pub fn hasAudioDescription(self: TrackDisposition) bool {
        return self.descriptions or self.visual_impaired;
    }

    pub fn hasClosedCaptions(self: TrackDisposition) bool {
        return self.captions or self.hearing_impaired;
    }

    pub fn hasSignLanguage(self: TrackDisposition) bool {
        return self.sign_language;
    }
};

// ============================================================================
// Audio Description Track
// ============================================================================

/// Audio description metadata
pub const AudioDescriptionInfo = struct {
    language: [3]u8 = .{ 'e', 'n', 'g' }, // ISO 639-2 language code
    description: ?[]const u8 = null, // e.g., "Audio Description"
    channel_count: u8 = 2,
    sample_rate: u32 = 48000,
    is_primary: bool = false,
    timing_offset_ms: i32 = 0, // Sync adjustment in milliseconds
};

/// Audio description track handler
pub const AudioDescriptionTrack = struct {
    allocator: std.mem.Allocator,
    info: AudioDescriptionInfo,
    track_id: u32,
    is_enabled: bool = true,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, track_id: u32) Self {
        return .{
            .allocator = allocator,
            .info = .{},
            .track_id = track_id,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.info.description) |desc| {
            self.allocator.free(desc);
        }
    }

    pub fn setLanguage(self: *Self, language: [3]u8) void {
        self.info.language = language;
    }

    pub fn setDescription(self: *Self, desc: []const u8) !void {
        if (self.info.description) |old| {
            self.allocator.free(old);
        }
        self.info.description = try self.allocator.dupe(u8, desc);
    }

    pub fn setTimingOffset(self: *Self, offset_ms: i32) void {
        self.info.timing_offset_ms = offset_ms;
    }

    /// Check if this track should be mixed with main audio
    pub fn shouldMixWithMain(self: *const Self) bool {
        return self.is_enabled and !self.info.is_primary;
    }
};

// ============================================================================
// Closed Captions
// ============================================================================

/// Caption format type
pub const CaptionFormat = enum {
    cea608, // NTSC Line 21 closed captions
    cea708, // ATSC Digital TV captions
    webvtt, // Web Video Text Tracks
    srt, // SubRip
    ttml, // Timed Text Markup Language
    smpte_tt, // SMPTE Timed Text
    imsc1, // IMSC1 (EBU-TT)
};

/// Caption embedding mode
pub const CaptionEmbedMode = enum {
    sei_nalu, // SEI NAL units (H.264/HEVC)
    mpeg_user_data, // MPEG-2 user data
    atsc_a53, // ATSC A/53 method
    dvb_teletext, // DVB Teletext
    side_data, // Container side data
    burn_in, // Hardcoded into video frames
};

/// Caption extraction/embedding handler
pub const CaptionHandler = struct {
    allocator: std.mem.Allocator,
    format: CaptionFormat = .cea608,
    embed_mode: CaptionEmbedMode = .sei_nalu,
    cea608_decoder: ?cea608.Cea608Decoder = null,
    cea708_decoder: ?cea708.Cea708Decoder = null,
    extracted_cues: std.ArrayList(CaptionCue),

    const Self = @This();

    pub const CaptionCue = struct {
        start_time_ms: u64,
        end_time_ms: u64,
        text: []const u8,
        style: ?CaptionStyle = null,
        position: ?CaptionPosition = null,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *CaptionCue) void {
            self.allocator.free(self.text);
            if (self.style) |*s| {
                if (s.font_family) |f| self.allocator.free(f);
            }
        }
    };

    pub const CaptionStyle = struct {
        font_family: ?[]const u8 = null,
        font_size: f32 = 1.0, // Relative size
        color: u32 = 0xFFFFFFFF, // ARGB
        background_color: u32 = 0x80000000, // Semi-transparent black
        italic: bool = false,
        bold: bool = false,
        underline: bool = false,
    };

    pub const CaptionPosition = struct {
        x: f32 = 0.5, // 0.0 = left, 1.0 = right
        y: f32 = 0.9, // 0.0 = top, 1.0 = bottom
        align: Alignment = .center,

        pub const Alignment = enum { left, center, right };
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .extracted_cues = std.ArrayList(CaptionCue).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.extracted_cues.items) |*cue| {
            cue.deinit();
        }
        self.extracted_cues.deinit();
    }

    /// Set the caption format to use
    pub fn setFormat(self: *Self, format: CaptionFormat) void {
        self.format = format;
    }

    /// Set the embedding mode
    pub fn setEmbedMode(self: *Self, mode: CaptionEmbedMode) void {
        self.embed_mode = mode;
    }

    /// Extract captions from SEI NAL unit data
    pub fn extractFromSei(self: *Self, sei_data: []const u8, timestamp_ms: u64) !void {
        // Look for closed caption payload type (4 = user data registered by ITU-T T.35)
        var offset: usize = 0;
        while (offset < sei_data.len) {
            // Parse SEI payload type
            var payload_type: u32 = 0;
            while (offset < sei_data.len and sei_data[offset] == 0xFF) {
                payload_type += 255;
                offset += 1;
            }
            if (offset >= sei_data.len) break;
            payload_type += sei_data[offset];
            offset += 1;

            // Parse SEI payload size
            var payload_size: u32 = 0;
            while (offset < sei_data.len and sei_data[offset] == 0xFF) {
                payload_size += 255;
                offset += 1;
            }
            if (offset >= sei_data.len) break;
            payload_size += sei_data[offset];
            offset += 1;

            if (offset + payload_size > sei_data.len) break;

            // Check for caption payload types
            if (payload_type == 4) {
                // User data registered by ITU-T T.35 - may contain CEA-608/708
                try self.extractCea708FromUserData(sei_data[offset .. offset + payload_size], timestamp_ms);
            }

            offset += payload_size;
        }
    }

    fn extractCea708FromUserData(self: *Self, data: []const u8, timestamp_ms: u64) !void {
        if (data.len < 7) return;

        // Check for ATSC A/53 marker (country code 0xB5, provider code 0x0031)
        if (data[0] == 0xB5 and data[1] == 0x00 and data[2] == 0x31) {
            // ATSC1_data() structure
            const user_identifier = std.mem.readInt(u32, data[3..7], .big);
            if (user_identifier == 0x47413934) { // "GA94"
                // Contains cc_data
                try self.processCcData(data[7..], timestamp_ms);
            }
        }
    }

    fn processCcData(self: *Self, data: []const u8, timestamp_ms: u64) !void {
        if (data.len < 3) return;

        const cc_count = data[0] & 0x1F;
        var offset: usize = 1;

        var i: u8 = 0;
        while (i < cc_count and offset + 3 <= data.len) : (i += 1) {
            const cc_valid = (data[offset] & 0x04) != 0;
            const cc_type = data[offset] & 0x03;
            const cc_data1 = data[offset + 1];
            const cc_data2 = data[offset + 2];

            if (cc_valid) {
                if (cc_type == 0 or cc_type == 1) {
                    // CEA-608 field 1 or 2
                    const text = try self.decodeCea608Pair(cc_data1, cc_data2);
                    if (text.len > 0) {
                        try self.extracted_cues.append(.{
                            .start_time_ms = timestamp_ms,
                            .end_time_ms = timestamp_ms + 3000, // Default 3 second duration
                            .text = text,
                            .allocator = self.allocator,
                        });
                    }
                }
                // cc_type 2 and 3 would be CEA-708 DTVCC packets
            }

            offset += 3;
        }
    }

    fn decodeCea608Pair(self: *Self, data1: u8, data2: u8) ![]const u8 {
        // Basic CEA-608 character decoding
        // This is a simplified implementation
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        // Check for printable characters
        const c1 = data1 & 0x7F;
        const c2 = data2 & 0x7F;

        if (c1 >= 0x20 and c1 < 0x7F) {
            try buf.append(c1);
        }
        if (c2 >= 0x20 and c2 < 0x7F) {
            try buf.append(c2);
        }

        return buf.toOwnedSlice();
    }

    /// Create SEI NAL unit with embedded captions
    pub fn createCaptionSei(self: *Self, cue: CaptionCue) ![]u8 {
        _ = cue;
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // SEI NAL unit header (for H.264)
        try output.append(0x06); // NAL type = SEI

        // User data registered payload (ITU-T T.35)
        try output.append(4); // payload_type = 4

        // Placeholder for payload size (will be updated)
        const size_pos = output.items.len;
        try output.append(0);

        // Country code (US)
        try output.append(0xB5);
        // Provider code (ATSC)
        try output.appendSlice(&[_]u8{ 0x00, 0x31 });
        // User identifier "GA94"
        try output.appendSlice("GA94");

        // cc_data_pkt
        try output.append(0x03); // user_data_type_code
        // ... add actual caption data here

        // Update payload size
        output.items[size_pos] = @intCast(output.items.len - size_pos - 1);

        return output.toOwnedSlice();
    }

    /// Get all extracted caption cues
    pub fn getCues(self: *const Self) []const CaptionCue {
        return self.extracted_cues.items;
    }

    /// Export captions to WebVTT format
    pub fn exportToWebVtt(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // WebVTT header
        try output.appendSlice("WEBVTT\n\n");

        for (self.extracted_cues.items, 0..) |cue, i| {
            // Cue identifier
            try output.writer().print("{d}\n", .{i + 1});

            // Timing
            try self.formatVttTimestamp(&output, cue.start_time_ms);
            try output.appendSlice(" --> ");
            try self.formatVttTimestamp(&output, cue.end_time_ms);
            try output.append('\n');

            // Text
            try output.appendSlice(cue.text);
            try output.appendSlice("\n\n");
        }

        return output.toOwnedSlice();
    }

    fn formatVttTimestamp(self: *Self, output: *std.ArrayList(u8), ms: u64) !void {
        _ = self;
        const hours = ms / (60 * 60 * 1000);
        const minutes = (ms / (60 * 1000)) % 60;
        const seconds = (ms / 1000) % 60;
        const millis = ms % 1000;

        try output.writer().print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, minutes, seconds, millis });
    }
};

// ============================================================================
// Sign Language Track
// ============================================================================

/// Sign language video track information
pub const SignLanguageInfo = struct {
    language: [3]u8 = .{ 'a', 's', 'l' }, // ISO 639-2 code (asl, bsl, etc.)
    region: ?[2]u8 = null, // ISO 3166-1 alpha-2 (US, GB, etc.)
    interpreter_name: ?[]const u8 = null,
    position: SignPosition = .bottom_right,
    size: SignSize = .medium,

    pub const SignPosition = enum {
        top_left,
        top_right,
        bottom_left,
        bottom_right,
        center_right,
    };

    pub const SignSize = enum {
        small, // ~15% of frame
        medium, // ~25% of frame
        large, // ~35% of frame
    };
};

/// Sign language track handler
pub const SignLanguageTrack = struct {
    allocator: std.mem.Allocator,
    info: SignLanguageInfo,
    track_id: u32,
    is_enabled: bool = true,
    overlay_opacity: f32 = 1.0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, track_id: u32) Self {
        return .{
            .allocator = allocator,
            .info = .{},
            .track_id = track_id,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.info.interpreter_name) |name| {
            self.allocator.free(name);
        }
    }

    pub fn setLanguage(self: *Self, language: [3]u8) void {
        self.info.language = language;
    }

    pub fn setPosition(self: *Self, position: SignLanguageInfo.SignPosition) void {
        self.info.position = position;
    }

    pub fn setSize(self: *Self, size: SignLanguageInfo.SignSize) void {
        self.info.size = size;
    }

    pub fn setInterpreterName(self: *Self, name: []const u8) !void {
        if (self.info.interpreter_name) |old| {
            self.allocator.free(old);
        }
        self.info.interpreter_name = try self.allocator.dupe(u8, name);
    }

    /// Calculate overlay rectangle based on frame dimensions
    pub fn getOverlayRect(self: *const Self, frame_width: u32, frame_height: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
        const size_factor: f32 = switch (self.info.size) {
            .small => 0.15,
            .medium => 0.25,
            .large => 0.35,
        };

        const w: u32 = @intFromFloat(@as(f32, @floatFromInt(frame_width)) * size_factor);
        const h: u32 = @intFromFloat(@as(f32, @floatFromInt(frame_height)) * size_factor);
        const margin: u32 = 10;

        const pos = switch (self.info.position) {
            .top_left => .{ .x = margin, .y = margin },
            .top_right => .{ .x = frame_width - w - margin, .y = margin },
            .bottom_left => .{ .x = margin, .y = frame_height - h - margin },
            .bottom_right => .{ .x = frame_width - w - margin, .y = frame_height - h - margin },
            .center_right => .{ .x = frame_width - w - margin, .y = (frame_height - h) / 2 },
        };

        return .{ .x = pos.x, .y = pos.y, .w = w, .h = h };
    }
};

// ============================================================================
// Accessibility Manager
// ============================================================================

/// Central manager for all accessibility features
pub const AccessibilityManager = struct {
    allocator: std.mem.Allocator,
    audio_description_tracks: std.ArrayList(AudioDescriptionTrack),
    caption_handler: CaptionHandler,
    sign_language_tracks: std.ArrayList(SignLanguageTrack),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .audio_description_tracks = std.ArrayList(AudioDescriptionTrack).init(allocator),
            .caption_handler = CaptionHandler.init(allocator),
            .sign_language_tracks = std.ArrayList(SignLanguageTrack).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.audio_description_tracks.items) |*track| {
            track.deinit();
        }
        self.audio_description_tracks.deinit();

        self.caption_handler.deinit();

        for (self.sign_language_tracks.items) |*track| {
            track.deinit();
        }
        self.sign_language_tracks.deinit();
    }

    /// Add an audio description track
    pub fn addAudioDescriptionTrack(self: *Self, track_id: u32) !*AudioDescriptionTrack {
        var track = AudioDescriptionTrack.init(self.allocator, track_id);
        try self.audio_description_tracks.append(track);
        return &self.audio_description_tracks.items[self.audio_description_tracks.items.len - 1];
    }

    /// Add a sign language track
    pub fn addSignLanguageTrack(self: *Self, track_id: u32) !*SignLanguageTrack {
        var track = SignLanguageTrack.init(self.allocator, track_id);
        try self.sign_language_tracks.append(track);
        return &self.sign_language_tracks.items[self.sign_language_tracks.items.len - 1];
    }

    /// Get caption handler
    pub fn getCaptionHandler(self: *Self) *CaptionHandler {
        return &self.caption_handler;
    }

    /// Check if media has any accessibility features
    pub fn hasAccessibilityFeatures(self: *const Self) bool {
        return self.audio_description_tracks.items.len > 0 or
            self.caption_handler.extracted_cues.items.len > 0 or
            self.sign_language_tracks.items.len > 0;
    }

    /// Get accessibility summary
    pub fn getSummary(self: *const Self) AccessibilitySummary {
        return .{
            .has_audio_description = self.audio_description_tracks.items.len > 0,
            .audio_description_count = @intCast(self.audio_description_tracks.items.len),
            .has_closed_captions = self.caption_handler.extracted_cues.items.len > 0,
            .caption_cue_count = @intCast(self.caption_handler.extracted_cues.items.len),
            .has_sign_language = self.sign_language_tracks.items.len > 0,
            .sign_language_count = @intCast(self.sign_language_tracks.items.len),
        };
    }

    pub const AccessibilitySummary = struct {
        has_audio_description: bool,
        audio_description_count: u32,
        has_closed_captions: bool,
        caption_cue_count: u32,
        has_sign_language: bool,
        sign_language_count: u32,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "TrackDisposition flags" {
    var disp = TrackDisposition{};
    try std.testing.expect(!disp.hasAudioDescription());
    try std.testing.expect(!disp.hasClosedCaptions());
    try std.testing.expect(!disp.hasSignLanguage());

    disp.descriptions = true;
    try std.testing.expect(disp.hasAudioDescription());

    disp.captions = true;
    try std.testing.expect(disp.hasClosedCaptions());

    disp.sign_language = true;
    try std.testing.expect(disp.hasSignLanguage());
}

test "AudioDescriptionTrack basic" {
    const allocator = std.testing.allocator;
    var track = AudioDescriptionTrack.init(allocator, 1);
    defer track.deinit();

    track.setLanguage(.{ 'f', 'r', 'a' });
    try track.setDescription("French Audio Description");
    track.setTimingOffset(-500);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 'f', 'r', 'a' }, &track.info.language);
    try std.testing.expectEqual(@as(i32, -500), track.info.timing_offset_ms);
}

test "SignLanguageTrack overlay rect" {
    const allocator = std.testing.allocator;
    var track = SignLanguageTrack.init(allocator, 2);
    defer track.deinit();

    track.setSize(.medium);
    track.setPosition(.bottom_right);

    const rect = track.getOverlayRect(1920, 1080);
    try std.testing.expect(rect.w > 0);
    try std.testing.expect(rect.h > 0);
    try std.testing.expect(rect.x + rect.w < 1920);
}

test "CaptionHandler init" {
    const allocator = std.testing.allocator;
    var handler = CaptionHandler.init(allocator);
    defer handler.deinit();

    handler.setFormat(.cea708);
    handler.setEmbedMode(.sei_nalu);

    try std.testing.expectEqual(CaptionFormat.cea708, handler.format);
    try std.testing.expectEqual(CaptionEmbedMode.sei_nalu, handler.embed_mode);
}

test "AccessibilityManager" {
    const allocator = std.testing.allocator;
    var manager = AccessibilityManager.init(allocator);
    defer manager.deinit();

    _ = try manager.addAudioDescriptionTrack(1);
    _ = try manager.addSignLanguageTrack(2);

    const summary = manager.getSummary();
    try std.testing.expect(summary.has_audio_description);
    try std.testing.expect(summary.has_sign_language);
    try std.testing.expectEqual(@as(u32, 1), summary.audio_description_count);
    try std.testing.expectEqual(@as(u32, 1), summary.sign_language_count);
}
