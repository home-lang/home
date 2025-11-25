/// Audio Extractor Example
/// Extracts audio track from video files
const std = @import("std");
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <video_input> <audio_output>\n", .{args[0]});
        std.debug.print("\nExample: {s} video.mp4 audio.wav\n", .{args[0]});
        std.debug.print("Supported output formats: .wav, .mp3, .aac, .flac\n", .{});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];

    std.debug.print("Extracting audio from: {s}\n", .{input_path});

    // Load video
    var vid = try video.bindings.Video.load(allocator, input_path);
    defer vid.deinit();

    std.debug.print("Video duration: {d:.2}s\n", .{vid.duration()});

    // Extract audio
    var audio = try vid.extractAudio();
    defer audio.deinit();

    std.debug.print("Audio: {d} Hz, {d} channels\n", .{
        audio.sample_rate,
        audio.channels,
    });

    // Detect output format
    const ext = std.fs.path.extension(output_path);
    const format: video.AudioFormat = if (std.mem.eql(u8, ext, ".mp3"))
        .mp3
    else if (std.mem.eql(u8, ext, ".aac"))
        .aac
    else if (std.mem.eql(u8, ext, ".flac"))
        .flac
    else
        .wav;

    std.debug.print("Output format: {s}\n", .{@tagName(format)});

    // Save audio
    try audio.save(output_path);

    std.debug.print("Saved to: {s}\n", .{output_path});
    std.debug.print("Done!\n", .{});
}
