// Home Audio Library - I/O Module
// Cross-platform audio input/output and MIDI support

pub const coreaudio = @import("coreaudio.zig");
pub const alsa = @import("alsa.zig");
pub const wasapi = @import("wasapi.zig");
pub const recorder = @import("recorder.zig");

// Re-export common types
pub const CoreAudioOutput = coreaudio.CoreAudioOutput;
pub const AudioDeviceInfo = coreaudio.AudioDeviceInfo;

pub const AlsaOutput = alsa.AlsaOutput;
pub const PcmFormat = alsa.PcmFormat;
pub const PcmAccess = alsa.PcmAccess;

pub const WasapiOutput = wasapi.WasapiOutput;
pub const ShareMode = wasapi.ShareMode;
pub const WaveFormat = wasapi.WaveFormat;

pub const AudioRecorder = recorder.AudioRecorder;
pub const RecordingState = recorder.RecordingState;
pub const VoiceActivityDetector = recorder.VoiceActivityDetector;
pub const InputDeviceInfo = recorder.InputDeviceInfo;

// Platform-specific output selection
pub const AudioOutput = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos => CoreAudioOutput,
    .linux, .freebsd, .openbsd, .netbsd => AlsaOutput,
    .windows => WasapiOutput,
    else => CoreAudioOutput, // Default fallback
};

test "io module" {
    _ = coreaudio;
    _ = alsa;
    _ = wasapi;
    _ = recorder;
}
