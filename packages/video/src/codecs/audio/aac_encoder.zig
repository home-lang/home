//! Legacy compatibility entry point. Its old fixed-width spectral payload was
//! not an AAC bitstream. Use packages/audio/src/encoding/native_aac.zig instead.
const std = @import("std");
const AudioFrame = @import("../../core/frame.zig").AudioFrame;
pub const AacFullEncoder = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    bitrate: u32,
    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, bitrate: u32) AacFullEncoder {
        return .{ .allocator = allocator, .sample_rate = sample_rate, .channels = channels, .bitrate = bitrate };
    }
    pub fn deinit(self: *AacFullEncoder) void {
        _ = self;
    }
    pub fn encode(self: *AacFullEncoder, input: *const AudioFrame) ![]u8 {
        _ = self;
        _ = input;
        return error.UnsupportedLegacyEncoder;
    }
    pub fn encodeAdts(self: *AacFullEncoder, input: *const AudioFrame) ![]u8 {
        return self.encode(input);
    }
};
