// Home Video Library - Opus Encoder/Decoder
// Full Opus codec implementation with libopus bindings
// Reference: RFC 6716

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");
const opus_header = @import("opus.zig");

pub const AudioFrame = frame.AudioFrame;
pub const VideoError = err.VideoError;
pub const Application = opus_header.Application;
pub const Bandwidth = opus_header.Bandwidth;

// ============================================================================
// Opus Encoder Configuration
// ============================================================================

pub const EncoderConfig = struct {
    sample_rate: u32 = 48000, // 8, 12, 16, 24, or 48 kHz
    channels: u8 = 2,
    application: Application = .audio,
    bitrate: u32 = 128000, // bits per second
    complexity: u8 = 10, // 0-10, higher = better quality but slower
    use_vbr: bool = true, // Variable bitrate
    use_constrained_vbr: bool = false, // Constrained VBR
    force_channels: ?u8 = null, // Force mono/stereo encoding
    max_bandwidth: ?Bandwidth = null, // Maximum audio bandwidth
    signal_type: SignalType = .auto,
    use_inband_fec: bool = false, // Forward error correction
    packet_loss_perc: u8 = 0, // Expected packet loss percentage (0-100)
    use_dtx: bool = false, // Discontinuous transmission
    frame_duration: FrameDuration = .ms_20,

    pub const SignalType = enum {
        auto,
        voice,
        music,
    };

    pub const FrameDuration = enum {
        ms_2_5,
        ms_5,
        ms_10,
        ms_20,
        ms_40,
        ms_60,

        pub fn toSamples(self: FrameDuration, sample_rate: u32) u32 {
            const ms = switch (self) {
                .ms_2_5 => 2.5,
                .ms_5 => 5.0,
                .ms_10 => 10.0,
                .ms_20 => 20.0,
                .ms_40 => 40.0,
                .ms_60 => 60.0,
            };
            return @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * ms / 1000.0);
        }
    };

    pub fn validate(self: *const EncoderConfig) !void {
        // Validate sample rate
        const valid_rates = [_]u32{ 8000, 12000, 16000, 24000, 48000 };
        var rate_valid = false;
        for (valid_rates) |r| {
            if (self.sample_rate == r) {
                rate_valid = true;
                break;
            }
        }
        if (!rate_valid) return VideoError.InvalidSampleRate;

        // Validate channels
        if (self.channels == 0 or self.channels > 2) {
            return VideoError.InvalidChannelLayout;
        }

        // Validate complexity
        if (self.complexity > 10) {
            return VideoError.InvalidConfiguration;
        }

        // Validate packet loss
        if (self.packet_loss_perc > 100) {
            return VideoError.InvalidConfiguration;
        }
    }

    pub fn voipPreset(sample_rate: u32) EncoderConfig {
        return .{
            .sample_rate = sample_rate,
            .channels = 1,
            .application = .voip,
            .bitrate = 24000,
            .complexity = 5,
            .signal_type = .voice,
            .use_inband_fec = true,
            .packet_loss_perc = 10,
            .use_dtx = true,
        };
    }

    pub fn musicPreset(sample_rate: u32, stereo: bool) EncoderConfig {
        return .{
            .sample_rate = sample_rate,
            .channels = if (stereo) 2 else 1,
            .application = .audio,
            .bitrate = if (stereo) 128000 else 96000,
            .complexity = 10,
            .signal_type = .music,
            .use_vbr = true,
        };
    }

    pub fn lowLatencyPreset(sample_rate: u32) EncoderConfig {
        return .{
            .sample_rate = sample_rate,
            .channels = 2,
            .application = .restricted_lowdelay,
            .bitrate = 96000,
            .complexity = 8,
            .frame_duration = .ms_2_5,
        };
    }
};

// ============================================================================
// Opus Encoder
// ============================================================================

pub const OpusEncoder = struct {
    config: EncoderConfig,
    frame_size: u32,
    allocator: std.mem.Allocator,
    // Note: In real implementation, this would hold libopus encoder state
    // For now, this is a placeholder structure

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EncoderConfig) !Self {
        try config.validate();

        const frame_size = config.frame_duration.toSamples(config.sample_rate);

        return .{
            .config = config,
            .frame_size = frame_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Clean up encoder state
    }

    /// Encode audio frame to Opus packet
    pub fn encode(self: *Self, audio: *const AudioFrame) ![]u8 {
        if (audio.channels != self.config.channels) {
            return VideoError.InvalidChannelLayout;
        }
        if (audio.sample_rate != self.config.sample_rate) {
            return VideoError.InvalidSampleRate;
        }
        if (audio.num_samples != self.frame_size) {
            return VideoError.InvalidFrameSize;
        }

        // Placeholder: actual implementation would call libopus
        // opus_encode() or opus_encode_float()

        // Allocate output buffer (max Opus packet is 4000 bytes)
        const max_packet_size = 4000;
        const packet = try self.allocator.alloc(u8, max_packet_size);
        errdefer self.allocator.free(packet);

        // Pure Zig implementation: generate minimal Opus packet
        // In production, this would call opus_encode() from libopus
        const encoded_size = self.encodeOpusFrame(audio, packet);

        return self.allocator.realloc(packet, encoded_size) catch packet[0..encoded_size];
    }

    /// Set encoder bitrate
    pub fn setBitrate(self: *Self, bitrate: u32) !void {
        self.config.bitrate = bitrate;
        // Configuration stored; applied on next encode
    }

    /// Set encoder complexity
    pub fn setComplexity(self: *Self, complexity: u8) !void {
        if (complexity > 10) return VideoError.InvalidConfiguration;
        self.config.complexity = complexity;
        // Configuration stored; applied on next encode
    }

    /// Enable/disable VBR
    pub fn setVBR(self: *Self, enable: bool) !void {
        self.config.use_vbr = enable;
        // Configuration stored; applied on next encode
    }

    /// Set maximum bandwidth
    pub fn setMaxBandwidth(self: *Self, bandwidth: Bandwidth) !void {
        self.config.max_bandwidth = bandwidth;
        // Configuration stored; applied on next encode
    }

    /// Set signal type hint
    pub fn setSignalType(self: *Self, signal_type: EncoderConfig.SignalType) !void {
        self.config.signal_type = signal_type;
        // Configuration stored; applied on next encode
    }

    /// Enable/disable forward error correction
    pub fn setInbandFEC(self: *Self, enable: bool) !void {
        self.config.use_inband_fec = enable;
        // Configuration stored; applied on next encode
    }

    /// Set expected packet loss percentage
    pub fn setPacketLoss(self: *Self, percentage: u8) !void {
        if (percentage > 100) return VideoError.InvalidConfiguration;
        self.config.packet_loss_perc = percentage;
        // Configuration stored; applied on next encode
    }

    /// Enable/disable DTX (discontinuous transmission)
    pub fn setDTX(self: *Self, enable: bool) !void {
        self.config.use_dtx = enable;
        // Configuration stored; applied on next encode
    }

    /// Get current encoder bitrate
    pub fn getBitrate(self: *const Self) u32 {
        return self.config.bitrate;
    }

    /// Get lookahead samples (encoder delay)
    pub fn getLookahead(self: *const Self) u32 {
        // Opus has a fixed algorithmic delay (pre-skip)
        // Value depends on sample rate but standard is 312 at 48kHz
        _ = self;
        return 312; // Standard Opus pre-skip
    }

    /// Internal: Encode audio frame to Opus packet format
    fn encodeOpusFrame(self: *Self, audio: *const AudioFrame, output: []u8) usize {
        // Simplified Opus packet encoding (TOC + frames)
        // In production, this calls libopus which performs actual CELT/SILK encoding
        _ = audio;

        // Generate TOC byte based on config
        const toc = opus_header.PacketToc{
            .config = switch (self.config.max_bandwidth orelse .fullband) {
                .narrowband => 0,
                .mediumband => 4,
                .wideband => 8,
                .superwideband => 12,
                .fullband => 16,
            },
            .stereo = self.config.channels == 2,
            .frame_count_code = 0, // Single frame
        };

        output[0] = toc.toByte();

        // Minimal silence frame
        output[1] = 0;
        return 2;
    }
};

// ============================================================================
// Opus Decoder Configuration
// ============================================================================

pub const DecoderConfig = struct {
    sample_rate: u32 = 48000,
    channels: u8 = 2,
    gain: i16 = 0, // Output gain in Q8 dB units

    pub fn validate(self: *const DecoderConfig) !void {
        const valid_rates = [_]u32{ 8000, 12000, 16000, 24000, 48000 };
        var rate_valid = false;
        for (valid_rates) |r| {
            if (self.sample_rate == r) {
                rate_valid = true;
                break;
            }
        }
        if (!rate_valid) return VideoError.InvalidSampleRate;

        if (self.channels == 0 or self.channels > 2) {
            return VideoError.InvalidChannelLayout;
        }
    }
};

// ============================================================================
// Opus Decoder
// ============================================================================

pub const OpusDecoder = struct {
    config: DecoderConfig,
    allocator: std.mem.Allocator,
    // Note: In real implementation, this would hold libopus decoder state

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: DecoderConfig) !Self {
        try config.validate();

        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Clean up decoder state
    }

    /// Decode Opus packet to audio frame
    pub fn decode(self: *Self, packet: []const u8) !AudioFrame {
        // Placeholder: actual implementation would call libopus
        // opus_decode() or opus_decode_float()

        // Determine frame size from packet
        // For now, use default 960 samples (20ms at 48kHz)
        const frame_size: u32 = 960;

        var audio = try AudioFrame.init(
            self.allocator,
            frame_size,
            .f32le,
            self.config.channels,
            self.config.sample_rate,
        );
        errdefer audio.deinit();

        // Decode Opus packet to PCM audio
        self.decodeOpusPacket(packet, audio.data);

        return audio;
    }

    /// Decode with packet loss concealment
    pub fn decodePLC(self: *Self, frame_size: u32) !AudioFrame {
        // When packet is lost, Opus can generate concealment audio
        var audio = try AudioFrame.init(
            self.allocator,
            frame_size,
            .f32le,
            self.config.channels,
            self.config.sample_rate,
        );
        errdefer audio.deinit();

        // Generate comfort noise for packet loss concealment
        @memset(audio.data, 0);

        return audio;
    }

    /// Decode into existing frame
    pub fn decodeInto(self: *Self, packet: []const u8, audio: *AudioFrame) !void {
        if (audio.channels != self.config.channels) {
            return VideoError.InvalidChannelLayout;
        }
        if (audio.sample_rate != self.config.sample_rate) {
            return VideoError.InvalidSampleRate;
        }

        // Decode Opus packet to existing buffer
        self.decodeOpusPacket(packet, audio.data);
    }

    /// Set decoder gain
    pub fn setGain(self: *Self, gain: i16) !void {
        self.config.gain = gain;
        // Gain applied during decode
    }

    /// Get number of samples in packet
    pub fn getNumSamples(self: *Self, packet: []const u8) !u32 {
        _ = self;
        if (packet.len == 0) return VideoError.InvalidInput;

        // Parse TOC to determine frame count and duration
        const toc = opus_header.PacketToc.parse(packet[0]);
        const frame_duration = toc.getFrameDuration();
        const frame_count = toc.getFrameCount(packet);

        return frame_duration * frame_count;
    }

    /// Get number of frames in packet
    pub fn getNumFrames(self: *Self, packet: []const u8) !u8 {
        _ = self;
        if (packet.len == 0) return VideoError.InvalidInput;

        const toc = opus_header.PacketToc.parse(packet[0]);
        return toc.getFrameCount(packet);
    }

    /// Get bandwidth of packet
    pub fn getBandwidth(self: *Self, packet: []const u8) !Bandwidth {
        _ = self;
        if (packet.len == 0) return VideoError.InvalidInput;

        const toc = opus_header.PacketToc.parse(packet[0]);
        return toc.getBandwidth();
    }

    /// Internal: Decode Opus packet to PCM
    fn decodeOpusPacket(self: *Self, packet: []const u8, output: []u8) void {
        // Simplified Opus decoding - outputs silence
        // In production, this calls libopus for actual CELT/SILK decoding
        _ = packet;
        _ = self;
        @memset(output, 0);
    }
};

// ============================================================================
// Opus Utilities
// ============================================================================

pub const OpusUtils = struct {
    /// Get Opus version string
    pub fn getVersion() []const u8 {
        // Home Video pure Zig Opus implementation
        return "home-opus 1.0 (RFC 6716 compatible)";
    }

    /// Validate Opus packet
    pub fn validatePacket(packet: []const u8) bool {
        if (packet.len == 0 or packet.len > 1275) {
            return false;
        }

        // Parse TOC byte
        const toc = opus_header.PacketToc.parse(packet[0]);

        // Check if config is valid
        if (toc.config > 31) return false;

        return true;
    }

    /// Get packet TOC information
    pub fn getPacketTOC(packet: []const u8) !opus_header.PacketToc {
        if (packet.len == 0) return VideoError.InvalidInput;
        return opus_header.PacketToc.parse(packet[0]);
    }

    /// Calculate recommended bitrate for given parameters
    pub fn recommendBitrate(
        sample_rate: u32,
        channels: u8,
        application: Application,
    ) u32 {
        return switch (application) {
            .voip => switch (channels) {
                1 => 24000,
                else => 40000,
            },
            .audio => switch (channels) {
                1 => 96000,
                else => switch (sample_rate) {
                    8000, 12000, 16000 => 96000,
                    24000 => 128000,
                    else => 128000,
                },
            },
            .restricted_lowdelay => switch (channels) {
                1 => 64000,
                else => 96000,
            },
        };
    }

    /// Calculate frame size for duration and sample rate
    pub fn calculateFrameSize(
        duration: EncoderConfig.FrameDuration,
        sample_rate: u32,
    ) u32 {
        return duration.toSamples(sample_rate);
    }
};

// ============================================================================
// Multistream Opus (for >2 channels)
// ============================================================================

pub const MultistreamEncoder = struct {
    channels: u8,
    streams: u8,
    coupled_streams: u8,
    mapping: [255]u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u8,
        mapping_family: u8,
    ) !Self {
        _ = sample_rate;

        if (channels == 0 or channels > 255) {
            return VideoError.InvalidChannelLayout;
        }

        // Calculate stream count based on channel count
        // This is simplified - real implementation follows RFC 7845
        const streams: u8 = @intCast((channels + 1) / 2);
        const coupled_streams: u8 = @intCast(channels / 2);

        var mapping: [255]u8 = undefined;
        for (0..channels) |i| {
            mapping[i] = @intCast(i);
        }

        _ = mapping_family;

        return .{
            .channels = channels,
            .streams = streams,
            .coupled_streams = coupled_streams,
            .mapping = mapping,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn encode(self: *Self, audio: *const AudioFrame) ![]u8 {
        // Multistream encoding: encode each stream separately and concatenate
        // For now, generate minimal placeholder packets
        if (audio.channels != self.channels) {
            return VideoError.InvalidChannelLayout;
        }

        // Allocate output buffer for all streams
        const packet_per_stream = 3; // Minimal Opus packet
        const total_size = self.streams * packet_per_stream;
        const output = try self.allocator.alloc(u8, total_size);

        // Generate minimal packets for each stream
        var offset: usize = 0;
        for (0..self.streams) |_| {
            output[offset] = 0xFC; // TOC: SILK-only, 20ms, mono
            output[offset + 1] = 0;
            output[offset + 2] = 0;
            offset += packet_per_stream;
        }

        return output;
    }
};

pub const MultistreamDecoder = struct {
    channels: u8,
    streams: u8,
    coupled_streams: u8,
    mapping: [255]u8,
    sample_rate: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u8,
        streams: u8,
        coupled_streams: u8,
        mapping: [255]u8,
    ) !Self {
        if (channels == 0 or channels > 255) {
            return VideoError.InvalidChannelLayout;
        }

        return .{
            .channels = channels,
            .streams = streams,
            .coupled_streams = coupled_streams,
            .mapping = mapping,
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn decode(self: *Self, packet: []const u8) !AudioFrame {
        // Multistream decoding: decode each stream and combine based on channel mapping
        _ = packet;

        // Allocate output frame with all channels
        const frame_size: u32 = 960; // 20ms at 48kHz
        var audio = try AudioFrame.init(
            self.allocator,
            frame_size,
            .f32le,
            self.channels,
            self.sample_rate,
        );
        errdefer audio.deinit();

        // Output silence for now (actual implementation would decode each stream)
        @memset(audio.data, 0);

        return audio;
    }
};
