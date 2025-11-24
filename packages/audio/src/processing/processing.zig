// Home Audio Library - Audio Processing
// Main entry point for audio processing utilities

pub const resampler = @import("resampler.zig");
pub const mixer = @import("mixer.zig");
pub const effects = @import("effects.zig");

// Re-export main types
pub const Resampler = resampler.Resampler;
pub const ResampleQuality = resampler.Quality;
pub const resample = resampler.resample;
pub const convertSampleRate = resampler.convertSampleRate;

pub const Mixer = mixer.Mixer;
pub const PanLaw = mixer.PanLaw;
pub const CrossfadeCurve = mixer.CrossfadeCurve;
pub const mix = mixer.mix;
pub const mixWithClipping = mixer.mixWithClipping;
pub const monoToStereo = mixer.monoToStereo;
pub const stereoToMono = mixer.stereoToMono;
pub const applyGain = mixer.applyGain;
pub const applyGainSoftClip = mixer.applyGainSoftClip;
pub const normalize = mixer.normalize;
pub const crossfade = mixer.crossfade;

pub const BiquadFilter = effects.BiquadFilter;
pub const FilterType = effects.FilterType;
pub const Compressor = effects.Compressor;
pub const NoiseGate = effects.NoiseGate;
pub const Delay = effects.Delay;
pub const Chorus = effects.Chorus;
pub const LFO = effects.LFO;
pub const FadeCurve = effects.FadeCurve;
pub const dbToLinear = effects.dbToLinear;
pub const linearToDb = effects.linearToDb;
pub const fadeIn = effects.fadeIn;
pub const fadeOut = effects.fadeOut;
pub const removeDcOffset = effects.removeDcOffset;

test {
    _ = resampler;
    _ = mixer;
    _ = effects;
}
