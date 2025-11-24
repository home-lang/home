// Home Audio Library - Metadata Module
// Re-exports all metadata utilities

pub const replaygain = @import("replaygain.zig");
pub const cuesheet = @import("cuesheet.zig");

// Re-export main types
pub const ReplayGain = replaygain.ReplayGain;
pub const CueSheet = cuesheet.CueSheet;
pub const CueTrack = cuesheet.CueTrack;
pub const Timestamp = cuesheet.Timestamp;

test {
    _ = replaygain;
    _ = cuesheet;
}
