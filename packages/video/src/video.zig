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

pub const mp3 = @import("codecs/audio/mp3.zig");
pub const Mp3 = mp3.Mp3;
pub const Mp3Parser = mp3.Mp3Parser;
pub const Mp3Reader = mp3.Mp3Reader;
pub const isMp3 = mp3.isMp3;

pub const vorbis = @import("codecs/audio/vorbis.zig");
pub const Vorbis = vorbis.Vorbis;
pub const VorbisParser = vorbis.VorbisParser;
pub const VorbisDecoder = vorbis.VorbisDecoder;
pub const VorbisEncoder = vorbis.VorbisEncoder;

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

pub const vp8 = @import("codecs/video/vp8.zig");
pub const Vp8 = vp8.Vp8;
pub const Vp8FrameParser = vp8.Vp8FrameParser;

pub const mjpeg = @import("codecs/video/mjpeg.zig");
pub const Mjpeg = mjpeg.Mjpeg;
pub const MjpegParser = mjpeg.MjpegParser;
pub const MjpegDecoder = mjpeg.MjpegDecoder;

pub const mpeg2 = @import("codecs/video/mpeg2.zig");
pub const Mpeg2 = mpeg2.Mpeg2;
pub const Mpeg2Parser = mpeg2.Mpeg2Parser;

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
// Captions (CEA-608/CEA-708)
// ============================================================================

pub const cea608 = @import("captions/cea608.zig");
pub const Cea608Decoder = cea608.Cea608Decoder;
pub const Cea608CaptionMode = cea608.CaptionMode;
pub const Cea608CaptionStyle = cea608.CaptionStyle;
pub const Cea608ControlCode = cea608.ControlCode;

pub const cea708 = @import("captions/cea708.zig");
pub const Cea708Decoder = cea708.Cea708Decoder;
pub const Cea708Service = cea708.Service;
pub const Cea708Window = cea708.Window;

// ============================================================================
// Quality Analysis
// ============================================================================

pub const quality = @import("analysis/quality.zig");
pub const QualityMetrics = quality.QualityMetrics;
pub const PsnrResult = quality.PsnrResult;
pub const SsimResult = quality.SsimResult;
pub const VmafScore = quality.VmafScore;
pub const calculatePsnr = quality.calculatePsnr;
pub const calculateSsim = quality.calculateSsim;
pub const calculateVmaf = quality.calculateVmaf;

pub const detection = @import("analysis/detection.zig");
pub const BlackFrameDetector = detection.BlackFrameDetector;
pub const FreezeFrameDetector = detection.FreezeFrameDetector;
pub const SilenceDetector = detection.SilenceDetector;

pub const scenecut = @import("analysis/scenecut.zig");
pub const ScenecutDetector = scenecut.ScenecutDetector;
pub const ScenecutMethod = scenecut.ScenecutMethod;
pub const ScenecutOptions = scenecut.ScenecutOptions;

// ============================================================================
// Streaming Protocols
// ============================================================================

pub const rtmp = @import("streaming/rtmp.zig");
pub const RtmpConnection = rtmp.RtmpConnection;
pub const RtmpHandshake = rtmp.RtmpHandshake;
pub const RtmpChunk = rtmp.RtmpChunk;
pub const RtmpMessage = rtmp.RtmpMessage;

pub const rtp = @import("streaming/rtp.zig");
pub const RtpHeader = rtp.RtpHeader;
pub const RtpPacket = rtp.RtpPacket;
pub const RtcpSenderReport = rtp.RtcpSenderReport;
pub const RtspRequest = rtp.RtspRequest;
pub const RtspResponse = rtp.RtspResponse;
pub const SdpSession = rtp.SdpSession;

// ============================================================================
// Overlay and Burn-in
// ============================================================================

pub const overlay = @import("overlay/overlay.zig");
pub const TextOverlay = overlay.TextOverlay;
pub const TextStyle = overlay.TextStyle;
pub const TimecodeOverlay = overlay.TimecodeOverlay;
pub const ImageOverlay = overlay.ImageOverlay;

// ============================================================================
// Advanced Audio Processing
// ============================================================================

pub const audio_processing = @import("audio/processing.zig");
pub const Ducker = audio_processing.Ducker;
pub const Compressor = audio_processing.Compressor;
pub const ParametricEq = audio_processing.ParametricEq;
pub const GraphicEq = audio_processing.GraphicEq;
pub const AudioNormalizer = audio_processing.AudioNormalizer;
pub const PitchShifter = audio_processing.PitchShifter;

// ============================================================================
// Video Stabilization
// ============================================================================

pub const stabilization = @import("stabilization/stabilization.zig");
pub const VideoStabilizer = stabilization.VideoStabilizer;
pub const FeatureDetector = stabilization.FeatureDetector;
pub const FeatureTracker = stabilization.FeatureTracker;
pub const TransformSmoother = stabilization.TransformSmoother;

// ============================================================================
// Broadcast Standards
// ============================================================================

pub const scte35 = @import("broadcast/scte35.zig");
pub const Scte35 = scte35.Scte35;
pub const Scte35Parser = scte35.Scte35Parser;
pub const SpliceInfoSection = scte35.Scte35.SpliceInfoSection;
pub const SpliceInsert = scte35.Scte35.SpliceInsert;

pub const teletext = @import("broadcast/teletext.zig");
pub const Teletext = teletext.Teletext;
pub const TeletextDecoder = teletext.TeletextDecoder;
pub const TeletextPage = teletext.Teletext.Page;

pub const afd = @import("broadcast/afd.zig");
pub const Afd = afd.Afd;
pub const AfdParser = afd.AfdParser;
pub const AfdDetector = afd.AfdDetector;

pub const wss = @import("broadcast/wss.zig");
pub const Wss = wss.Wss;
pub const WssDecoder = wss.WssDecoder;
pub const WssDetector = wss.WssDetector;

// ============================================================================
// Codec Analysis
// ============================================================================

pub const h264_analysis = @import("codec/h264_analysis.zig");
pub const H264Analysis = h264_analysis.H264Analysis;
pub const SpsParser = h264_analysis.SpsParser;
pub const PpsParser = h264_analysis.PpsParser;
pub const SliceHeaderParser = h264_analysis.SliceHeaderParser;
pub const ExpGolomb = h264_analysis.ExpGolomb;

pub const hevc_analysis = @import("codec/hevc_analysis.zig");
pub const HevcAnalysis = hevc_analysis.HevcAnalysis;
pub const HevcVpsParser = hevc_analysis.VpsParser;
pub const HevcSpsParser = hevc_analysis.SpsParser;
pub const HevcPpsParser = hevc_analysis.PpsParser;

pub const bitrate = @import("codec/bitrate.zig");
pub const BitrateAnalyzer = bitrate.BitrateAnalyzer;
pub const BitrateStats = bitrate.BitrateAnalyzer.BitrateStats;
pub const VbvSimulator = bitrate.VbvSimulator;
pub const GopAnalyzer = bitrate.GopAnalyzer;

// ============================================================================
// Professional Formats
// ============================================================================

pub const prores = @import("formats/prores.zig");
pub const ProRes = prores.ProRes;
pub const ProResParser = prores.ProResParser;
pub const ProResRecommendations = prores.ProResRecommendations;

pub const dnxhd = @import("formats/dnxhd.zig");
pub const DnxHd = dnxhd.DnxHd;
pub const DnxParser = dnxhd.DnxParser;
pub const DnxRecommendations = dnxhd.DnxRecommendations;

pub const imf = @import("formats/imf.zig");
pub const Imf = imf.Imf;
pub const ImfPackage = imf.ImfPackage;
pub const ImfEssence = imf.ImfEssence;
pub const ImfUtils = imf.ImfUtils;

pub const dcp = @import("formats/dcp.zig");
pub const Dcp = dcp.Dcp;
pub const DcpPackage = dcp.DcpPackage;
pub const DcpEssence = dcp.DcpEssence;
pub const DcpUtils = dcp.DcpUtils;

// ============================================================================
// Timeline / NLE
// ============================================================================

pub const timeline = @import("timeline/timeline.zig");
pub const Timeline = timeline.Timeline;
pub const Track = timeline.Track;
pub const Clip = timeline.Clip;
pub const Transition = timeline.Transition;
pub const TimelineRenderer = timeline.TimelineRenderer;
pub const EdlExporter = timeline.EdlExporter;
pub const FcpXmlExporter = timeline.FcpXmlExporter;
pub const XmlFormat = timeline.FcpXmlExporter.XmlFormat;
pub const FcpXmlOptions = timeline.FcpXmlExporter.FcpXmlOptions;
pub const PremiereXmlOptions = timeline.FcpXmlExporter.PremiereXmlOptions;
pub const DavinciXmlOptions = timeline.FcpXmlExporter.DavinciXmlOptions;
pub const TimelineProject = timeline.TimelineProject;

// ============================================================================
// GIF Support
// ============================================================================

pub const gif = @import("containers/gif.zig");
pub const Gif = gif.Gif;
pub const GifReader = gif.GifReader;
pub const GifWriter = gif.GifWriter;
pub const isGif = gif.isGif;

// ============================================================================
// Audio Visualization
// ============================================================================

pub const audio_viz = @import("audio/visualization.zig");
pub const WaveformGenerator = audio_viz.WaveformGenerator;
pub const SpectrogramGenerator = audio_viz.SpectrogramGenerator;
pub const SpectrumAnalyzer = audio_viz.SpectrumAnalyzer;
pub const AudioMeter = audio_viz.AudioMeter;

// ============================================================================
// Image-based Subtitles
// ============================================================================

pub const pgs = @import("subtitles/pgs.zig");
pub const Pgs = pgs.Pgs;
pub const PgsParser = pgs.PgsParser;
pub const PgsDecoder = pgs.PgsDecoder;
pub const isPgs = pgs.isPgs;

pub const vobsub = @import("subtitles/vobsub.zig");
pub const VobSub = vobsub.VobSub;
pub const VobSubIdx = vobsub.VobSubIdx;
pub const VobSubParser = vobsub.VobSubParser;
pub const VobSubDecoder = vobsub.VobSubDecoder;

// ============================================================================
// Additional Containers
// ============================================================================

pub const avi = @import("containers/avi.zig");
pub const Avi = avi.Avi;
pub const AviReader = avi.AviReader;
pub const isAvi = avi.isAvi;

// ============================================================================
// Additional Audio Codecs
// ============================================================================

pub const ac3 = @import("codecs/audio/ac3.zig");
pub const Ac3 = ac3.Ac3;
pub const Ac3Parser = ac3.Ac3Parser;
pub const Ac3Decoder = ac3.Ac3Decoder;
pub const isAc3OrEac3 = ac3.isAc3OrEac3;

pub const dts = @import("codecs/audio/dts.zig");
pub const Dts = dts.Dts;
pub const DtsParser = dts.DtsParser;
pub const DtsDecoder = dts.DtsDecoder;
pub const isDts = dts.isDts;

// ============================================================================
// Conversion Pipeline
// ============================================================================

pub const conversion = @import("conversion/conversion.zig");
pub const ConversionMode = conversion.ConversionMode;
pub const ConversionOptions = conversion.ConversionOptions;
pub const ConversionResult = conversion.ConversionResult;
pub const VideoEncodingOptions = conversion.VideoEncodingOptions;
pub const AudioEncodingOptions = conversion.AudioEncodingOptions;
pub const StreamAction = conversion.StreamAction;
pub const SubtitleAction = conversion.SubtitleAction;
pub const Converter = conversion.Converter;
pub const BatchConverter = conversion.BatchConverter;
pub const Presets = conversion.Presets;
pub const ProgressCallback = conversion.ProgressCallback;
pub const CancellationToken = conversion.CancellationToken;

// ============================================================================
// Media Sources
// ============================================================================

pub const sources = @import("sources/sources.zig");
pub const VideoSource = sources.VideoSource;
pub const AudioSource = sources.AudioSource;
pub const ImageSequenceSource = sources.ImageSequenceSource;
pub const CanvasSource = sources.CanvasSource;
pub const ToneGeneratorSource = sources.ToneGeneratorSource;
pub const SilenceSource = sources.SilenceSource;
pub const RawVideoSource = sources.RawVideoSource;
pub const RawAudioSource = sources.RawAudioSource;

// ============================================================================
// Media Sinks
// ============================================================================

pub const sinks = @import("sinks/sinks.zig");
pub const VideoSink = sinks.VideoSink;
pub const AudioSink = sinks.AudioSink;
pub const VideoFrameSink = sinks.VideoFrameSink;
pub const ImageSequenceSink = sinks.ImageSequenceSink;
pub const EncodedPacketSink = sinks.EncodedPacketSink;
pub const AudioSampleSink = sinks.AudioSampleSink;
pub const WaveformSink = sinks.WaveformSink;
pub const NullSink = sinks.NullSink;
pub const FileSink = sinks.FileSink;
pub const BufferSink = sinks.BufferSink;

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

    /// Encode to bytes in specified format
    pub fn encode(self: *const Self, format_type: AudioFormat) ![]u8 {
        // Encode audio to various formats
        switch (format_type) {
            .wav => {
                // Encode to WAV format
                var writer = try WavWriter.init(self.allocator, self.channels, self.sample_rate, self.format);
                defer writer.deinit();

                for (self.frames.items) |*audio_frame| {
                    try writer.writeFrame(audio_frame);
                }

                return try writer.toBytes();
            },
            .flac => {
                // FLAC encoding would use flac encoder
                // For now, return WAV as fallback
                return try self.encode(.wav);
            },
            .mp3 => {
                // MP3 encoding would use lame or similar
                // For now, return WAV as fallback
                return try self.encode(.wav);
            },
            .aac => {
                // Use AAC encoder
                const aac_codec = @import("codecs/audio/aac.zig");
                var encoder = aac_codec.AacEncoder.init(self.allocator, self.sample_rate, self.channels, 128000);
                defer encoder.deinit();

                var output = std.ArrayList(u8).init(self.allocator);
                defer output.deinit();

                // Encode each frame and concatenate
                for (self.frames.items) |*audio_frame| {
                    const encoded = try encoder.encodeAdts(audio_frame);
                    defer self.allocator.free(encoded);
                    try output.appendSlice(encoded);
                }

                return output.toOwnedSlice();
            },
            .opus => {
                // Opus encoding would use opus encoder
                return try self.encode(.wav);
            },
            .vorbis => {
                // Use Vorbis encoder
                const vorbis_codec = @import("codecs/audio/vorbis.zig");
                var encoder = vorbis_codec.VorbisEncoder.init(self.allocator, self.sample_rate, self.channels, 0.5);

                // Generate headers
                const id_header = try encoder.generateIdentificationHeader();
                defer self.allocator.free(id_header);

                const comment_header = try encoder.generateCommentHeader("Encoded with Home Video Library", &[_]vorbis_codec.Vorbis.Comment{});
                defer self.allocator.free(comment_header);

                var output = std.ArrayList(u8).init(self.allocator);
                defer output.deinit();

                // Write headers (in real usage, these would go into Ogg container)
                try output.appendSlice(id_header);
                try output.appendSlice(comment_header);

                // Encode frames
                // First, collect all samples
                var all_samples = std.ArrayList(f32).init(self.allocator);
                defer all_samples.deinit();

                for (self.frames.items) |*audio_frame| {
                    for (0..audio_frame.num_samples) |i| {
                        for (0..audio_frame.channels) |ch| {
                            const sample = audio_frame.getSampleF32(@intCast(ch), @intCast(i)) orelse 0.0;
                            try all_samples.append(sample);
                        }
                    }
                }

                // Encode
                const encoded = try encoder.encodeAudio(all_samples.items);
                defer self.allocator.free(encoded);
                try output.appendSlice(encoded);

                return output.toOwnedSlice();
            },
            else => {
                // Unknown format, default to WAV
                return try self.encode(.wav);
            },
        }
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
// Accessibility Features
// ============================================================================

pub const accessibility = @import("accessibility/accessibility.zig");
pub const TrackDisposition = accessibility.TrackDisposition;
pub const AudioDescriptionTrack = accessibility.AudioDescriptionTrack;
pub const AudioDescriptionInfo = accessibility.AudioDescriptionInfo;
pub const CaptionHandler = accessibility.CaptionHandler;
pub const CaptionFormat = accessibility.CaptionFormat;
pub const CaptionEmbedMode = accessibility.CaptionEmbedMode;
pub const SignLanguageTrack = accessibility.SignLanguageTrack;
pub const SignLanguageInfo = accessibility.SignLanguageInfo;
pub const AccessibilityManager = accessibility.AccessibilityManager;

// ============================================================================
// Robustness Features
// ============================================================================

pub const robustness = @import("robustness/robustness.zig");
pub const RecoveryMode = robustness.RecoveryMode;
pub const CorruptionHandler = robustness.CorruptionHandler;
pub const VfrHandler = robustness.VfrHandler;
pub const LargeFileHandler = robustness.LargeFileHandler;
pub const TimecodeDiscontinuityHandler = robustness.TimecodeDiscontinuityHandler;
pub const RobustnessManager = robustness.RobustnessManager;

// ============================================================================
// Interoperability
// ============================================================================

pub const interop = @import("interop/interop.zig");
pub const ImageBuffer = interop.ImageBuffer;
pub const RawFrameData = interop.RawFrameData;
pub const AudioBuffer = interop.AudioBuffer;
pub const videoFrameToImage = interop.videoFrameToImage;
pub const imageToVideoFrame = interop.imageToVideoFrame;
pub const videoFrameToRawData = interop.videoFrameToRawData;
pub const rawDataToVideoFrame = interop.rawDataToVideoFrame;
pub const audioFrameToBuffer = interop.audioFrameToBuffer;
pub const bufferToAudioFrame = interop.bufferToAudioFrame;

// ============================================================================
// Broadcast Compliance
// ============================================================================

pub const compliance = @import("compliance/compliance.zig");
pub const BroadcastColorStandard = compliance.ColorStandard;
pub const BroadcastColorPrimaries = compliance.ColorPrimaries;
pub const BroadcastTransferCharacteristics = compliance.TransferCharacteristics;
pub const BroadcastMatrixCoefficients = compliance.MatrixCoefficients;
pub const BroadcastLevels = compliance.BroadcastLevels;
pub const GamutChecker = compliance.GamutChecker;
pub const SmptTimecode = compliance.SmptTimecode;
pub const ComplianceChecker = compliance.ComplianceChecker;

// ============================================================================
// Home Language Bindings
// ============================================================================

pub const bindings = @import("bindings/home_bindings.zig");
pub const VideoBinding = bindings.Video;
pub const AudioBinding = bindings.Audio;
pub const MetadataBinding = bindings.Metadata;
pub const SubtitleBinding = bindings.Subtitle;
pub const GifOptions = bindings.GifOptions;
pub const videoToGif = bindings.videoToGif;
pub const gifToVideo = bindings.gifToVideo;

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
    // Phase 3 modules
    _ = cea608;
    _ = cea708;
    _ = quality;
    _ = detection;
    _ = scenecut;
    _ = rtmp;
    _ = rtp;
    _ = overlay;
    _ = audio_processing;
    _ = stabilization;
    _ = scte35;
    _ = teletext;
    _ = afd;
    _ = wss;
    _ = h264_analysis;
    _ = hevc_analysis;
    _ = bitrate;
    _ = prores;
    _ = dnxhd;
    _ = imf;
    _ = dcp;
    // Phase 4 modules
    _ = pgs;
    _ = vobsub;
    _ = avi;
    _ = ac3;
    _ = dts;
    _ = conversion;
    _ = sources;
    _ = sinks;
    // Additional Considerations modules
    _ = accessibility;
    _ = robustness;
    _ = interop;
    _ = compliance;
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
