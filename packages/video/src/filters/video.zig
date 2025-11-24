// Home Video Library - Video Filters
// Re-exports all video filter modules

pub const scale = @import("video/scale.zig");
pub const crop = @import("video/crop.zig");
pub const color = @import("video/color.zig");

// Scale filter
pub const ScaleFilter = scale.ScaleFilter;
pub const ScaleAlgorithm = scale.ScaleAlgorithm;

// Crop filter
pub const CropFilter = crop.CropFilter;

// Color filters
pub const ColorFilter = color.ColorFilter;
pub const ColorAdjustment = color.ColorAdjustment;
pub const InvertFilter = color.InvertFilter;
pub const GrayscaleFilter = color.GrayscaleFilter;

// ============================================================================
// Tests
// ============================================================================

test "Video filters imports" {
    _ = scale;
    _ = crop;
    _ = color;
}
