// Home Video Library - Audio Filters
// Re-exports all audio filter modules

pub const volume = @import("audio/volume.zig");
pub const resample = @import("audio/resample.zig");

// Volume and normalization
pub const VolumeFilter = volume.VolumeFilter;
pub const NormalizeFilter = volume.NormalizeFilter;

// Resampling and channel mixing
pub const ResampleFilter = resample.ResampleFilter;
pub const ResampleQuality = resample.ResampleQuality;
pub const ChannelMixer = resample.ChannelMixer;

// ============================================================================
// Tests
// ============================================================================

test "Audio filters imports" {
    _ = volume;
    _ = resample;
}
