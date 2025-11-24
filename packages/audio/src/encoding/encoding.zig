// Home Audio Library - Encoding Module
// Pure Zig audio encoders for MP3, AAC, and Opus

pub const mp3_encoder = @import("mp3_encoder.zig");
pub const aac_encoder = @import("aac_encoder.zig");
pub const opus_encoder = @import("opus_encoder.zig");

// Re-export main types
pub const Mp3Encoder = mp3_encoder.Mp3Encoder;
pub const Mp3Quality = mp3_encoder.Mp3Quality;
pub const Mp3ChannelMode = mp3_encoder.Mp3ChannelMode;
pub const Mp3FrameHeader = mp3_encoder.Mp3FrameHeader;
pub const Id3v2Writer = mp3_encoder.Id3v2Writer;

pub const AacEncoder = aac_encoder.AacEncoder;
pub const AacQuality = aac_encoder.AacQuality;
pub const AacProfile = aac_encoder.AacProfile;
pub const AdtsHeader = aac_encoder.AdtsHeader;
pub const AudioSpecificConfig = aac_encoder.AudioSpecificConfig;
pub const SampleRateIndex = aac_encoder.SampleRateIndex;
pub const ChannelConfig = aac_encoder.ChannelConfig;

pub const OpusEncoder = opus_encoder.OpusEncoder;
pub const OpusQuality = opus_encoder.OpusQuality;
pub const OpusApplication = opus_encoder.OpusApplication;
pub const OpusBandwidth = opus_encoder.OpusBandwidth;
pub const OpusFrameSize = opus_encoder.OpusFrameSize;
pub const OpusToc = opus_encoder.OpusToc;
pub const OggOpusWriter = opus_encoder.OggOpusWriter;

test "encoding module" {
    _ = mp3_encoder;
    _ = aac_encoder;
    _ = opus_encoder;
}
