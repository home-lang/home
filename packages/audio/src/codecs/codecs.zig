// Home Audio Library - Codec Exports
// Full decoder implementations for MP3, AAC, Vorbis, and Opus

pub const mp3 = @import("mp3_decoder.zig");
pub const aac = @import("aac_decoder.zig");
pub const vorbis = @import("vorbis_decoder.zig");
pub const opus = @import("opus_decoder.zig");

pub const Mp3Decoder = mp3.Mp3Decoder;
pub const AacDecoder = aac.AacDecoder;
pub const VorbisDecoder = vorbis.VorbisDecoder;
pub const OpusDecoder = opus.OpusDecoder;

test {
    _ = mp3;
    _ = aac;
    _ = vorbis;
    _ = opus;
}
