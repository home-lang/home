// Home Video Library - Video Filters
// Re-exports all video filter modules

pub const scale = @import("video/scale.zig");
pub const crop = @import("video/crop.zig");
pub const color = @import("video/color.zig");
pub const colorspace = @import("video/colorspace.zig");
pub const transform = @import("video/transform.zig");
pub const convolution = @import("video/convolution.zig");

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

// Color space conversion
pub const ColorSpaceConverter = colorspace.ColorSpaceConverter;
pub const ColorStandard = colorspace.ColorStandard;
pub const yuv420pToRgb24 = colorspace.yuv420pToRgb24;
pub const rgb24ToYuv420p = colorspace.rgb24ToYuv420p;
pub const yuv420pToRgba32 = colorspace.yuv420pToRgba32;

// Transform filters
pub const RotateFilter = transform.RotateFilter;
pub const RotationAngle = transform.RotationAngle;
pub const FlipFilter = transform.FlipFilter;
pub const FlipDirection = transform.FlipDirection;
pub const TransposeFilter = transform.TransposeFilter;

// Convolution filters (blur, sharpen, edge detection)
pub const ConvolutionFilter = convolution.ConvolutionFilter;
pub const Kernel = convolution.Kernel;
pub const Kernels = convolution.Kernels;
pub const BlurFilter = convolution.BlurFilter;
pub const SharpenFilter = convolution.SharpenFilter;
pub const EdgeDetectionFilter = convolution.EdgeDetectionFilter;
pub const EdgeDetectionMode = convolution.EdgeDetectionMode;

// ============================================================================
// Tests
// ============================================================================

test "Video filters imports" {
    _ = scale;
    _ = crop;
    _ = color;
    _ = colorspace;
    _ = transform;
    _ = convolution;
}
