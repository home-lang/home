// Home Audio Library - Analysis Module
// Audio analysis tools for beat detection, waveform generation, silence detection, and fingerprinting

pub const beat = @import("beat.zig");
pub const waveform = @import("waveform.zig");
pub const silence = @import("silence.zig");
pub const fingerprint = @import("fingerprint.zig");

// Re-export main types
pub const OnsetDetector = beat.OnsetDetector;
pub const TempoEstimator = beat.TempoEstimator;
pub const BeatTracker = beat.BeatTracker;
pub const BeatInfo = beat.BeatInfo;
pub const OnsetType = beat.OnsetType;

pub const WaveformGenerator = waveform.WaveformGenerator;
pub const StreamingWaveformGenerator = waveform.StreamingWaveformGenerator;
pub const OverviewWaveform = waveform.OverviewWaveform;
pub const WaveformPoint = waveform.WaveformPoint;
pub const WaveformResolution = waveform.WaveformResolution;
pub const WaveformStats = waveform.WaveformStats;

pub const SilenceDetector = silence.SilenceDetector;
pub const AudioSplitter = silence.AudioSplitter;
pub const SilenceRemover = silence.SilenceRemover;
pub const SilenceRegion = silence.SilenceRegion;
pub const AudioSegment = silence.AudioSegment;
pub const SilenceConfig = silence.SilenceConfig;

pub const AudioFingerprinter = fingerprint.AudioFingerprinter;
pub const FingerprintDatabase = fingerprint.FingerprintDatabase;
pub const AudioFingerprint = fingerprint.AudioFingerprint;
pub const FingerprintFrame = fingerprint.FingerprintFrame;
pub const FingerprintMatch = fingerprint.FingerprintMatch;

test "analysis module" {
    _ = beat;
    _ = waveform;
    _ = silence;
    _ = fingerprint;
}
