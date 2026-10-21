//! Test-only facade: keep independent-reader fixtures in one Zig module.
pub const Embed = @import("metadata_embed.zig");
pub const Icc = @import("metadata/icc.zig");
pub const Raster = @import("formats/raster_encoder.zig");
pub const Jpeg = @import("jpeg_encoder.zig");
