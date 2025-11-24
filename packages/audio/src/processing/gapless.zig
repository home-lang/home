// Home Audio Library - Gapless Playback Support
// Tools for seamless track transitions

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Track gap information
pub const GapInfo = struct {
    leading_silence_samples: usize, // Silence at start
    trailing_silence_samples: usize, // Silence at end
    encoder_delay: usize, // Encoder padding (MP3/AAC)
    encoder_padding: usize, // End padding
    total_samples: usize, // Total samples in file

    /// Get actual audio start position
    pub fn getAudioStart(self: GapInfo) usize {
        return self.leading_silence_samples + self.encoder_delay;
    }

    /// Get actual audio end position
    pub fn getAudioEnd(self: GapInfo) usize {
        if (self.total_samples > self.trailing_silence_samples + self.encoder_padding) {
            return self.total_samples - self.trailing_silence_samples - self.encoder_padding;
        }
        return self.total_samples;
    }

    /// Get actual audio length
    pub fn getAudioLength(self: GapInfo) usize {
        const start = self.getAudioStart();
        const end = self.getAudioEnd();
        return if (end > start) end - start else 0;
    }
};

/// Gapless playback manager
pub const GaplessPlayer = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Current track info
    current_gap_info: ?GapInfo,
    next_gap_info: ?GapInfo,

    // Buffer for seamless transition
    overlap_buffer: []f32,
    overlap_samples: usize,

    // State
    samples_played: usize,
    is_transitioning: bool,

    // Pre-buffer for next track
    next_track_buffer: []f32,
    next_track_samples: usize,

    const Self = @This();

    pub const OVERLAP_DURATION_MS = 10;

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        const overlap_size = @as(usize, @intFromFloat(OVERLAP_DURATION_MS * @as(f32, @floatFromInt(sample_rate)) / 1000.0)) * channels;

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .current_gap_info = null,
            .next_gap_info = null,
            .overlap_buffer = try allocator.alloc(f32, overlap_size),
            .overlap_samples = 0,
            .samples_played = 0,
            .is_transitioning = false,
            .next_track_buffer = try allocator.alloc(f32, overlap_size * 2),
            .next_track_samples = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.overlap_buffer);
        self.allocator.free(self.next_track_buffer);
    }

    /// Set current track's gap information
    pub fn setCurrentTrack(self: *Self, gap_info: GapInfo) void {
        self.current_gap_info = gap_info;
        self.samples_played = 0;
    }

    /// Set next track's gap information for seamless transition
    pub fn setNextTrack(self: *Self, gap_info: GapInfo) void {
        self.next_gap_info = gap_info;
    }

    /// Pre-buffer samples from next track
    pub fn preBufferNextTrack(self: *Self, samples: []const f32) void {
        const to_copy = @min(samples.len, self.next_track_buffer.len - self.next_track_samples);
        @memcpy(self.next_track_buffer[self.next_track_samples .. self.next_track_samples + to_copy], samples[0..to_copy]);
        self.next_track_samples += to_copy;
    }

    /// Process output buffer, handling track transitions
    pub fn process(self: *Self, output: []f32, current_track_samples: []const f32) void {
        const current_info = self.current_gap_info orelse {
            // No gap info, just copy
            @memcpy(output[0..@min(output.len, current_track_samples.len)], current_track_samples[0..@min(output.len, current_track_samples.len)]);
            return;
        };

        const audio_end = current_info.getAudioEnd() * self.channels;
        var output_pos: usize = 0;
        var input_pos: usize = 0;

        // Copy current track samples
        while (output_pos < output.len and input_pos < current_track_samples.len) {
            const current_sample_pos = self.samples_played + input_pos / self.channels;

            // Check if we're near the end and should start transition
            if (current_sample_pos * self.channels >= audio_end) {
                self.is_transitioning = true;
                break;
            }

            output[output_pos] = current_track_samples[input_pos];
            output_pos += 1;
            input_pos += 1;
        }

        self.samples_played += input_pos / self.channels;

        // Handle transition to next track
        if (self.is_transitioning and self.next_gap_info != null and self.next_track_samples > 0) {
            const next_info = self.next_gap_info.?;
            const next_start = next_info.getAudioStart() * self.channels;

            // Copy from next track buffer (skipping leading silence/delay)
            var next_pos = next_start;
            while (output_pos < output.len and next_pos < self.next_track_samples) {
                output[output_pos] = self.next_track_buffer[next_pos];
                output_pos += 1;
                next_pos += 1;
            }
        }

        // Fill remaining with silence
        while (output_pos < output.len) {
            output[output_pos] = 0;
            output_pos += 1;
        }
    }

    /// Check if current track is finished
    pub fn isTrackFinished(self: *Self) bool {
        if (self.current_gap_info) |info| {
            return self.samples_played >= info.getAudioEnd();
        }
        return false;
    }

    /// Advance to next track
    pub fn advanceToNextTrack(self: *Self) void {
        self.current_gap_info = self.next_gap_info;
        self.next_gap_info = null;
        self.samples_played = 0;
        self.is_transitioning = false;
        self.next_track_samples = 0;
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        self.current_gap_info = null;
        self.next_gap_info = null;
        self.samples_played = 0;
        self.is_transitioning = false;
        self.overlap_samples = 0;
        self.next_track_samples = 0;
        @memset(self.overlap_buffer, 0);
        @memset(self.next_track_buffer, 0);
    }
};

/// Gap analyzer for detecting silence and encoder padding
pub const GapAnalyzer = struct {
    sample_rate: u32,
    channels: u8,
    silence_threshold: f32,

    const Self = @This();

    pub fn init(sample_rate: u32, channels: u8) Self {
        return Self{
            .sample_rate = sample_rate,
            .channels = channels,
            .silence_threshold = 0.0001, // About -80dB
        };
    }

    /// Set silence detection threshold
    pub fn setThreshold(self: *Self, threshold_db: f32) void {
        self.silence_threshold = math.pow(f32, 10.0, threshold_db / 20.0);
    }

    /// Analyze audio for gap information
    pub fn analyze(self: *Self, samples: []const f32) GapInfo {
        const num_frames = samples.len / self.channels;

        // Find leading silence
        var leading_silence: usize = 0;
        for (0..num_frames) |frame| {
            var is_silent = true;
            for (0..self.channels) |ch| {
                if (@abs(samples[frame * self.channels + ch]) > self.silence_threshold) {
                    is_silent = false;
                    break;
                }
            }
            if (!is_silent) break;
            leading_silence += 1;
        }

        // Find trailing silence
        var trailing_silence: usize = 0;
        var frame = num_frames;
        while (frame > leading_silence) {
            frame -= 1;
            var is_silent = true;
            for (0..self.channels) |ch| {
                if (@abs(samples[frame * self.channels + ch]) > self.silence_threshold) {
                    is_silent = false;
                    break;
                }
            }
            if (!is_silent) break;
            trailing_silence += 1;
        }

        return GapInfo{
            .leading_silence_samples = leading_silence,
            .trailing_silence_samples = trailing_silence,
            .encoder_delay = 0, // Would need format-specific parsing
            .encoder_padding = 0,
            .total_samples = num_frames,
        };
    }

    /// Analyze with known encoder delay (from ID3/MP4 metadata)
    pub fn analyzeWithEncoderInfo(
        self: *Self,
        samples: []const f32,
        encoder_delay: usize,
        encoder_padding: usize,
    ) GapInfo {
        var info = self.analyze(samples);
        info.encoder_delay = encoder_delay;
        info.encoder_padding = encoder_padding;
        return info;
    }
};

/// MP3 gapless info (from LAME header)
pub const Mp3GaplessInfo = struct {
    encoder_delay: u16, // Samples to skip at start (typically 576 or 1152)
    encoder_padding: u16, // Samples to skip at end
    total_samples: u64, // Total samples in original audio

    /// Parse from LAME header in Xing/Info frame
    pub fn fromLameHeader(data: []const u8) ?Mp3GaplessInfo {
        // LAME header is typically at offset 0x9C in Xing frame
        if (data.len < 0x9C + 12) return null;

        // Check for "LAME" identifier
        if (!std.mem.eql(u8, data[0x9C .. 0x9C + 4], "LAME")) return null;

        // Encoder delay and padding are at offset 0xAD
        const delay_padding = @as(u32, data[0xAD]) << 16 | @as(u32, data[0xAE]) << 8 | @as(u32, data[0xAF]);

        return Mp3GaplessInfo{
            .encoder_delay = @intCast((delay_padding >> 12) & 0xFFF),
            .encoder_padding = @intCast(delay_padding & 0xFFF),
            .total_samples = 0, // Would need to calculate from frame count
        };
    }
};

/// AAC gapless info (from iTunSMPB atom)
pub const AacGaplessInfo = struct {
    encoder_delay: u32,
    encoder_padding: u32,
    total_samples: u64,

    /// Parse from iTunSMPB metadata
    pub fn fromITunSMPB(data: []const u8) ?AacGaplessInfo {
        // Format: " 00000000 XXXXXXXX YYYYYYYY ZZZZZZZZZZZZZZZZ"
        // X = encoder delay, Y = padding, Z = total samples
        if (data.len < 48) return null;

        // Parse hex values (simplified)
        var info = AacGaplessInfo{
            .encoder_delay = 0,
            .encoder_padding = 0,
            .total_samples = 0,
        };

        // Skip leading space and first 8 zeros
        var pos: usize = 1;
        while (pos < data.len and data[pos] == ' ') pos += 1;
        pos += 8; // Skip zeros
        while (pos < data.len and data[pos] == ' ') pos += 1;

        // Parse encoder delay
        var val: u32 = 0;
        while (pos < data.len and pos < 20) : (pos += 1) {
            const c = data[pos];
            if (c == ' ') break;
            val = val * 16 + (if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else 0);
        }
        info.encoder_delay = val;

        return info;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GapInfo calculations" {
    const info = GapInfo{
        .leading_silence_samples = 100,
        .trailing_silence_samples = 50,
        .encoder_delay = 576,
        .encoder_padding = 288,
        .total_samples = 100000,
    };

    try std.testing.expectEqual(@as(usize, 676), info.getAudioStart());
    try std.testing.expectEqual(@as(usize, 99662), info.getAudioEnd());
}

test "GaplessPlayer init" {
    const allocator = std.testing.allocator;

    var player = try GaplessPlayer.init(allocator, 44100, 2);
    defer player.deinit();

    const info = GapInfo{
        .leading_silence_samples = 0,
        .trailing_silence_samples = 0,
        .encoder_delay = 0,
        .encoder_padding = 0,
        .total_samples = 1000,
    };
    player.setCurrentTrack(info);
}

test "GapAnalyzer analyze" {
    var analyzer = GapAnalyzer.init(44100, 1);

    // Create audio with silence at start and end
    var samples: [1000]f32 = undefined;
    for (0..100) |i| {
        samples[i] = 0; // Leading silence
    }
    for (100..900) |i| {
        samples[i] = 0.5; // Audio
    }
    for (900..1000) |i| {
        samples[i] = 0; // Trailing silence
    }

    const info = analyzer.analyze(&samples);
    try std.testing.expectEqual(@as(usize, 100), info.leading_silence_samples);
    try std.testing.expectEqual(@as(usize, 100), info.trailing_silence_samples);
}
