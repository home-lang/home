// Home Audio Library
// A comprehensive, dependency-free audio processing library
// for the Home programming language, implemented in pure Zig.
//
// Supported formats:
// - WAV  (read/write) - Waveform Audio File Format
// - MP3  (read)       - MPEG Audio Layer III
// - FLAC (read/write) - Free Lossless Audio Codec
// - OGG  (read)       - Ogg Vorbis
// - AAC  (read)       - Advanced Audio Coding (ADTS)
// - AIFF (read/write) - Audio Interchange File Format
// - Opus (read)       - Opus Audio Codec (in OGG container)
// - WMA  (read)       - Windows Media Audio (ASF container)
// - M4A  (read)       - MPEG-4 Audio (AAC/ALAC in MP4 container)
// - MKA  (read)       - Matroska Audio / WebM
// - CAF  (read)       - Core Audio Format (Apple)
// - DSD  (read)       - Direct Stream Digital (DSF/DSDIFF)
// - APE  (read)       - Monkey's Audio
// - TTA  (read)       - True Audio
// - WavPack (read)    - WavPack hybrid lossless

const std = @import("std");

// ============================================================================
// Core Types
// ============================================================================

pub const types = @import("core/types.zig");
pub const AudioFormat = types.AudioFormat;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const ChannelType = types.ChannelType;
pub const AudioCodec = types.AudioCodec;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const QualityPreset = types.QualityPreset;
pub const EncoderOptions = types.EncoderOptions;
pub const Metadata = types.Metadata;

// ============================================================================
// Frame Types
// ============================================================================

pub const frame = @import("core/frame.zig");
pub const AudioFrame = frame.AudioFrame;
pub const AudioBuffer = frame.AudioBuffer;

// ============================================================================
// Error Types
// ============================================================================

pub const err = @import("core/error.zig");
pub const AudioError = err.AudioError;
pub const ErrorContext = err.ErrorContext;
pub const Result = err.Result;
pub const makeError = err.makeError;
pub const isRecoverable = err.isRecoverable;
pub const getUserMessage = err.getUserMessage;
pub const getCategory = err.getCategory;
pub const ErrorCategory = err.ErrorCategory;

// ============================================================================
// Format Modules
// ============================================================================

pub const wav = @import("formats/wav.zig");
pub const WavReader = wav.WavReader;
pub const WavWriter = wav.WavWriter;
pub const WavHeader = wav.WavHeader;

pub const mp3 = @import("formats/mp3.zig");
pub const Mp3Reader = mp3.Mp3Reader;
pub const Mp3FrameHeader = mp3.Mp3FrameHeader;
pub const MpegVersion = mp3.MpegVersion;
pub const MpegLayer = mp3.MpegLayer;
pub const ChannelMode = mp3.ChannelMode;
pub const Id3Tag = mp3.Id3Tag;
pub const Id3Version = mp3.Id3Version;

pub const flac = @import("formats/flac.zig");
pub const FlacReader = flac.FlacReader;
pub const StreamInfo = flac.StreamInfo;
pub const VorbisComment = flac.VorbisComment;
pub const FlacFrameHeader = flac.FlacFrameHeader;

pub const ogg = @import("formats/ogg.zig");
pub const OggReader = ogg.OggReader;
pub const OggPage = ogg.OggPage;
pub const OggPageWriter = ogg.OggPageWriter;
pub const VorbisIdHeader = ogg.VorbisIdHeader;
pub const VorbisCommentHeader = ogg.VorbisCommentHeader;

pub const aac = @import("formats/aac.zig");
pub const AacReader = aac.AacReader;
pub const AdtsHeader = aac.AdtsHeader;
pub const AdtsParser = aac.AdtsParser;
pub const AudioObjectType = aac.AudioObjectType;
pub const AudioSpecificConfig = aac.AudioSpecificConfig;

pub const aiff = @import("formats/aiff.zig");
pub const AiffReader = aiff.AiffReader;
pub const AiffWriter = aiff.AiffWriter;
pub const AiffHeader = aiff.AiffHeader;

pub const opus = @import("formats/opus.zig");
pub const OpusReader = opus.OpusReader;
pub const OpusHeader = opus.OpusHeader;

pub const wma = @import("formats/wma.zig");
pub const WmaReader = wma.WmaReader;
pub const WmaFormat = wma.WmaFormat;

pub const m4a = @import("formats/m4a.zig");
pub const M4aReader = m4a.M4aReader;

pub const flac_writer = @import("formats/flac_writer.zig");
pub const FlacWriter = flac_writer.FlacWriter;

pub const matroska = @import("formats/matroska.zig");
pub const MatroskaReader = matroska.MatroskaReader;
pub const MatroskaCodec = matroska.MatroskaCodec;

pub const caf = @import("formats/caf.zig");
pub const CafReader = caf.CafReader;
pub const CafFormatCode = caf.CafFormatCode;

pub const dsd = @import("formats/dsd.zig");
pub const DsfReader = dsd.DsfReader;
pub const DsdiffReader = dsd.DsdiffReader;
pub const DsdRate = dsd.DsdRate;

pub const ape = @import("formats/ape.zig");
pub const ApeReader = ape.ApeReader;
pub const ApeCompression = ape.ApeCompression;

pub const tta = @import("formats/tta.zig");
pub const TtaReader = tta.TtaReader;
pub const TtaFormat = tta.TtaFormat;

pub const wavpack = @import("formats/wavpack.zig");
pub const WavPackReader = wavpack.WavPackReader;
pub const WavPackFlags = wavpack.WavPackFlags;

pub const midi = @import("formats/midi.zig");
pub const MidiReader = midi.MidiReader;
pub const MidiFormat = midi.MidiFormat;
pub const MidiEvent = midi.MidiEvent;
pub const MidiTrack = midi.MidiTrack;

// ============================================================================
// Processing Modules
// ============================================================================

pub const processing = @import("processing/processing.zig");
pub const Resampler = processing.Resampler;
pub const ResampleQuality = processing.ResampleQuality;
pub const Mixer = processing.Mixer;
pub const PanLaw = processing.PanLaw;
pub const BiquadFilter = processing.BiquadFilter;
pub const Compressor = processing.Compressor;
pub const NoiseGate = processing.NoiseGate;
pub const Delay = processing.Delay;
pub const Chorus = processing.Chorus;
pub const LFO = processing.LFO;

// Extended processing
pub const converter = @import("processing/converter.zig");
pub const channels = @import("processing/channels.zig");
pub const loudness = @import("processing/loudness.zig");
pub const fft = @import("processing/fft.zig");
pub const pitch = @import("processing/pitch.zig");
pub const timestretch = @import("processing/timestretch.zig");
pub const reverb = @import("processing/reverb.zig");

// Processing types
pub const LoudnessMeter = loudness.LoudnessMeter;
pub const LoudnessResult = loudness.LoudnessResult;
pub const SpectrumAnalyzer = fft.SpectrumAnalyzer;
pub const WindowType = fft.WindowType;
pub const PitchDetector = pitch.PitchDetector;
pub const Note = pitch.Note;
pub const TimeStretcher = timestretch.TimeStretcher;
pub const Reverb = reverb.Reverb;
pub const ReverbPreset = reverb.ReverbPreset;
pub const DownmixCoefficients = channels.DownmixCoefficients;

// ============================================================================
// Metadata Modules
// ============================================================================

pub const metadata = @import("metadata/metadata.zig");
pub const ReplayGain = metadata.ReplayGain;
pub const CueSheet = metadata.CueSheet;
pub const CueTrack = metadata.CueTrack;
pub const CueTimestamp = metadata.Timestamp;

// Extended processing
pub const equalizer = @import("processing/equalizer.zig");
pub const limiter = @import("processing/limiter.zig");
pub const deesser = @import("processing/deesser.zig");
pub const stereo = @import("processing/stereo.zig");
pub const noise = @import("processing/noise.zig");
pub const convolution = @import("processing/convolution.zig");
pub const vocoder = @import("processing/vocoder.zig");
pub const crossfade = @import("processing/crossfade.zig");
pub const gapless = @import("processing/gapless.zig");
pub const multiband = @import("processing/multiband.zig");
pub const modulation = @import("processing/modulation.zig");
pub const sidechain = @import("processing/sidechain.zig");
pub const tape = @import("processing/tape.zig");
pub const phasevocoder = @import("processing/phasevocoder.zig");

// Effects types
pub const ParametricEQ = equalizer.ParametricEQ;
pub const GraphicEQ = equalizer.GraphicEQ;
pub const ParametricBand = equalizer.ParametricBand;
pub const FilterType = equalizer.FilterType;
pub const BrickwallLimiter = limiter.BrickwallLimiter;
pub const LookAheadLimiter = limiter.LookAheadLimiter;
pub const SoftKneeLimiter = limiter.SoftKneeLimiter;
pub const Deesser = deesser.Deesser;
pub const MultibandDeesser = deesser.MultibandDeesser;
pub const StereoWidener = stereo.StereoWidener;
pub const StereoBalance = stereo.StereoBalance;
pub const MidSideProcessor = stereo.MidSideProcessor;
pub const StereoCorrelation = stereo.StereoCorrelation;
pub const HaasWidener = stereo.HaasWidener;
pub const NoiseReductionGate = noise.NoiseGate;
pub const Expander = noise.Expander;
pub const SpectralNoiseReducer = noise.SpectralNoiseReducer;
pub const ConvolutionReverb = convolution.ConvolutionReverb;
pub const ReverbSpace = convolution.ReverbSpace;
pub const Vocoder = vocoder.Vocoder;
pub const VocoderPreset = vocoder.VocoderPreset;
pub const Crossfader = crossfade.Crossfader;
pub const CrossfadeCurve = crossfade.CrossfadeCurve;
pub const CrossfadeDetector = crossfade.CrossfadeDetector;
pub const GaplessPlayer = gapless.GaplessPlayer;
pub const GapAnalyzer = gapless.GapAnalyzer;
pub const GapInfo = gapless.GapInfo;
pub const MultibandCompressor = multiband.MultibandCompressor;
pub const BandConfig = multiband.BandConfig;
pub const MultibandPreset = multiband.MultibandPreset;
pub const Tremolo = modulation.Tremolo;
pub const Vibrato = modulation.Vibrato;
pub const RingModulator = modulation.RingModulator;
pub const Flanger = modulation.Flanger;
pub const Phaser = modulation.Phaser;
pub const SidechainCompressor = sidechain.SidechainCompressor;
pub const SidechainGate = sidechain.SidechainGate;
pub const DuckingPreset = sidechain.DuckingPreset;
pub const TapeSaturation = tape.TapeSaturation;
pub const TapePreset = tape.TapePreset;
pub const TubeSaturation = tape.TubeSaturation;
pub const PhaseVocoder = phasevocoder.PhaseVocoder;
pub const SimpleTimeStretcher = phasevocoder.SimpleTimeStretcher;

// ============================================================================
// I/O Modules
// ============================================================================

pub const io = @import("io/io.zig");
pub const AudioOutput = io.AudioOutput;
pub const CoreAudioOutput = io.CoreAudioOutput;
pub const AlsaOutput = io.AlsaOutput;
pub const WasapiOutput = io.WasapiOutput;
pub const AudioRecorder = io.AudioRecorder;
pub const RecordingState = io.RecordingState;
pub const VoiceActivityDetector = io.VoiceActivityDetector;

// ============================================================================
// Analysis Modules
// ============================================================================

pub const analysis = @import("analysis/analysis.zig");
pub const OnsetDetector = analysis.OnsetDetector;
pub const TempoEstimator = analysis.TempoEstimator;
pub const BeatTracker = analysis.BeatTracker;
pub const WaveformGenerator = analysis.WaveformGenerator;
pub const WaveformPoint = analysis.WaveformPoint;
pub const WaveformStats = analysis.WaveformStats;
pub const SilenceDetector = analysis.SilenceDetector;
pub const AudioSplitter = analysis.AudioSplitter;
pub const SilenceRemover = analysis.SilenceRemover;
pub const AudioFingerprinter = analysis.AudioFingerprinter;
pub const FingerprintDatabase = analysis.FingerprintDatabase;
pub const AudioFingerprint = analysis.AudioFingerprint;

// Chord/key detection
pub const chords = @import("analysis/chords.zig");
pub const PitchClass = chords.PitchClass;
pub const ChordQuality = chords.ChordQuality;
pub const Chord = chords.Chord;
pub const Key = chords.Key;
pub const Chromagram = chords.Chromagram;
pub const ChordDetector = chords.ChordDetector;
pub const KeyDetector = chords.KeyDetector;

// ============================================================================
// Synthesis Modules
// ============================================================================

pub const synthesis = @import("synthesis/synth.zig");
pub const Waveform = synthesis.Waveform;
pub const Envelope = synthesis.Envelope;
pub const Voice = synthesis.Voice;
pub const Synthesizer = synthesis.Synthesizer;
pub const FMSynth = synthesis.FMSynth;
pub const midiToFreq = synthesis.midiToFreq;

// ============================================================================
// Encoding Modules
// ============================================================================

pub const encoding = @import("encoding/encoding.zig");
pub const Mp3Encoder = encoding.Mp3Encoder;
pub const Mp3Quality = encoding.Mp3Quality;
pub const Id3v2Writer = encoding.Id3v2Writer;
pub const AacEncoder = encoding.AacEncoder;
pub const AacQuality = encoding.AacQuality;
pub const AacProfile = encoding.AacProfile;
pub const OpusEncoder = encoding.OpusEncoder;
pub const OpusQuality = encoding.OpusQuality;
pub const OggOpusWriter = encoding.OggOpusWriter;

// ============================================================================
// Utility Modules
// ============================================================================

pub const utils = @import("utils/utils.zig");
pub const Playlist = utils.Playlist;
pub const PlaylistEntry = utils.PlaylistEntry;
pub const M3uParser = utils.M3uParser;
pub const PlsParser = utils.PlsParser;
pub const M3uWriter = utils.M3uWriter;
pub const PlsWriter = utils.PlsWriter;
pub const BatchConverter = utils.BatchConverter;
pub const BatchOptions = utils.BatchOptions;
pub const ConversionPreset = utils.ConversionPreset;

// ============================================================================
// High-Level API
// ============================================================================

/// Audio file for simple operations
pub const Audio = struct {
    frames: std.ArrayList(AudioFrame),
    sample_rate: u32,
    channels: u8,
    format: SampleFormat,
    metadata: ?Metadata,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Load audio from file (auto-detects format)
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
        defer allocator.free(data);

        return loadFromMemory(allocator, data);
    }

    /// Load audio from memory (auto-detects format)
    pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        const format_type = AudioFormat.fromMagicBytes(data);

        return switch (format_type) {
            .wav => loadWav(allocator, data),
            .aiff => loadAiff(allocator, data),
            .mp3 => loadMp3Info(allocator, data),
            .flac => loadFlacInfo(allocator, data),
            .ogg => loadOggInfo(allocator, data),
            .aac, .m4a => loadAacInfo(allocator, data),
            else => AudioError.UnsupportedFormat,
        };
    }

    fn loadWav(allocator: std.mem.Allocator, data: []const u8) !Self {
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
            .metadata = null,
            .allocator = allocator,
        };
    }

    fn loadAiff(allocator: std.mem.Allocator, data: []const u8) !Self {
        var reader = try AiffReader.fromMemory(allocator, data);

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
            .sample_rate = @intFromFloat(reader.header.sample_rate),
            .channels = @intCast(reader.header.channels),
            .format = reader.header.getSampleFormat() orelse .s16be,
            .metadata = null,
            .allocator = allocator,
        };
    }

    fn loadMp3Info(allocator: std.mem.Allocator, data: []const u8) !Self {
        var reader = try Mp3Reader.fromMemory(allocator, data);
        defer reader.deinit();

        // MP3 decoding not implemented - return info only
        return Self{
            .frames = std.ArrayList(AudioFrame).init(allocator),
            .sample_rate = reader.getSampleRate(),
            .channels = reader.getChannels(),
            .format = .s16le,
            .metadata = reader.getMetadata(),
            .allocator = allocator,
        };
    }

    fn loadFlacInfo(allocator: std.mem.Allocator, data: []const u8) !Self {
        var reader = try FlacReader.fromMemory(allocator, data);
        defer reader.deinit();

        return Self{
            .frames = std.ArrayList(AudioFrame).init(allocator),
            .sample_rate = reader.getSampleRate(),
            .channels = reader.getChannels(),
            .format = reader.stream_info.getSampleFormat(),
            .metadata = reader.getMetadata(),
            .allocator = allocator,
        };
    }

    fn loadOggInfo(allocator: std.mem.Allocator, data: []const u8) !Self {
        var reader = try OggReader.fromMemory(allocator, data);
        defer reader.deinit();

        return Self{
            .frames = std.ArrayList(AudioFrame).init(allocator),
            .sample_rate = reader.getSampleRate(),
            .channels = reader.getChannels(),
            .format = .f32le,
            .metadata = reader.getMetadata(),
            .allocator = allocator,
        };
    }

    fn loadAacInfo(allocator: std.mem.Allocator, data: []const u8) !Self {
        const reader = try AacReader.fromMemory(allocator, data);

        return Self{
            .frames = std.ArrayList(AudioFrame).init(allocator),
            .sample_rate = reader.getSampleRate(),
            .channels = reader.getChannels(),
            .format = .f32le,
            .metadata = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.frames.items) |*f| {
            f.deinit();
        }
        self.frames.deinit();
        if (self.metadata) |*m| {
            m.deinit();
        }
    }

    /// Save audio to file (format determined by extension)
    pub fn save(self: *const Self, path: []const u8) !void {
        const ext = std.fs.path.extension(path);
        const format_type = AudioFormat.fromExtension(ext);

        try self.saveAs(path, format_type);
    }

    /// Save audio as specific format
    pub fn saveAs(self: *const Self, path: []const u8, format_type: AudioFormat) !void {
        const data = try self.encode(format_type);
        defer self.allocator.free(data);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    /// Encode to specific format
    pub fn encode(self: *const Self, format_type: AudioFormat) ![]u8 {
        return switch (format_type) {
            .wav => self.encodeWav(),
            .aiff => self.encodeAiff(),
            else => AudioError.UnsupportedFormat,
        };
    }

    fn encodeWav(self: *const Self) ![]u8 {
        var writer = try WavWriter.init(self.allocator, self.channels, self.sample_rate, self.format);
        defer writer.deinit();

        for (self.frames.items) |*audio_frame| {
            try writer.writeFrame(audio_frame);
        }

        return try writer.finalize();
    }

    fn encodeAiff(self: *const Self) ![]u8 {
        const bits = self.format.bitsPerSample();
        var writer = try AiffWriter.init(self.allocator, self.channels, self.sample_rate, bits);
        defer writer.deinit();

        for (self.frames.items) |*audio_frame| {
            try writer.writeFrame(audio_frame);
        }

        return try writer.finalize();
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

    /// Check if audio data is loaded (vs just metadata)
    pub fn hasAudioData(self: *const Self) bool {
        return self.frames.items.len > 0;
    }

    /// Get a sample value
    pub fn getSample(self: *const Self, sample_idx: u64, channel: u8) ?f32 {
        var offset: u64 = 0;
        for (self.frames.items) |*audio_frame| {
            if (sample_idx < offset + audio_frame.num_samples) {
                return audio_frame.getSampleF32(sample_idx - offset, channel);
            }
            offset += audio_frame.num_samples;
        }
        return null;
    }
};

// ============================================================================
// Format Detection
// ============================================================================

/// Detect audio format from file extension
pub fn formatFromExtension(ext: []const u8) AudioFormat {
    return AudioFormat.fromExtension(ext);
}

/// Detect audio format from magic bytes
pub fn formatFromMagic(data: []const u8) AudioFormat {
    return AudioFormat.fromMagicBytes(data);
}

/// Check if format is supported for reading
pub fn canRead(format_type: AudioFormat) bool {
    return switch (format_type) {
        .wav, .mp3, .flac, .ogg, .aac, .m4a, .aiff, .opus, .wma => true,
        else => false,
    };
}

/// Check if format is supported for writing
pub fn canWrite(format_type: AudioFormat) bool {
    return switch (format_type) {
        .wav, .aiff => true,
        else => false,
    };
}

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

test "Audio library imports" {
    // Verify all modules can be imported
    _ = types;
    _ = frame;
    _ = err;
    _ = wav;
    _ = mp3;
    _ = flac;
    _ = ogg;
    _ = aac;
    _ = aiff;
    _ = opus;
    _ = wma;
    _ = m4a;
    _ = flac_writer;
    _ = matroska;
    _ = caf;
    _ = dsd;
    _ = ape;
    _ = tta;
    _ = wavpack;
    _ = midi;
    _ = processing;
    _ = converter;
    _ = channels;
    _ = loudness;
    _ = fft;
    _ = pitch;
    _ = timestretch;
    _ = reverb;
    _ = metadata;
    _ = equalizer;
    _ = limiter;
    _ = deesser;
    _ = stereo;
    _ = noise;
    _ = convolution;
    _ = vocoder;
    _ = crossfade;
    _ = gapless;
    _ = io;
    _ = analysis;
    _ = encoding;
    _ = utils;
}

test "Format detection" {
    try std.testing.expectEqual(AudioFormat.wav, AudioFormat.fromExtension(".wav"));
    try std.testing.expectEqual(AudioFormat.mp3, AudioFormat.fromExtension(".mp3"));
    try std.testing.expectEqual(AudioFormat.flac, AudioFormat.fromExtension(".flac"));
    try std.testing.expectEqual(AudioFormat.ogg, AudioFormat.fromExtension(".ogg"));
    try std.testing.expectEqual(AudioFormat.aac, AudioFormat.fromExtension(".aac"));
    try std.testing.expectEqual(AudioFormat.aiff, AudioFormat.fromExtension(".aiff"));
}

test "Format capabilities" {
    try std.testing.expect(canRead(.wav));
    try std.testing.expect(canRead(.mp3));
    try std.testing.expect(canWrite(.wav));
    try std.testing.expect(!canWrite(.mp3));
}

test "Timestamp basic" {
    const ts = Timestamp.fromSeconds(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);
}

test "Duration basic" {
    const d = Duration.fromSeconds(60.0);
    try std.testing.expectEqual(@as(u64, 60000), d.toMilliseconds());
}

test "SampleFormat" {
    try std.testing.expectEqual(@as(u8, 2), SampleFormat.s16le.bytesPerSample());
    try std.testing.expectEqual(@as(u8, 4), SampleFormat.f32le.bytesPerSample());
    try std.testing.expect(SampleFormat.f32le.isFloat());
    try std.testing.expect(!SampleFormat.s16le.isFloat());
}

test "ChannelLayout" {
    try std.testing.expectEqual(@as(u8, 2), ChannelLayout.stereo.channelCount());
    try std.testing.expectEqual(@as(u8, 6), ChannelLayout.surround_51.channelCount());
}

// Import tests from all new modules
test {
    _ = multiband;
    _ = modulation;
    _ = sidechain;
    _ = tape;
    _ = phasevocoder;
    _ = chords;
    _ = synthesis;
}
