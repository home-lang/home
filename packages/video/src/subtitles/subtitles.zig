// Home Video Library - Subtitles Module
// Re-exports all subtitle format modules

pub const srt = @import("srt.zig");
pub const vtt = @import("vtt.zig");
pub const ass = @import("ass.zig");
pub const ttml = @import("ttml.zig");
pub const convert = @import("convert.zig");

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

// ASS/SSA types
pub const AssParser = ass.AssParser;
pub const AssWriter = ass.AssWriter;
pub const AssDialogue = ass.Dialogue;
pub const AssStyle = ass.Style;
pub const AssScriptInfo = ass.ScriptInfo;
pub const isAss = ass.isAss;

// TTML types
pub const TtmlParser = ttml.TtmlParser;
pub const TtmlWriter = ttml.TtmlWriter;
pub const TtmlCue = ttml.Cue;
pub const TtmlStyle = ttml.Style;
pub const TtmlRegion = ttml.Region;
pub const isTtml = ttml.isTtml;

// Conversion types
pub const SubtitleFormat = convert.SubtitleFormat;
pub const UniversalCue = convert.UniversalCue;
pub const UniversalSubtitle = convert.UniversalSubtitle;
pub const UniversalStyle = convert.UniversalStyle;
pub const detectFormat = convert.detectFormat;

// Direct conversion functions
pub const srtToVtt = convert.srtToVtt;
pub const vttToSrt = convert.vttToSrt;
pub const srtToAss = convert.srtToAss;
pub const assToSrt = convert.assToSrt;
pub const srtToTtml = convert.srtToTtml;
pub const ttmlToSrt = convert.ttmlToSrt;
pub const vttToAss = convert.vttToAss;
pub const assToVtt = convert.assToVtt;
pub const vttToTtml = convert.vttToTtml;
pub const ttmlToVtt = convert.ttmlToVtt;
pub const assToTtml = convert.assToTtml;
pub const ttmlToAss = convert.ttmlToAss;
pub const convertSubtitle = convert.convert;

// ============================================================================
// Tests
// ============================================================================

test "Subtitle imports" {
    _ = srt;
    _ = vtt;
    _ = ass;
    _ = ttml;
    _ = convert;
}
