// Home Video Library - Streaming Module
// HLS and DASH streaming protocol support

pub const hls = @import("hls.zig");
pub const dash = @import("dash.zig");

// HLS types
pub const HlsPlaylist = hls.Playlist;
pub const HlsPlaylistType = hls.PlaylistType;
pub const HlsVariantStream = hls.VariantStream;
pub const HlsSegment = hls.Segment;
pub const HlsRendition = hls.Rendition;
pub const HlsEncryptionKey = hls.EncryptionKey;
pub const isHls = hls.isHls;

// DASH types
pub const DashManifest = dash.Manifest;
pub const DashManifestType = dash.ManifestType;
pub const DashPeriod = dash.Period;
pub const DashAdaptationSet = dash.AdaptationSet;
pub const DashRepresentation = dash.Representation;
pub const DashSegmentTemplate = dash.SegmentTemplate;
pub const isDash = dash.isDash;

// ============================================================================
// Tests
// ============================================================================

test "Streaming imports" {
    _ = hls;
    _ = dash;
}
