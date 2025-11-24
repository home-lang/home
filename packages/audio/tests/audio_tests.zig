// Home Audio Library - Comprehensive Test Suite
// Uses zig-test-framework for structured testing

const std = @import("std");
const ztf = @import("zig-test-framework");
const audio = @import("audio");

pub fn main() !void {
    // Use page allocator to avoid leak detection issues with the test framework
    // (the framework doesn't clean up all its internal state)
    const allocator = std.heap.page_allocator;

    // Core Types Tests
    try ztf.describe(allocator, "AudioFormat", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should detect format from extension", testFromExtension);
            try ztf.it(alloc, "should return correct MIME types", testMimeType);
            try ztf.it(alloc, "should identify lossless formats", testLossless);
        }

        fn testFromExtension(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".wav")).toBe(audio.AudioFormat.wav);
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".mp3")).toBe(audio.AudioFormat.mp3);
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".flac")).toBe(audio.AudioFormat.flac);
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".ogg")).toBe(audio.AudioFormat.ogg);
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".m4a")).toBe(audio.AudioFormat.m4a);
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".opus")).toBe(audio.AudioFormat.opus);
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".wma")).toBe(audio.AudioFormat.wma);
            try ztf.expect(alloc, audio.AudioFormat.fromExtension(".unknown")).toBe(audio.AudioFormat.unknown);
        }

        fn testMimeType(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.AudioFormat.wav.mimeType()).toBe("audio/wav");
            try ztf.expect(alloc, audio.AudioFormat.mp3.mimeType()).toBe("audio/mpeg");
            try ztf.expect(alloc, audio.AudioFormat.flac.mimeType()).toBe("audio/flac");
            try ztf.expect(alloc, audio.AudioFormat.opus.mimeType()).toBe("audio/opus");
        }

        fn testLossless(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.AudioFormat.wav.isLossless()).toBeTruthy();
            try ztf.expect(alloc, audio.AudioFormat.flac.isLossless()).toBeTruthy();
            try ztf.expect(alloc, audio.AudioFormat.aiff.isLossless()).toBeTruthy();
            try ztf.expect(alloc, audio.AudioFormat.mp3.isLossless()).toBeFalsy();
            try ztf.expect(alloc, audio.AudioFormat.aac.isLossless()).toBeFalsy();
        }
    }.testSuite);

    // Sample Format Tests
    try ztf.describe(allocator, "SampleFormat", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should return correct bytes per sample", testBytesPerSample);
            try ztf.it(alloc, "should identify float formats", testIsFloat);
            try ztf.it(alloc, "should identify big-endian formats", testIsBigEndian);
        }

        fn testBytesPerSample(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.SampleFormat.u8.bytesPerSample()).toBe(@as(u8, 1));
            try ztf.expect(alloc, audio.SampleFormat.s16le.bytesPerSample()).toBe(@as(u8, 2));
            try ztf.expect(alloc, audio.SampleFormat.s24le.bytesPerSample()).toBe(@as(u8, 3));
            try ztf.expect(alloc, audio.SampleFormat.s32le.bytesPerSample()).toBe(@as(u8, 4));
            try ztf.expect(alloc, audio.SampleFormat.f32le.bytesPerSample()).toBe(@as(u8, 4));
            try ztf.expect(alloc, audio.SampleFormat.f64le.bytesPerSample()).toBe(@as(u8, 8));
        }

        fn testIsFloat(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.SampleFormat.f32le.isFloat()).toBeTruthy();
            try ztf.expect(alloc, audio.SampleFormat.f64le.isFloat()).toBeTruthy();
            try ztf.expect(alloc, audio.SampleFormat.s16le.isFloat()).toBeFalsy();
            try ztf.expect(alloc, audio.SampleFormat.s32le.isFloat()).toBeFalsy();
        }

        fn testIsBigEndian(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.SampleFormat.s16be.isBigEndian()).toBeTruthy();
            try ztf.expect(alloc, audio.SampleFormat.s24be.isBigEndian()).toBeTruthy();
            try ztf.expect(alloc, audio.SampleFormat.s16le.isBigEndian()).toBeFalsy();
            try ztf.expect(alloc, audio.SampleFormat.s24le.isBigEndian()).toBeFalsy();
        }
    }.testSuite);

    // Channel Layout Tests
    try ztf.describe(allocator, "ChannelLayout", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should return correct channel count", testChannelCount);
            try ztf.it(alloc, "should create layout from channel count", testFromChannelCount);
        }

        fn testChannelCount(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.ChannelLayout.mono.channelCount()).toBe(@as(u8, 1));
            try ztf.expect(alloc, audio.ChannelLayout.stereo.channelCount()).toBe(@as(u8, 2));
            try ztf.expect(alloc, audio.ChannelLayout.surround_51.channelCount()).toBe(@as(u8, 6));
            try ztf.expect(alloc, audio.ChannelLayout.surround_71.channelCount()).toBe(@as(u8, 8));
        }

        fn testFromChannelCount(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.ChannelLayout.fromChannelCount(1)).toBe(audio.ChannelLayout.mono);
            try ztf.expect(alloc, audio.ChannelLayout.fromChannelCount(2)).toBe(audio.ChannelLayout.stereo);
            try ztf.expect(alloc, audio.ChannelLayout.fromChannelCount(6)).toBe(audio.ChannelLayout.surround_51);
        }
    }.testSuite);

    // Timestamp Tests
    try ztf.describe(allocator, "Timestamp", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should convert from/to seconds", testSecondsConversion);
            try ztf.it(alloc, "should convert from/to milliseconds", testMillisecondsConversion);
            try ztf.it(alloc, "should handle sample-based conversion", testSampleConversion);
        }

        fn testSecondsConversion(alloc: std.mem.Allocator) !void {
            const ts = audio.Timestamp.fromSeconds(1.5);
            const seconds = ts.toSeconds();
            try ztf.expect(alloc, seconds > 1.49 and seconds < 1.51).toBeTruthy();
        }

        fn testMillisecondsConversion(alloc: std.mem.Allocator) !void {
            const ts = audio.Timestamp.fromMilliseconds(1500);
            try ztf.expect(alloc, ts.toMilliseconds()).toBe(@as(i64, 1500));
        }

        fn testSampleConversion(alloc: std.mem.Allocator) !void {
            const ts = audio.Timestamp.fromSamples(44100, 44100);
            try ztf.expect(alloc, ts.toSeconds() > 0.99 and ts.toSeconds() < 1.01).toBeTruthy();
        }
    }.testSuite);

    // Duration Tests
    try ztf.describe(allocator, "Duration", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should convert to different units", testConversions);
            try ztf.it(alloc, "should calculate sample count", testSampleCount);
        }

        fn testConversions(alloc: std.mem.Allocator) !void {
            const d = audio.Duration.fromSeconds(60.0);
            try ztf.expect(alloc, d.toMilliseconds()).toBe(@as(u64, 60000));
            try ztf.expect(alloc, d.toMicroseconds()).toBe(@as(u64, 60000000));
        }

        fn testSampleCount(alloc: std.mem.Allocator) !void {
            const d = audio.Duration.fromSeconds(1.0);
            const samples = d.toSamples(44100);
            // Should be approximately 44100 samples
            try ztf.expect(alloc, samples > 44000 and samples < 44200).toBeTruthy();
        }
    }.testSuite);

    // WAV Format Tests
    try ztf.describe(allocator, "WAV Format", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should detect WAV format", testDetection);
            try ztf.it(alloc, "should parse WAV header", testHeaderParsing);
        }

        fn testDetection(alloc: std.mem.Allocator) !void {
            const wav_magic = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
            const format = audio.AudioFormat.fromMagicBytes(&wav_magic);
            try ztf.expect(alloc, format).toBe(audio.AudioFormat.wav);
        }

        fn testHeaderParsing(alloc: std.mem.Allocator) !void {
            // Minimal WAV header: RIFF + size + WAVE + fmt chunk + data chunk
            var wav_data: [44]u8 = undefined;
            @memcpy(wav_data[0..4], "RIFF");
            std.mem.writeInt(u32, wav_data[4..8], 36, .little);
            @memcpy(wav_data[8..12], "WAVE");
            @memcpy(wav_data[12..16], "fmt ");
            std.mem.writeInt(u32, wav_data[16..20], 16, .little); // fmt chunk size
            std.mem.writeInt(u16, wav_data[20..22], 1, .little); // PCM format
            std.mem.writeInt(u16, wav_data[22..24], 2, .little); // 2 channels
            std.mem.writeInt(u32, wav_data[24..28], 44100, .little); // sample rate
            std.mem.writeInt(u32, wav_data[28..32], 176400, .little); // byte rate
            std.mem.writeInt(u16, wav_data[32..34], 4, .little); // block align
            std.mem.writeInt(u16, wav_data[34..36], 16, .little); // bits per sample
            @memcpy(wav_data[36..40], "data");
            std.mem.writeInt(u32, wav_data[40..44], 0, .little); // data size

            const reader = audio.WavReader.fromMemory(alloc, &wav_data) catch {
                try ztf.expect(alloc, false).toBeTruthy(); // Should not fail
                return;
            };

            try ztf.expect(alloc, reader.header.channels).toBe(@as(u16, 2));
            try ztf.expect(alloc, reader.header.sample_rate).toBe(@as(u32, 44100));
            try ztf.expect(alloc, reader.header.bits_per_sample).toBe(@as(u16, 16));
        }
    }.testSuite);

    // Resampler Tests
    try ztf.describe(allocator, "Resampler", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should calculate correct output samples", testOutputSamples);
            try ztf.it(alloc, "should resample with linear interpolation", testLinearResample);
        }

        fn testOutputSamples(alloc: std.mem.Allocator) !void {
            var resampler = audio.Resampler.init(alloc, 44100, 48000, 2, .fast) catch {
                try ztf.expect(alloc, false).toBeTruthy();
                return;
            };
            defer resampler.deinit();

            // 1 second of 44100 Hz should become ~48000 samples at 48000 Hz
            const output = resampler.getOutputSamples(44100);
            try ztf.expect(alloc, output).toBe(@as(u64, 48000));
        }

        fn testLinearResample(alloc: std.mem.Allocator) !void {
            var resampler = audio.Resampler.init(alloc, 100, 200, 1, .fast) catch {
                try ztf.expect(alloc, false).toBeTruthy();
                return;
            };
            defer resampler.deinit();

            const input = [_]f32{ 0.0, 1.0, 0.0, -1.0 };
            var output: [8]f32 = undefined;

            resampler.resample(&input, &output);

            // First sample should be 0
            try ztf.expect(alloc, output[0] > -0.1 and output[0] < 0.1).toBeTruthy();
            // Middle should interpolate towards 1
            try ztf.expect(alloc, output[2] > 0.9 and output[2] < 1.1).toBeTruthy();
        }
    }.testSuite);

    // Mixer Tests
    try ztf.describe(allocator, "Mixer", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should initialize with correct settings", testInit);
            try ztf.it(alloc, "should apply pan law correctly", testPanLaw);
        }

        fn testInit(alloc: std.mem.Allocator) !void {
            var mixer = audio.Mixer.init(alloc, 2, 44100, 1024) catch {
                try ztf.expect(alloc, false).toBeTruthy();
                return;
            };
            defer mixer.deinit();

            try ztf.expect(alloc, mixer.channels).toBe(@as(u8, 2));
            try ztf.expect(alloc, mixer.sample_rate).toBe(@as(u32, 44100));
        }

        fn testPanLaw(alloc: std.mem.Allocator) !void {
            // Center pan should give equal gains
            const linear = audio.PanLaw.linear.getGains(0.0);
            try ztf.expect(alloc, linear.left > 0.49 and linear.left < 0.51).toBeTruthy();
            try ztf.expect(alloc, linear.right > 0.49 and linear.right < 0.51).toBeTruthy();

            // Full left
            const left = audio.PanLaw.linear.getGains(-1.0);
            try ztf.expect(alloc, left.left > 0.99 and left.left < 1.01).toBeTruthy();
            try ztf.expect(alloc, left.right > -0.01 and left.right < 0.01).toBeTruthy();
        }
    }.testSuite);

    // Effects Tests
    try ztf.describe(allocator, "Audio Effects", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should create biquad filter", testBiquadFilter);
            try ztf.it(alloc, "should convert dB to linear", testDbConversion);
            try ztf.it(alloc, "should initialize compressor", testCompressor);
        }

        fn testBiquadFilter(alloc: std.mem.Allocator) !void {
            var filter = audio.BiquadFilter.lowpass(44100, 1000, 0.707);
            const output = filter.process(1.0);
            try ztf.expect(alloc, output != 0).toBeTruthy();

            filter.reset();
            try ztf.expect(alloc, filter.x1).toBe(@as(f32, 0));
            try ztf.expect(alloc, filter.y1).toBe(@as(f32, 0));
        }

        fn testDbConversion(alloc: std.mem.Allocator) !void {
            // 0 dB = 1.0 linear
            const linear_0db = audio.processing.dbToLinear(0);
            try ztf.expect(alloc, linear_0db > 0.99 and linear_0db < 1.01).toBeTruthy();

            // -20 dB = 0.1 linear
            const linear_20db = audio.processing.dbToLinear(-20);
            try ztf.expect(alloc, linear_20db > 0.09 and linear_20db < 0.11).toBeTruthy();
        }

        fn testCompressor(alloc: std.mem.Allocator) !void {
            var comp = audio.Compressor.init(44100);
            comp.setThreshold(-10.0);
            try ztf.expect(alloc, comp.threshold).toBe(@as(f32, -10.0));

            comp.setRatio(8.0);
            try ztf.expect(alloc, comp.ratio).toBe(@as(f32, 8.0));
        }
    }.testSuite);

    // Format Capabilities Tests
    try ztf.describe(allocator, "Format Capabilities", struct {
        fn testSuite(alloc: std.mem.Allocator) !void {
            try ztf.it(alloc, "should report readable formats", testCanRead);
            try ztf.it(alloc, "should report writable formats", testCanWrite);
        }

        fn testCanRead(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.canRead(.wav)).toBeTruthy();
            try ztf.expect(alloc, audio.canRead(.mp3)).toBeTruthy();
            try ztf.expect(alloc, audio.canRead(.flac)).toBeTruthy();
            try ztf.expect(alloc, audio.canRead(.m4a)).toBeTruthy();
            try ztf.expect(alloc, audio.canRead(.opus)).toBeTruthy();
            try ztf.expect(alloc, audio.canRead(.wma)).toBeTruthy();
        }

        fn testCanWrite(alloc: std.mem.Allocator) !void {
            try ztf.expect(alloc, audio.canWrite(.wav)).toBeTruthy();
            try ztf.expect(alloc, audio.canWrite(.aiff)).toBeTruthy();
            try ztf.expect(alloc, audio.canWrite(.mp3)).toBeFalsy();
            try ztf.expect(alloc, audio.canWrite(.flac)).toBeFalsy();
        }
    }.testSuite);
}
