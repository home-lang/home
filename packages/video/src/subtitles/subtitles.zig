// Home Video Library - Subtitles Module
// Re-exports all subtitle format modules

pub const srt = @import("srt.zig");
pub const vtt = @import("vtt.zig");

// SRT types
pub const SrtParser = srt.SrtParser;
pub const SrtWriter = srt.SrtWriter;
pub const SrtCue = srt.Cue;

// VTT types
pub const VttParser = vtt.VttParser;
pub const VttWriter = vtt.VttWriter;
pub const VttCue = vtt.Cue;
pub const VttCueSettings = vtt.CueSettings;
pub const isVtt = vtt.isVtt;

// ============================================================================
// Tests
// ============================================================================

test "Subtitle imports" {
    _ = srt;
    _ = vtt;
}
