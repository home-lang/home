// Home Video Library
// A comprehensive, dependency-free video/audio processing library
// for the Home programming language, implemented in pure Zig.

const std = @import("std");

// ============================================================================
// Core Types
// ============================================================================

pub const types = @import("core/types.zig");
pub const VideoFormat = types.VideoFormat;
pub const AudioFormat = types.AudioFormat;
pub const PixelFormat = types.PixelFormat;
pub const SampleFormat = types.SampleFormat;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Rational = types.Rational;
pub const ColorSpace = types.ColorSpace;
pub const ColorRange = types.ColorRange;
pub const ColorPrimaries = types.ColorPrimaries;
pub const ColorTransfer = types.ColorTransfer;
pub const ChromaLocation = types.ChromaLocation;
pub const ChannelLayout = types.ChannelLayout;
pub const VideoCodec = types.VideoCodec;
pub const AudioCodec = types.AudioCodec;
pub const QualityPreset = types.QualityPreset;

// ============================================================================
// Frame Types
// ============================================================================

pub const frame = @import("core/frame.zig");
pub const VideoFrame = frame.VideoFrame;
pub const AudioFrame = frame.AudioFrame;

// ============================================================================
// Packet and Stream Types
// ============================================================================

pub const packet = @import("core/packet.zig");
pub const Packet = packet.Packet;
pub const PacketType = packet.PacketType;
pub const PacketFlags = packet.PacketFlags;
pub const Stream = packet.Stream;
pub const StreamType = packet.StreamType;
pub const StreamDisposition = packet.StreamDisposition;
pub const StreamInfo = packet.StreamInfo;
pub const VideoStreamInfo = packet.VideoStreamInfo;
pub const AudioStreamInfo = packet.AudioStreamInfo;
pub const SubtitleStreamInfo = packet.SubtitleStreamInfo;
pub const MediaFile = packet.MediaFile;

// ============================================================================
// Error Types
// ============================================================================

pub const err = @import("core/error.zig");
pub const VideoError = err.VideoError;
pub const ErrorContext = err.ErrorContext;
pub const Result = err.Result;
pub const makeError = err.makeError;
pub const isRecoverable = err.isRecoverable;
pub const getUserMessage = err.getUserMessage;

// ============================================================================
// I/O Types
// ============================================================================

pub const source = @import("io/source.zig");
pub const Source = source.Source;
pub const BufferSource = source.BufferSource;
pub const FileSource = source.FileSource;
pub const BufferedSource = source.BufferedSource;

pub const target = @import("io/target.zig");
pub const Target = target.Target;
pub const BufferTarget = target.BufferTarget;
pub const FileTarget = target.FileTarget;
pub const NullTarget = target.NullTarget;
pub const CallbackTarget = target.CallbackTarget;

// ============================================================================
// Container Formats
// ============================================================================

pub const wav = @import("containers/wav.zig");
pub const WavReader = wav.WavReader;
pub const WavWriter = wav.WavWriter;
pub const WavHeader = wav.WavHeader;

pub const mp4 = @import("containers/mp4.zig");
pub const Mp4Reader = mp4.Mp4Reader;
pub const BoxType = mp4.BoxType;
pub const BoxHeader = mp4.BoxHeader;
pub const TrackInfo = mp4.TrackInfo;
pub const TrackType = mp4.TrackType;
pub const SampleTable = mp4.SampleTable;

pub const mp4_muxer = @import("containers/mp4_muxer.zig");
pub const Mp4Muxer = mp4_muxer.Mp4Muxer;
pub const VideoTrackConfig = mp4_muxer.VideoTrackConfig;
pub const AudioTrackConfig = mp4_muxer.AudioTrackConfig;
pub const MuxerSample = mp4_muxer.Sample;

pub const webm = @import("containers/webm.zig");
pub const WebmReader = webm.WebmReader;
pub const WebmElementId = webm.ElementId;
pub const WebmTrackType = webm.TrackType;
pub const WebmTrackInfo = webm.TrackInfo;
pub const WebmSegmentInfo = webm.SegmentInfo;
pub const WebmCuePoint = webm.CuePoint;
pub const WebmCodecId = webm.CodecId;
pub const isWebm = webm.isWebm;
pub const isMatroska = webm.isMatroska;

pub const ogg = @import("containers/ogg.zig");
pub const OggReader = ogg.OggReader;
pub const OggWriter = ogg.OggWriter;
pub const OggPageHeader = ogg.PageHeader;
pub const OggStreamType = ogg.StreamType;
pub const OggStreamInfo = ogg.StreamInfo;
pub const OggVorbisInfo = ogg.VorbisInfo;
pub const isOgg = ogg.isOgg;

// ============================================================================
// Audio Codecs
// ============================================================================

pub const pcm = @import("codecs/audio/pcm.zig");
pub const PcmDecoder = pcm.PcmDecoder;
pub const PcmEncoder = pcm.PcmEncoder;
pub const convertSamples = pcm.convertSamples;
pub const decodeAlaw = pcm.decodeAlaw;
pub const decodeUlaw = pcm.decodeUlaw;
pub const encodeAlaw = pcm.encodeAlaw;
pub const encodeUlaw = pcm.encodeUlaw;
pub const interleavedToPlanar = pcm.interleavedToPlanar;
pub const planarToInterleaved = pcm.planarToInterleaved;

pub const aac = @import("codecs/audio/aac.zig");
pub const AacDecoder = aac.AacDecoder;
pub const AacEncoder = aac.AacEncoder;
pub const AudioSpecificConfig = aac.AudioSpecificConfig;
pub const AdtsHeader = aac.AdtsHeader;
pub const AdtsParser = aac.AdtsParser;
pub const AudioObjectType = aac.AudioObjectType;

pub const opus = @import("codecs/audio/opus.zig");
pub const OpusIdHeader = opus.IdHeader;
pub const OpusCommentHeader = opus.CommentHeader;
pub const OpusPacketToc = opus.PacketToc;
pub const OpusDOpsBox = opus.DOpsBox;
pub const OpusBandwidth = opus.Bandwidth;
pub const OpusFrameDuration = opus.FrameDuration;
pub const OpusChannelMappingFamily = opus.ChannelMappingFamily;

pub const flac = @import("codecs/audio/flac.zig");
pub const FlacReader = flac.FlacReader;
pub const FlacStreamInfo = flac.StreamInfo;
pub const FlacMetadataBlockHeader = flac.MetadataBlockHeader;
pub const FlacBlockType = flac.BlockType;
pub const FlacSeekPoint = flac.SeekPoint;
pub const FlacPicture = flac.Picture;
pub const FlacPictureType = flac.PictureType;
pub const isFlac = flac.isFlac;

// ============================================================================
// Video Codecs
// ============================================================================

pub const h264 = @import("codecs/video/h264.zig");
pub const H264NalIterator = h264.H264NalIterator;
pub const H264NalUnitType = h264.NalUnitType;
pub const H264NalUnitHeader = h264.NalUnitHeader;
pub const H264Sps = h264.Sps;
pub const H264Pps = h264.Pps;
pub const AvcDecoderConfigRecord = h264.AvcDecoderConfigRecord;

pub const hevc = @import("codecs/video/hevc.zig");
pub const HevcNalIterator = hevc.HevcNalIterator;
pub const HevcNalUnitType = hevc.NalUnitType;
pub const HevcNalUnitHeader = hevc.NalUnitHeader;
pub const HevcVps = hevc.Vps;
pub const HevcSps = hevc.Sps;
pub const HevcPps = hevc.Pps;
pub const HvccRecord = hevc.HvccRecord;

pub const vp9 = @import("codecs/video/vp9.zig");
pub const Vp9Profile = vp9.Profile;
pub const Vp9ColorSpace = vp9.ColorSpace;
pub const Vp9FrameType = vp9.FrameType;
pub const Vp9FrameParser = vp9.FrameParser;
pub const Vp9UncompressedHeader = vp9.UncompressedHeader;
pub const Vp9SuperframeIndex = vp9.SuperframeIndex;
pub const Vp9SuperframeIterator = vp9.SuperframeIterator;
pub const VpcCRecord = vp9.VpcCRecord;
pub const parseSuperframeIndex = vp9.parseSuperframeIndex;

pub const av1 = @import("codecs/video/av1.zig");
pub const Av1ObuType = av1.ObuType;
pub const Av1Profile = av1.Profile;
pub const Av1Level = av1.Level;
pub const Av1FrameType = av1.FrameType;
pub const Av1ObuHeader = av1.ObuHeader;
pub const Av1ObuParser = av1.ObuParser;
pub const Av1ObuIterator = av1.ObuIterator;
pub const Av1SequenceHeader = av1.SequenceHeader;
pub const Av1CRecord = av1.Av1CRecord;

// ============================================================================
// Utilities
// ============================================================================

pub const bitstream = @import("util/bitstream.zig");
pub const BitstreamReader = bitstream.BitstreamReader;
pub const BitstreamWriter = bitstream.BitstreamWriter;
pub const NALUnitIterator = bitstream.NALUnitIterator;
pub const removeEmulationPrevention = bitstream.removeEmulationPrevention;
pub const addEmulationPrevention = bitstream.addEmulationPrevention;
pub const findStartCode = bitstream.findStartCode;

// ============================================================================
// Video Filters
// ============================================================================

pub const video_filters = @import("filters/video.zig");
pub const ScaleFilter = video_filters.ScaleFilter;
pub const ScaleAlgorithm = video_filters.ScaleAlgorithm;
pub const CropFilter = video_filters.CropFilter;
pub const ColorFilter = video_filters.ColorFilter;
pub const ColorAdjustment = video_filters.ColorAdjustment;
pub const InvertFilter = video_filters.InvertFilter;
pub const GrayscaleFilter = video_filters.GrayscaleFilter;
pub const ColorSpaceConverter = video_filters.ColorSpaceConverter;
pub const ColorStandard = video_filters.ColorStandard;
pub const RotateFilter = video_filters.RotateFilter;
pub const RotationAngle = video_filters.RotationAngle;
pub const FlipFilter = video_filters.FlipFilter;
pub const FlipDirection = video_filters.FlipDirection;
pub const TransposeFilter = video_filters.TransposeFilter;
pub const BlurFilter = video_filters.BlurFilter;
pub const SharpenFilter = video_filters.SharpenFilter;
pub const EdgeDetectionFilter = video_filters.EdgeDetectionFilter;
pub const ConvolutionFilter = video_filters.ConvolutionFilter;
pub const Kernel = video_filters.Kernel;
pub const Kernels = video_filters.Kernels;
pub const DeinterlaceFilter = video_filters.DeinterlaceFilter;
pub const DeinterlaceMethod = video_filters.DeinterlaceMethod;
pub const FieldOrder = video_filters.FieldOrder;
pub const FieldSeparator = video_filters.FieldSeparator;
pub const DenoiseFilter = video_filters.DenoiseFilter;
pub const DenoiseMethod = video_filters.DenoiseMethod;

// ============================================================================
// Audio Filters
// ============================================================================

pub const audio_filters = @import("filters/audio.zig");
pub const VolumeFilter = audio_filters.VolumeFilter;
pub const NormalizeFilter = audio_filters.NormalizeFilter;
pub const ResampleFilter = audio_filters.ResampleFilter;
pub const ResampleQuality = audio_filters.ResampleQuality;
pub const ChannelMixer = audio_filters.ChannelMixer;

// ============================================================================
// Subtitles
// ============================================================================

pub const srt = @import("subtitles/srt.zig");
pub const SrtParser = srt.SrtParser;
pub const SrtWriter = srt.SrtWriter;
pub const SrtCue = srt.Cue;

pub const vtt = @import("subtitles/vtt.zig");
pub const VttParser = vtt.VttParser;
pub const VttWriter = vtt.VttWriter;
pub const VttCue = vtt.Cue;
pub const VttCueSettings = vtt.CueSettings;
pub const isVtt = vtt.isVtt;

// ============================================================================
// High-Level API
// ============================================================================

/// Audio file for simple operations
pub const Audio = struct {
    frames: std.ArrayList(AudioFrame),
    sample_rate: u32,
    channels: u8,
    format: SampleFormat,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Load audio from file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Self {
        const ext = std.fs.path.extension(path);

        if (std.mem.eql(u8, ext, ".wav") or std.mem.eql(u8, ext, ".WAV")) {
            return loadWav(allocator, path);
        }

        return VideoError.UnsupportedFormat;
    }

    /// Load WAV file
    fn loadWav(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
        defer allocator.free(data);

        var reader = try WavReader.fromMemory(allocator, data);

        var frames = std.ArrayList(AudioFrame).init(allocator);
        errdefer {
            for (frames.items) |*f| f.deinit();
            frames.deinit();
        }

        // Read all frames
        while (try reader.readFrames(4096)) |audio_frame| {
            try frames.append(audio_frame);
        }

        return Self{
            .frames = frames,
            .sample_rate = reader.header.sample_rate,
            .channels = @intCast(reader.header.channels),
            .format = reader.header.getSampleFormat() orelse .s16le,
            .allocator = allocator,
        };
    }

    /// Load audio from memory
    pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (wav.isWav(data)) {
            var reader = try WavReader.fromMemory(allocator, data);

            var frames = std.ArrayList(AudioFrame).init(allocator);
            errdefer {
                for (frames.items) |*f| f.deinit();
                frames.deinit();
            }

            while (try reader.readFrames(4096)) |audio_frame| {
                try frames.append(audio_frame);
            }

            return Self{
                .frames = frames,
                .sample_rate = reader.header.sample_rate,
                .channels = @intCast(reader.header.channels),
                .format = reader.header.getSampleFormat() orelse .s16le,
                .allocator = allocator,
            };
        }

        return VideoError.UnsupportedFormat;
    }

    pub fn deinit(self: *Self) void {
        for (self.frames.items) |*f| {
            f.deinit();
        }
        self.frames.deinit();
    }

    /// Save audio to file
    pub fn save(self: *const Self, path: []const u8) !void {
        const ext = std.fs.path.extension(path);

        if (std.mem.eql(u8, ext, ".wav") or std.mem.eql(u8, ext, ".WAV")) {
            try self.saveWav(path);
            return;
        }

        return VideoError.UnsupportedFormat;
    }

    fn saveWav(self: *const Self, path: []const u8) !void {
        var writer = try WavWriter.init(self.allocator, self.channels, self.sample_rate, self.format);
        defer writer.deinit();

        for (self.frames.items) |*audio_frame| {
            try writer.writeFrame(audio_frame);
        }

        try writer.writeToFile(path);
    }

    /// Encode to bytes
    pub fn encode(self: *const Self, format_type: AudioFormat) ![]u8 {
        _ = self;
        _ = format_type;
        return VideoError.NotImplemented;
    }

    /// Get duration in seconds
    pub fn duration(self: *const Self) f64 {
        var total_samples: u64 = 0;
        for (self.frames.items) |f| {
            total_samples += f.num_samples;
        }
        return @as(f64, @floatFromInt(total_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Get total number of samples (per channel)
    pub fn totalSamples(self: *const Self) u64 {
        var total: u64 = 0;
        for (self.frames.items) |f| {
            total += f.num_samples;
        }
        return total;
    }
};

// ============================================================================
// Version Information
// ============================================================================

pub const VERSION = struct {
    pub const MAJOR: u32 = 0;
    pub const MINOR: u32 = 1;
    pub const PATCH: u32 = 0;

    pub fn string() []const u8 {
        return "0.1.0";
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Video library imports" {
    // Verify all modules can be imported
    _ = types;
    _ = frame;
    _ = packet;
    _ = err;
    _ = source;
    _ = target;
    _ = wav;
    _ = mp4;
    _ = mp4_muxer;
    _ = webm;
    _ = ogg;
    _ = pcm;
    _ = aac;
    _ = opus;
    _ = flac;
    _ = h264;
    _ = hevc;
    _ = vp9;
    _ = av1;
    _ = bitstream;
    _ = video_filters;
    _ = audio_filters;
    _ = srt;
    _ = vtt;
}

test "Timestamp basic" {
    const ts = Timestamp.fromSeconds(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);
}

test "Duration basic" {
    const d = Duration.fromSeconds(60.0);
    try std.testing.expectEqual(@as(u64, 60000), d.toMilliseconds());
}

test "PixelFormat" {
    try std.testing.expect(PixelFormat.rgba32.hasAlpha());
    try std.testing.expect(!PixelFormat.yuv420p.hasAlpha());
}

test "SampleFormat" {
    try std.testing.expectEqual(@as(u8, 2), SampleFormat.s16le.bytesPerSample());
    try std.testing.expectEqual(@as(u8, 4), SampleFormat.f32le.bytesPerSample());
}
