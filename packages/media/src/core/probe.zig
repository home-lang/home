// Home Media Library - Format Probing
// Auto-detection of media formats from file content and extensions

const std = @import("std");
const types = @import("types.zig");
const err = @import("error.zig");

const MediaType = types.MediaType;
const MediaInfo = types.MediaInfo;
const ContainerFormat = types.ContainerFormat;
const VideoCodec = types.VideoCodec;
const AudioCodec = types.AudioCodec;
const Duration = types.Duration;
const Rational = types.Rational;
const MediaError = err.MediaError;

// ============================================================================
// Format Detection from Magic Bytes
// ============================================================================

/// Detect container format from file header (magic bytes)
pub fn detectFormat(data: []const u8) ContainerFormat {
    if (data.len < 4) return .unknown;

    // MP4/MOV: Check for ftyp box
    if (data.len >= 12 and
        data[4] == 'f' and data[5] == 't' and data[6] == 'y' and data[7] == 'p')
    {
        // Check brand
        if (std.mem.eql(u8, data[8..12], "qt  ")) return .mov;
        if (std.mem.eql(u8, data[8..12], "isom")) return .mp4;
        if (std.mem.eql(u8, data[8..12], "mp41")) return .mp4;
        if (std.mem.eql(u8, data[8..12], "mp42")) return .mp4;
        if (std.mem.eql(u8, data[8..12], "M4V ")) return .mp4;
        if (std.mem.eql(u8, data[8..12], "M4A ")) return .aac;
        if (std.mem.eql(u8, data[8..12], "avc1")) return .mp4;
        if (std.mem.eql(u8, data[8..12], "hevc")) return .mp4;
        return .mp4; // Default to MP4 for ftyp
    }

    // Matroska/WebM: EBML header
    if (data.len >= 4 and data[0] == 0x1A and data[1] == 0x45 and data[2] == 0xDF and data[3] == 0xA3) {
        // Need to check DocType for mkv vs webm
        // Simplified: assume mkv for now, could scan for doctype
        if (data.len >= 32) {
            // Look for "webm" in first 32 bytes
            for (0..28) |i| {
                if (data.len > i + 4 and
                    data[i] == 'w' and data[i + 1] == 'e' and data[i + 2] == 'b' and data[i + 3] == 'm')
                {
                    return .webm;
                }
            }
        }
        return .mkv;
    }

    // AVI: RIFF....AVI
    if (data.len >= 12 and
        data[0] == 'R' and data[1] == 'I' and data[2] == 'F' and data[3] == 'F' and
        data[8] == 'A' and data[9] == 'V' and data[10] == 'I' and data[11] == ' ')
    {
        return .avi;
    }

    // WAV: RIFF....WAVE
    if (data.len >= 12 and
        data[0] == 'R' and data[1] == 'I' and data[2] == 'F' and data[3] == 'F' and
        data[8] == 'W' and data[9] == 'A' and data[10] == 'V' and data[11] == 'E')
    {
        return .wav;
    }

    // FLV: FLV signature
    if (data[0] == 'F' and data[1] == 'L' and data[2] == 'V') {
        return .flv;
    }

    // MPEG-TS: Sync byte 0x47
    if (data[0] == 0x47) {
        // Check for TS sync at regular intervals
        if (data.len >= 188 * 3) {
            if (data[188] == 0x47 and data[376] == 0x47) {
                return .ts;
            }
        }
        // M2TS uses 192-byte packets
        if (data.len >= 192 * 3) {
            if (data[4] == 0x47 and data[196] == 0x47 and data[388] == 0x47) {
                return .m2ts;
            }
        }
    }

    // Ogg: OggS
    if (data[0] == 'O' and data[1] == 'g' and data[2] == 'g' and data[3] == 'S') {
        return .ogg;
    }

    // MP3: Frame sync or ID3
    if ((data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) or // Frame sync
        (data[0] == 'I' and data[1] == 'D' and data[2] == '3'))
    { // ID3
        return .mp3;
    }

    // FLAC: fLaC
    if (data[0] == 'f' and data[1] == 'L' and data[2] == 'a' and data[3] == 'C') {
        return .flac;
    }

    // AAC ADTS: Sync word 0xFFF
    if ((data[0] == 0xFF and (data[1] & 0xF0) == 0xF0)) {
        return .aac;
    }

    // MXF: MXF partition pack key
    if (data.len >= 14 and
        data[0] == 0x06 and data[1] == 0x0E and data[2] == 0x2B and data[3] == 0x34)
    {
        return .mxf;
    }

    // GIF: GIF87a or GIF89a
    if (data.len >= 6 and data[0] == 'G' and data[1] == 'I' and data[2] == 'F') {
        return .gif;
    }

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (data.len >= 8 and
        data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G' and
        data[4] == 0x0D and data[5] == 0x0A and data[6] == 0x1A and data[7] == 0x0A)
    {
        return .png;
    }

    // JPEG: FF D8 FF
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return .jpeg;
    }

    // WebP: RIFF....WEBP
    if (data.len >= 12 and
        data[0] == 'R' and data[1] == 'I' and data[2] == 'F' and data[3] == 'F' and
        data[8] == 'W' and data[9] == 'E' and data[10] == 'B' and data[11] == 'P')
    {
        return .webp;
    }

    // AVIF/HEIC: ftyp with specific brands
    if (data.len >= 12 and
        data[4] == 'f' and data[5] == 't' and data[6] == 'y' and data[7] == 'p')
    {
        if (std.mem.eql(u8, data[8..12], "avif") or std.mem.eql(u8, data[8..12], "avis")) {
            return .avif;
        }
        if (std.mem.eql(u8, data[8..12], "heic") or std.mem.eql(u8, data[8..12], "heix") or
            std.mem.eql(u8, data[8..12], "hevc") or std.mem.eql(u8, data[8..12], "mif1"))
        {
            return .heic;
        }
    }

    return .unknown;
}

/// Detect media type from file header
pub fn detectMediaType(data: []const u8) MediaType {
    const format = detectFormat(data);

    return switch (format) {
        .mp4, .mov, .mkv, .webm, .avi, .flv, .ts, .m2ts, .mxf => .video,
        .wav, .mp3, .flac, .aac, .ogg => .audio,
        .gif, .png, .jpeg, .webp, .avif, .heic => .image,
        .unknown => MediaType.fromExtension(""), // Will return unknown
    };
}

// ============================================================================
// Probing Functions
// ============================================================================

/// Probe a file and extract media information
pub fn probe(allocator: std.mem.Allocator, path: []const u8) !MediaInfo {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| {
        return switch (e) {
            error.FileNotFound => MediaError.FileNotFound,
            error.AccessDenied => MediaError.PermissionDenied,
            else => MediaError.IoError,
        };
    };
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    // Read header for format detection
    var header_buf: [4096]u8 = undefined;
    const bytes_read = try file.read(&header_buf);
    if (bytes_read == 0) {
        return MediaError.TruncatedData;
    }

    const header = header_buf[0..bytes_read];
    const format = detectFormat(header);

    var info = MediaInfo{
        .format = format,
        .size_bytes = size,
    };

    // Copy path
    info.path = try allocator.dupe(u8, path);

    // Get extension-based info
    const ext = std.fs.path.extension(path);
    const media_type = MediaType.fromExtension(ext);

    // Set basic flags based on media type
    switch (media_type) {
        .video => {
            info.has_video = true;
            info.has_audio = true; // Most videos have audio
        },
        .audio => {
            info.has_audio = true;
        },
        .image => {
            // Images don't have duration
        },
        else => {},
    }

    // Format-specific probing
    switch (format) {
        .mp4, .mov => try probeMp4(file, header, &info),
        .mkv, .webm => try probeMatroska(file, header, &info),
        .avi => try probeAvi(file, header, &info),
        .flv => try probeFlv(file, header, &info),
        .ts, .m2ts => try probeMpegTs(file, header, &info),
        .wav => try probeWav(file, header, &info),
        .mp3 => try probeMp3(file, header, &info),
        .flac => try probeFlac(file, header, &info),
        .ogg => try probeOgg(file, header, &info),
        .png => try probePng(header, &info),
        .jpeg => try probeJpeg(header, &info),
        .gif => try probeGif(header, &info),
        else => {},
    }

    return info;
}

/// Probe media from memory buffer
pub fn probeFromMemory(allocator: std.mem.Allocator, data: []const u8) !MediaInfo {
    _ = allocator;

    if (data.len == 0) {
        return MediaError.InvalidInput;
    }

    const format = detectFormat(data);

    var info = MediaInfo{
        .format = format,
        .size_bytes = data.len,
    };

    // Probe based on format
    // Simplified in-memory probing
    switch (format) {
        .png => try probePng(data, &info),
        .jpeg => try probeJpeg(data, &info),
        .gif => try probeGif(data, &info),
        else => {},
    }

    return info;
}

// ============================================================================
// Format-Specific Probing
// ============================================================================

fn probeMp4(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;
    _ = header;

    // MP4 probing: read boxes to find video/audio tracks
    // Simplified implementation - full version would parse moov/trak boxes
    info.has_video = true;
    info.has_audio = true;
    info.video_codec = .h264; // Common default
    info.audio_codec = .aac;
}

fn probeMatroska(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;

    // Check for webm doctype
    if (header.len >= 32) {
        for (0..28) |i| {
            if (header.len > i + 4 and
                header[i] == 'w' and header[i + 1] == 'e' and header[i + 2] == 'b' and header[i + 3] == 'm')
            {
                info.video_codec = .vp9;
                info.audio_codec = .opus;
                break;
            }
        }
    }

    info.has_video = true;
    info.has_audio = true;
}

fn probeAvi(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;
    _ = header;

    info.has_video = true;
    info.has_audio = true;
}

fn probeFlv(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;

    if (header.len >= 5) {
        const flags = header[4];
        info.has_audio = (flags & 0x04) != 0;
        info.has_video = (flags & 0x01) != 0;
    }
}

fn probeMpegTs(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;
    _ = header;

    info.has_video = true;
    info.has_audio = true;
}

fn probeWav(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;

    info.has_video = false;
    info.has_audio = true;
    info.audio_codec = .pcm;

    if (header.len >= 44) {
        // Read format chunk
        info.channels = @as(u8, @truncate(std.mem.readInt(u16, header[22..24], .little)));
        info.sample_rate = std.mem.readInt(u32, header[24..28], .little);
        info.audio_bitrate = std.mem.readInt(u32, header[28..32], .little) * 8 / 1000;
    }
}

fn probeMp3(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;

    info.has_video = false;
    info.has_audio = true;
    info.audio_codec = .mp3;

    // Skip ID3 tag if present
    var offset: usize = 0;
    if (header.len >= 10 and header[0] == 'I' and header[1] == 'D' and header[2] == '3') {
        const id3_size = (@as(u32, header[6]) << 21) | (@as(u32, header[7]) << 14) |
            (@as(u32, header[8]) << 7) | @as(u32, header[9]);
        offset = 10 + id3_size;
    }

    // Find MP3 frame header
    if (offset + 4 <= header.len and header[offset] == 0xFF and (header[offset + 1] & 0xE0) == 0xE0) {
        const h = header[offset..];

        // Parse MP3 frame header
        const version_bits = (h[1] >> 3) & 0x03;
        const layer_bits = (h[1] >> 1) & 0x03;
        const bitrate_index = (h[2] >> 4) & 0x0F;
        const sample_rate_index = (h[2] >> 2) & 0x03;
        const channel_mode = (h[3] >> 6) & 0x03;

        // Sample rates for MPEG-1
        const sample_rates = [_]u32{ 44100, 48000, 32000, 0 };
        if (version_bits == 3 and layer_bits == 1) { // MPEG-1 Layer 3
            info.sample_rate = sample_rates[sample_rate_index];
        }

        // Bitrates for MPEG-1 Layer 3
        const bitrates = [_]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
        if (bitrate_index < bitrates.len) {
            info.audio_bitrate = bitrates[bitrate_index];
        }

        info.channels = if (channel_mode == 3) 1 else 2;
    }
}

fn probeFlac(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;

    info.has_video = false;
    info.has_audio = true;
    info.audio_codec = .flac;

    // Parse STREAMINFO metadata block
    if (header.len >= 42) {
        // STREAMINFO starts at byte 4 (after "fLaC")
        const block_header = header[4];
        const is_last = (block_header & 0x80) != 0;
        const block_type = block_header & 0x7F;
        _ = is_last;

        if (block_type == 0) { // STREAMINFO
            const data = header[8..];
            if (data.len >= 18) {
                // Sample rate is bits 0-19 of bytes 10-12
                info.sample_rate = (@as(u32, data[10]) << 12) |
                    (@as(u32, data[11]) << 4) |
                    (@as(u32, data[12]) >> 4);

                // Channels is bits 4-6 of byte 12 (+1)
                info.channels = @as(u8, @truncate(((data[12] >> 1) & 0x07) + 1));
            }
        }
    }
}

fn probeOgg(file: std.fs.File, header: []const u8, info: *MediaInfo) !void {
    _ = file;

    info.has_video = false;
    info.has_audio = true;

    // Check for Vorbis or Opus identification header
    if (header.len >= 35) {
        // Look for codec identification
        for (0..27) |i| {
            if (header.len > i + 7) {
                if (std.mem.eql(u8, header[i..][0..7], "\x01vorbis")) {
                    info.audio_codec = .vorbis;
                    break;
                }
                if (header.len > i + 8 and std.mem.eql(u8, header[i..][0..8], "OpusHead")) {
                    info.audio_codec = .opus;
                    break;
                }
            }
        }
    }
}

fn probePng(header: []const u8, info: *MediaInfo) !void {
    info.has_video = false;
    info.has_audio = false;

    // PNG IHDR chunk starts at byte 8
    if (header.len >= 24) {
        info.width = std.mem.readInt(u32, header[16..20], .big);
        info.height = std.mem.readInt(u32, header[20..24], .big);
    }
}

fn probeJpeg(header: []const u8, info: *MediaInfo) !void {
    info.has_video = false;
    info.has_audio = false;

    // Scan for SOF0/SOF2 marker to get dimensions
    var i: usize = 2;
    while (i + 8 < header.len) {
        if (header[i] == 0xFF) {
            const marker = header[i + 1];
            if (marker == 0xC0 or marker == 0xC2) { // SOF0 or SOF2
                info.height = std.mem.readInt(u16, header[i + 5 ..][0..2], .big);
                info.width = std.mem.readInt(u16, header[i + 7 ..][0..2], .big);
                break;
            }
            if (marker == 0xD9) break; // EOI
            if (marker >= 0xD0 and marker <= 0xD8) {
                i += 2; // RST markers have no length
            } else {
                const len = std.mem.readInt(u16, header[i + 2 ..][0..2], .big);
                i += 2 + len;
            }
        } else {
            i += 1;
        }
    }
}

fn probeGif(header: []const u8, info: *MediaInfo) !void {
    info.has_video = false;
    info.has_audio = false;

    if (header.len >= 10) {
        info.width = std.mem.readInt(u16, header[6..8], .little);
        info.height = std.mem.readInt(u16, header[8..10], .little);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Format detection - PNG" {
    const png_header = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0 };
    try std.testing.expectEqual(ContainerFormat.png, detectFormat(&png_header));
}

test "Format detection - JPEG" {
    const jpeg_header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0 };
    try std.testing.expectEqual(ContainerFormat.jpeg, detectFormat(&jpeg_header));
}

test "Format detection - GIF" {
    const gif_header = [_]u8{ 'G', 'I', 'F', '8', '9', 'a', 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(ContainerFormat.gif, detectFormat(&gif_header));
}

test "Format detection - MP3" {
    const mp3_header = [_]u8{ 0xFF, 0xFB, 0x90, 0x00, 0, 0, 0, 0 };
    try std.testing.expectEqual(ContainerFormat.mp3, detectFormat(&mp3_header));
}

test "Format detection - FLAC" {
    const flac_header = [_]u8{ 'f', 'L', 'a', 'C', 0, 0, 0, 0 };
    try std.testing.expectEqual(ContainerFormat.flac, detectFormat(&flac_header));
}

test "Format detection - WAV" {
    const wav_header = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    try std.testing.expectEqual(ContainerFormat.wav, detectFormat(&wav_header));
}
