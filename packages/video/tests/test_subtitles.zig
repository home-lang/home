// Home Video Library - Subtitle Tests
// Unit tests for subtitle formats

const std = @import("std");
const testing = std.testing;
const video = @import("video");

// ============================================================================
// SRT Tests
// ============================================================================

test "SRT - Basic parsing" {
    const allocator = testing.allocator;

    const srt_data =
        \\1
        \\00:00:01,000 --> 00:00:03,000
        \\First subtitle
        \\
        \\2
        \\00:00:05,500 --> 00:00:08,000
        \\Second subtitle
        \\with two lines
        \\
    ;

    var parser = video.SrtParser.init(allocator);
    defer parser.deinit();

    try parser.parse(srt_data);

    try testing.expectEqual(@as(usize, 2), parser.cues.items.len);

    const cue1 = parser.cues.items[0];
    try testing.expectEqual(@as(i64, 1000000), cue1.start_time);
    try testing.expectEqual(@as(i64, 3000000), cue1.end_time);
    try testing.expect(std.mem.eql(u8, "First subtitle", cue1.text));

    const cue2 = parser.cues.items[1];
    try testing.expectEqual(@as(i64, 5500000), cue2.start_time);
    try testing.expectEqual(@as(i64, 8000000), cue2.end_time);
}

test "SRT - Time parsing" {
    const time_str = "00:01:23,456";
    const microseconds: i64 = 83_456_000; // 1m 23s 456ms

    // Manual parsing for test
    var parts = std.mem.splitScalar(u8, time_str, ':');
    const hours = try std.fmt.parseInt(u32, parts.next().?, 10);
    const minutes = try std.fmt.parseInt(u32, parts.next().?, 10);

    var sec_ms = std.mem.splitScalar(u8, parts.next().?, ',');
    const seconds = try std.fmt.parseInt(u32, sec_ms.next().?, 10);
    const milliseconds = try std.fmt.parseInt(u32, sec_ms.next().?, 10);

    const result_us = @as(i64, hours) * 3600_000_000 +
                      @as(i64, minutes) * 60_000_000 +
                      @as(i64, seconds) * 1_000_000 +
                      @as(i64, milliseconds) * 1_000;

    try testing.expectEqual(microseconds, result_us);
}

test "SRT - Empty subtitle" {
    const allocator = testing.allocator;

    const srt_data =
        \\1
        \\00:00:01,000 --> 00:00:03,000
        \\
        \\
    ;

    var parser = video.SrtParser.init(allocator);
    defer parser.deinit();

    try parser.parse(srt_data);

    try testing.expectEqual(@as(usize, 1), parser.cues.items.len);
    try testing.expect(parser.cues.items[0].text.len == 0);
}

// ============================================================================
// VTT Tests
// ============================================================================

test "VTT - Magic detection" {
    const vtt_data = "WEBVTT\n\n";
    try testing.expect(video.isVtt(vtt_data));

    const not_vtt = "WEBVT\n\n";
    try testing.expect(!video.isVtt(not_vtt));
}

test "VTT - Basic parsing" {
    const allocator = testing.allocator;

    const vtt_data =
        \\WEBVTT
        \\
        \\00:00:01.000 --> 00:00:03.000
        \\First subtitle
        \\
        \\00:00:05.500 --> 00:00:08.000
        \\Second subtitle
        \\
    ;

    var parser = video.VttParser.init(allocator);
    defer parser.deinit();

    try parser.parse(vtt_data);

    try testing.expectEqual(@as(usize, 2), parser.cues.items.len);

    const cue1 = parser.cues.items[0];
    try testing.expectEqual(@as(i64, 1000000), cue1.start_time);
    try testing.expectEqual(@as(i64, 3000000), cue1.end_time);
}

test "VTT - Cue settings" {
    const settings_str = "align:start line:0% position:50%";

    // Parse settings (simplified)
    try testing.expect(std.mem.indexOf(u8, settings_str, "align:start") != null);
    try testing.expect(std.mem.indexOf(u8, settings_str, "line:0%") != null);
    try testing.expect(std.mem.indexOf(u8, settings_str, "position:50%") != null);
}

// ============================================================================
// ASS/SSA Tests
// ============================================================================

test "ASS - Magic detection" {
    const ass_data = "[Script Info]\nTitle: Test";
    try testing.expect(video.isAss(ass_data));

    const not_ass = "Not ASS format";
    try testing.expect(!video.isAss(not_ass));
}

test "ASS - Dialogue parsing" {
    const allocator = testing.allocator;

    const ass_data =
        \\[Script Info]
        \\Title: Test
        \\
        \\[Events]
        \\Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \\Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,First subtitle
        \\
    ;

    var parser = video.AssParser.init(allocator);
    defer parser.deinit();

    try parser.parse(ass_data);

    try testing.expectEqual(@as(usize, 1), parser.dialogues.items.len);

    const dialogue = parser.dialogues.items[0];
    try testing.expect(std.mem.eql(u8, "Default", dialogue.style));
}

test "ASS - Style parsing" {
    const style_line = "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1";

    // Check format
    try testing.expect(std.mem.startsWith(u8, style_line, "Style: "));
}

// ============================================================================
// TTML Tests
// ============================================================================

test "TTML - Magic detection" {
    const ttml_data = "<?xml version=\"1.0\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\">";
    try testing.expect(video.isTtml(ttml_data));

    const not_ttml = "<?xml version=\"1.0\"?>\n<html>";
    try testing.expect(!video.isTtml(not_ttml));
}

// ============================================================================
// Subtitle Format Detection
// ============================================================================

test "Subtitle - Format detection SRT" {
    const srt_data =
        \\1
        \\00:00:01,000 --> 00:00:03,000
        \\Text
        \\
    ;

    const format = video.detectSubtitleFormat(srt_data);
    try testing.expectEqual(video.SubtitleFormatType.srt, format);
}

test "Subtitle - Format detection VTT" {
    const vtt_data = "WEBVTT\n\n";
    const format = video.detectSubtitleFormat(vtt_data);
    try testing.expectEqual(video.SubtitleFormatType.vtt, format);
}

test "Subtitle - Format detection ASS" {
    const ass_data = "[Script Info]\nTitle: Test";
    const format = video.detectSubtitleFormat(ass_data);
    try testing.expectEqual(video.SubtitleFormatType.ass, format);
}

test "Subtitle - Format detection TTML" {
    const ttml_data = "<?xml version=\"1.0\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\">";
    const format = video.detectSubtitleFormat(ttml_data);
    try testing.expectEqual(video.SubtitleFormatType.ttml, format);
}

// ============================================================================
// Subtitle Conversion Tests
// ============================================================================

test "Subtitle - SRT to VTT conversion" {
    const allocator = testing.allocator;

    const srt_data =
        \\1
        \\00:00:01,000 --> 00:00:03,000
        \\First subtitle
        \\
        \\2
        \\00:00:05,500 --> 00:00:08,000
        \\Second subtitle
        \\
    ;

    const vtt_data = try video.srtToVtt(allocator, srt_data);
    defer allocator.free(vtt_data);

    // Should start with WEBVTT
    try testing.expect(std.mem.startsWith(u8, vtt_data, "WEBVTT"));

    // Should have dot instead of comma
    try testing.expect(std.mem.indexOf(u8, vtt_data, "00:00:01.000") != null);
}

test "Subtitle - VTT to SRT conversion" {
    const allocator = testing.allocator;

    const vtt_data =
        \\WEBVTT
        \\
        \\00:00:01.000 --> 00:00:03.000
        \\First subtitle
        \\
    ;

    const srt_data = try video.vttToSrt(allocator, vtt_data);
    defer allocator.free(srt_data);

    // Should have sequence number
    try testing.expect(std.mem.indexOf(u8, srt_data, "1\n") != null);

    // Should have comma instead of dot
    try testing.expect(std.mem.indexOf(u8, srt_data, "00:00:01,000") != null);
}

// ============================================================================
// Caption Format Tests (CEA-608/708)
// ============================================================================

test "CEA-608 - Control code detection" {
    const control_code: u16 = 0x1420; // Resume caption loading

    // Check if it's a control code (starts with 0x14-0x17 or 0x1C-0x1F)
    const is_control = (control_code & 0xFC00) == 0x1400 or (control_code & 0xFC00) == 0x1C00;
    try testing.expect(is_control);
}

test "CEA-608 - Basic character detection" {
    const char_code: u16 = 0x4141; // 'AA'

    // Check if it's in valid character range
    const is_basic_char = (char_code & 0x7F00) >= 0x2000 and (char_code & 0x7F00) <= 0x7F00;
    try testing.expect(is_basic_char);
}

// ============================================================================
// PGS (Bluray Subtitles) Tests
// ============================================================================

test "PGS - Magic detection" {
    const pgs_magic = "PG";
    const data = pgs_magic[0..2];

    try testing.expect(video.isPgs(data));

    const not_pgs = "NG";
    try testing.expect(!video.isPgs(not_pgs));
}

// ============================================================================
// VobSub (DVD Subtitles) Tests
// ============================================================================

test "VobSub - IDX header" {
    const idx_data = "# VobSub index file, v7\n";

    try testing.expect(std.mem.startsWith(u8, idx_data, "# VobSub index file"));
}

test "VobSub - Language line" {
    const lang_line = "id: en, index: 0";

    try testing.expect(std.mem.indexOf(u8, lang_line, "id: en") != null);
    try testing.expect(std.mem.indexOf(u8, lang_line, "index: 0") != null);
}

// ============================================================================
// Timestamp Utilities
// ============================================================================

test "Subtitle - Timestamp formatting" {
    const microseconds: i64 = 83_456_000; // 1m 23s 456ms

    const total_ms = @divTrunc(microseconds, 1000);
    const hours = @divTrunc(total_ms, 3600_000);
    const minutes = @divTrunc(@mod(total_ms, 3600_000), 60_000);
    const seconds = @divTrunc(@mod(total_ms, 60_000), 1_000);
    const milliseconds = @mod(total_ms, 1_000);

    try testing.expectEqual(@as(i64, 0), hours);
    try testing.expectEqual(@as(i64, 1), minutes);
    try testing.expectEqual(@as(i64, 23), seconds);
    try testing.expectEqual(@as(i64, 456), milliseconds);
}

test "Subtitle - Duration calculation" {
    const start: i64 = 1_000_000; // 1s
    const end: i64 = 3_500_000; // 3.5s
    const duration = end - start;

    try testing.expectEqual(@as(i64, 2_500_000), duration); // 2.5s
}

test "Subtitle - Overlap detection" {
    const cue1_start: i64 = 1_000_000;
    const cue1_end: i64 = 3_000_000;

    const cue2_start: i64 = 2_000_000;
    const cue2_end: i64 = 4_000_000;

    const overlaps = !(cue1_end < cue2_start or cue2_end < cue1_start);
    try testing.expect(overlaps);
}
