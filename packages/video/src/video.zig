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

pub const vvc = @import("codecs/video/vvc.zig");
pub const VvcNalIterator = vvc.VvcNalIterator;
pub const VvcNalUnitType = vvc.NalUnitType;
pub const VvcNalUnitHeader = vvc.NalUnitHeader;
pub const VvcProfile = vvc.Profile;
pub const VvcLevel = vvc.Level;
pub const VvcVps = vvc.Vps;
pub const VvcSps = vvc.Sps;
pub const VvcPps = vvc.Pps;
pub const VvcCRecord = vvc.VvcCRecord;

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

pub const ass = @import("subtitles/ass.zig");
pub const AssParser = ass.AssParser;
pub const AssWriter = ass.AssWriter;
pub const AssDialogue = ass.Dialogue;
pub const AssStyle = ass.Style;
pub const AssScriptInfo = ass.ScriptInfo;
pub const isAss = ass.isAss;

pub const ttml = @import("subtitles/ttml.zig");
pub const TtmlParser = ttml.TtmlParser;
pub const TtmlWriter = ttml.TtmlWriter;
pub const TtmlCue = ttml.Cue;
pub const TtmlStyle = ttml.Style;
pub const TtmlRegion = ttml.Region;
pub const isTtml = ttml.isTtml;

pub const subtitle_convert = @import("subtitles/convert.zig");
pub const SubtitleFormatType = subtitle_convert.SubtitleFormat;
pub const UniversalCue = subtitle_convert.UniversalCue;
pub const UniversalSubtitle = subtitle_convert.UniversalSubtitle;
pub const UniversalStyle = subtitle_convert.UniversalStyle;
pub const detectSubtitleFormat = subtitle_convert.detectFormat;
pub const srtToVtt = subtitle_convert.srtToVtt;
pub const vttToSrt = subtitle_convert.vttToSrt;
pub const srtToAss = subtitle_convert.srtToAss;
pub const assToSrt = subtitle_convert.assToSrt;
pub const convertSubtitle = subtitle_convert.convert;

// ============================================================================
// Streaming
// ============================================================================

pub const hls = @import("streaming/hls.zig");
pub const HlsPlaylist = hls.Playlist;
pub const HlsPlaylistType = hls.PlaylistType;
pub const HlsVariantStream = hls.VariantStream;
pub const HlsSegment = hls.Segment;
pub const HlsRendition = hls.Rendition;
pub const isHls = hls.isHls;

pub const dash = @import("streaming/dash.zig");
pub const DashManifest = dash.Manifest;
pub const DashManifestType = dash.ManifestType;
pub const DashPeriod = dash.Period;
pub const DashAdaptationSet = dash.AdaptationSet;
pub const DashRepresentation = dash.Representation;
pub const isDash = dash.isDash;

// ============================================================================
// Additional Container Formats
// ============================================================================

pub const mpegts = @import("containers/mpegts.zig");
pub const MpegTsReader = mpegts.TsReader;
pub const MpegTsPacketHeader = mpegts.PacketHeader;
pub const MpegTsStreamType = mpegts.StreamType;
pub const MpegTsPatEntry = mpegts.PatEntry;
pub const MpegTsPmtStream = mpegts.PmtStream;
pub const MpegTsAdaptationField = mpegts.AdaptationField;
pub const isMpegTs = mpegts.isMpegTs;

pub const flv = @import("containers/flv.zig");
pub const FlvDemuxer = flv.FlvDemuxer;
pub const FlvMuxer = flv.FlvMuxer;
pub const FlvHeader = flv.FlvHeader;
pub const FlvTag = flv.FlvTag;
pub const FlvTagType = flv.FlvTagType;
pub const FlvVideoData = flv.FlvVideoData;
pub const FlvAudioData = flv.FlvAudioData;
pub const FlvMetadata = flv.FlvMetadata;
pub const FlvVideoCodec = flv.FlvVideoCodec;
pub const FlvAudioCodec = flv.FlvAudioCodec;

pub const mxf = @import("containers/mxf.zig");
pub const MxfDemuxer = mxf.MxfDemuxer;
pub const MxfPartitionPack = mxf.PartitionPack;
pub const MxfKLV = mxf.KLV;
pub const MxfTrack = mxf.MxfTrack;
pub const MxfMetadata = mxf.MxfMetadata;
pub const MxfEssenceType = mxf.EssenceType;
pub const MxfOperationalPattern = mxf.OperationalPattern;
pub const isValidMxf = mxf.isValidMxf;

// ============================================================================
// Metadata
// ============================================================================

pub const id3 = @import("metadata/id3.zig");
pub const Id3v1Tag = id3.Id3v1Tag;
pub const Id3v2Header = id3.Id3v2Header;
pub const Id3v2Frame = id3.Id3v2Frame;
pub const Id3Tag = id3.Id3Tag;
pub const parseId3v1 = id3.parseId3v1;
pub const parseId3v2 = id3.parseId3v2;
pub const hasId3v2 = id3.hasId3v2;
pub const hasId3v1 = id3.hasId3v1;

pub const mp4meta = @import("metadata/mp4meta.zig");
pub const Mp4Metadata = mp4meta.Mp4Metadata;
pub const Mp4AtomType = mp4meta.AtomType;
pub const parseMp4Metadata = mp4meta.parseMetadata;

pub const matroska_tags = @import("metadata/matroska_tags.zig");
pub const MatroskaTag = matroska_tags.Tag;
pub const MatroskaSimpleTag = matroska_tags.SimpleTag;
pub const MatroskaTagTarget = matroska_tags.TagTarget;
pub const parseMatroskaTags = matroska_tags.parseTags;

// ============================================================================
// Chapters
// ============================================================================

pub const chapters = @import("chapters/chapters.zig");
pub const Chapter = chapters.Chapter;
pub const ChapterEdition = chapters.ChapterEdition;
pub const ChapterTrack = chapters.ChapterTrack;
pub const parseMp4Chapters = chapters.parseMp4Chapters;
pub const parseMatroskaChapters = chapters.parseMatroskaChapters;
pub const parseOggChapters = chapters.parseOggChapters;
pub const formatChapterTime = chapters.formatChapterTime;

// ============================================================================
// HDR Metadata
// ============================================================================

pub const hdr = @import("hdr/hdr.zig");
pub const HdrFormat = hdr.HdrFormat;
pub const HdrMetadata = hdr.HdrMetadata;
pub const MasteringDisplayColorVolume = hdr.MasteringDisplayColorVolume;
pub const ContentLightLevel = hdr.ContentLightLevel;
pub const Hdr10PlusMetadata = hdr.Hdr10PlusMetadata;
pub const DolbyVisionConfiguration = hdr.DolbyVisionConfiguration;
pub const DolbyVisionProfile = hdr.DolbyVisionProfile;
pub const DolbyVisionLevel = hdr.DolbyVisionLevel;
pub const HdrPresets = hdr.HdrPresets;
pub const parseHdr10Plus = hdr.parseHdr10Plus;
pub const parseDolbyVisionConfig = hdr.parseDolbyVisionConfig;
pub const parseMasteringDisplaySei = hdr.parseMasteringDisplaySei;
pub const parseContentLightLevelSei = hdr.parseContentLightLevelSei;

// ============================================================================
// Audio Metering
// ============================================================================

pub const metering = @import("audio/metering.zig");
pub const LoudnessMeter = metering.LoudnessMeter;
pub const TruePeakMeter = metering.TruePeakMeter;
pub const LoudnessResult = metering.LoudnessResult;
pub const LoudnessTarget = metering.LoudnessTarget;
pub const measureLoudness = metering.measureLoudness;

// ============================================================================
// Timecode
// ============================================================================

pub const timecode = @import("timecode/timecode.zig");
pub const Timecode = timecode.Timecode;
pub const TimecodeFrameRate = timecode.FrameRate;
pub const LtcFrame = timecode.LtcFrame;
pub const LtcDecoder = timecode.LtcDecoder;
pub const LtcEncoder = timecode.LtcEncoder;
pub const TimecodeRange = timecode.TimecodeRange;

// ============================================================================
// DRM / Encryption
// ============================================================================

pub const drm = @import("drm/drm.zig");
pub const DrmSystem = drm.DrmSystem;
pub const EncryptionScheme = drm.EncryptionScheme;
pub const PsshBox = drm.PsshBox;
pub const TencBox = drm.TencBox;
pub const ContentProtection = drm.ContentProtection;
pub const parsePssh = drm.parsePssh;
pub const parseTenc = drm.parseTenc;
pub const DrmSystemIds = drm.SystemIds;

// ============================================================================
// Thumbnails
// ============================================================================

pub const thumbnail = @import("thumbnail/thumbnail.zig");
pub const ThumbnailExtractor = thumbnail.ThumbnailExtractor;
pub const ThumbnailOptions = thumbnail.ThumbnailOptions;
pub const ThumbnailFormat = thumbnail.ThumbnailFormat;
pub const ScaleMode = thumbnail.ScaleMode;
pub const SpriteSheet = thumbnail.SpriteSheet;
pub const SpriteSheetOptions = thumbnail.SpriteSheetOptions;

// ============================================================================
// Frame Seeking
// ============================================================================

pub const seeking = @import("seeking/seeking.zig");
pub const FrameIndex = seeking.FrameIndex;
pub const FrameIndexEntry = seeking.FrameIndexEntry;
pub const FrameSeeker = seeking.FrameSeeker;
pub const SeekTarget = seeking.SeekTarget;
pub const SeekResult = seeking.SeekResult;
pub const GopInfo = seeking.GopInfo;
pub const SeekFrameType = seeking.FrameType;
pub const AvcFrameParser = seeking.AvcFrameParser;
pub const HevcFrameParser = seeking.HevcFrameParser;
pub const Mpeg2FrameParser = seeking.Mpeg2FrameParser;
pub const Vp9FrameParser = seeking.Vp9FrameParser;
pub const Av1FrameParser = seeking.Av1FrameParser;

// ============================================================================
// Color LUT
// ============================================================================

pub const lut = @import("color/lut.zig");
pub const Lut1D = lut.Lut1D;
pub const Lut3D = lut.Lut3D;
pub const LutType = lut.LutType;
pub const LutColorSpace = lut.ColorSpace;
pub const LutProcessor = lut.LutProcessor;
pub const LutGenerator = lut.LutGenerator;
pub const LutWriter = lut.LutWriter;
pub const parseCube = lut.parseCube;
pub const parse3dl = lut.parse3dl;
pub const parseCsp = lut.parseCsp;

// ============================================================================
// Conversion Utilities
// ============================================================================

pub const sample_convert = @import("core/sample_convert.zig");
pub const SampleConvertFormat = sample_convert.SampleFormat;
pub const readSampleNormalized = sample_convert.readSampleNormalized;
pub const writeSampleNormalized = sample_convert.writeSampleNormalized;
pub const convertAudioSamples = sample_convert.convertSamples;
pub const convertAudioChannels = sample_convert.convertChannels;
pub const resampleAudio = sample_convert.resample;
pub const applyAudioGain = sample_convert.applyGain;
pub const normalizeAudio = sample_convert.normalize;
pub const AudioChannelLayout = sample_convert.ChannelLayout;

pub const pixel_convert = @import("core/pixel_convert.zig");
pub const PixelConvertFormat = pixel_convert.PixelFormat;
pub const ConvertColorSpace = pixel_convert.ColorSpace;
pub const ConvertColorRange = pixel_convert.ColorRange;
pub const ConvertFrame = pixel_convert.Frame;
pub const convertPixelFormat = pixel_convert.convert;
pub const convertPixelFormatInPlace = pixel_convert.convertInPlace;

pub const nal_convert = @import("core/nal_convert.zig");
pub const NalFormat = nal_convert.NalFormat;
pub const NalCodecType = nal_convert.CodecType;
pub const NalUnit = nal_convert.NalUnit;
pub const parseAnnexB = nal_convert.parseAnnexB;
pub const parseLengthPrefixed = nal_convert.parseLengthPrefixed;
pub const annexBToLengthPrefixed = nal_convert.annexBToLengthPrefixed;
pub const lengthPrefixedToAnnexB = nal_convert.lengthPrefixedToAnnexB;
pub const extractParameterSets = nal_convert.extractParameterSets;

pub const remux = @import("core/remux.zig");
pub const RemuxStreamType = remux.StreamType;
pub const RemuxVideoCodec = remux.VideoCodec;
pub const RemuxAudioCodec = remux.AudioCodec;
pub const RemuxSubtitleCodec = remux.SubtitleCodec;
pub const RemuxStream = remux.Stream;
pub const RemuxPacket = remux.Packet;
pub const ContainerFormat = remux.ContainerFormat;
pub const RemuxContext = remux.RemuxContext;
pub const convertTimestamp = remux.convertTimestamp;
pub const StreamSelection = remux.StreamSelection;
pub const selectStreams = remux.selectStreams;

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
    _ = vvc;
    _ = bitstream;
    _ = video_filters;
    _ = audio_filters;
    _ = srt;
    _ = vtt;
    _ = ass;
    _ = ttml;
    _ = hls;
    _ = dash;
    _ = subtitle_convert;
    _ = sample_convert;
    _ = pixel_convert;
    _ = nal_convert;
    _ = remux;
    // New modules
    _ = mpegts;
    _ = flv;
    _ = mxf;
    _ = id3;
    _ = mp4meta;
    _ = matroska_tags;
    _ = chapters;
    _ = hdr;
    _ = metering;
    _ = timecode;
    _ = drm;
    _ = thumbnail;
    _ = seeking;
    _ = lut;
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
