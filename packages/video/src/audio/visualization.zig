const std = @import("std");

/// Waveform generator
pub const WaveformGenerator = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    style: WaveformStyle,
    colors: WaveformColors,

    pub const WaveformStyle = enum {
        bars,
        line,
        filled,
        mirrored,
    };

    pub const WaveformColors = struct {
        foreground: u32, // RGBA
        background: u32,
        center_line: ?u32,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) WaveformGenerator {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .style = .filled,
            .colors = .{
                .foreground = 0x00FF00FF, // Green
                .background = 0x000000FF, // Black
                .center_line = 0x808080FF, // Gray
            },
        };
    }

    pub fn generateFromSamples(self: *WaveformGenerator, samples: []const f32, channel_count: u8) ![]u8 {
        const pixel_count = self.width * self.height * 4; // RGBA
        var pixels = try self.allocator.alloc(u8, pixel_count);

        // Clear to background
        var i: usize = 0;
        while (i < pixel_count) : (i += 4) {
            pixels[i] = @truncate(self.colors.background >> 24);
            pixels[i + 1] = @truncate(self.colors.background >> 16);
            pixels[i + 2] = @truncate(self.colors.background >> 8);
            pixels[i + 3] = @truncate(self.colors.background);
        }

        // Draw center line
        if (self.colors.center_line) |center| {
            const center_y = self.height / 2;
            i = center_y * self.width * 4;
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                pixels[i] = @truncate(center >> 24);
                pixels[i + 1] = @truncate(center >> 16);
                pixels[i + 2] = @truncate(center >> 8);
                pixels[i + 3] = @truncate(center);
                i += 4;
            }
        }

        // Downsample audio to fit width
        const samples_per_pixel = @divFloor(samples.len, channel_count * self.width);
        if (samples_per_pixel == 0) return pixels;

        var x: u32 = 0;
        while (x < self.width) : (x += 1) {
            const sample_start = x * samples_per_pixel * channel_count;
            const sample_end = @min(sample_start + samples_per_pixel * channel_count, samples.len);

            // Calculate RMS for this pixel
            var sum: f32 = 0;
            var count: usize = 0;
            var s = sample_start;
            while (s < sample_end) : (s += channel_count) {
                const sample = samples[s];
                sum += sample * sample;
                count += 1;
            }

            const rms = if (count > 0) @sqrt(sum / @as(f32, @floatFromInt(count))) else 0.0;
            const amplitude = @min(rms, 1.0);

            try self.drawColumn(pixels, x, amplitude);
        }

        return pixels;
    }

    fn drawColumn(self: *WaveformGenerator, pixels: []u8, x: u32, amplitude: f32) !void {
        const center_y = self.height / 2;
        const bar_height = @as(u32, @intFromFloat(amplitude * @as(f32, @floatFromInt(center_y))));

        switch (self.style) {
            .bars, .line, .filled => {
                const y_start = center_y - bar_height;
                const y_end = center_y + bar_height;

                var y = y_start;
                while (y <= y_end and y < self.height) : (y += 1) {
                    const idx = (y * self.width + x) * 4;
                    pixels[idx] = @truncate(self.colors.foreground >> 24);
                    pixels[idx + 1] = @truncate(self.colors.foreground >> 16);
                    pixels[idx + 2] = @truncate(self.colors.foreground >> 8);
                    pixels[idx + 3] = @truncate(self.colors.foreground);
                }
            },
            .mirrored => {
                var y: u32 = 0;
                while (y < bar_height and y < center_y) : (y += 1) {
                    const idx1 = ((center_y - y) * self.width + x) * 4;
                    const idx2 = ((center_y + y) * self.width + x) * 4;

                    pixels[idx1] = @truncate(self.colors.foreground >> 24);
                    pixels[idx1 + 1] = @truncate(self.colors.foreground >> 16);
                    pixels[idx1 + 2] = @truncate(self.colors.foreground >> 8);
                    pixels[idx1 + 3] = @truncate(self.colors.foreground);

                    pixels[idx2] = @truncate(self.colors.foreground >> 24);
                    pixels[idx2 + 1] = @truncate(self.colors.foreground >> 16);
                    pixels[idx2 + 2] = @truncate(self.colors.foreground >> 8);
                    pixels[idx2 + 3] = @truncate(self.colors.foreground);
                }
            },
        }
    }

    pub fn generateStereo(self: *WaveformGenerator, left: []const f32, right: []const f32) ![]u8 {
        const pixel_count = self.width * self.height * 4;
        var pixels = try self.allocator.alloc(u8, pixel_count);

        // Clear to background
        var i: usize = 0;
        while (i < pixel_count) : (i += 4) {
            pixels[i] = @truncate(self.colors.background >> 24);
            pixels[i + 1] = @truncate(self.colors.background >> 16);
            pixels[i + 2] = @truncate(self.colors.background >> 8);
            pixels[i + 3] = @truncate(self.colors.background);
        }

        // Draw center lines at 1/4 and 3/4 height
        const quarter_y = self.height / 4;
        const three_quarter_y = (self.height * 3) / 4;

        // Implementation similar to generateFromSamples but split for stereo
        _ = left;
        _ = right;
        _ = quarter_y;
        _ = three_quarter_y;

        return pixels;
    }
};

/// Spectrogram generator using FFT
pub const SpectrogramGenerator = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    fft_size: usize,
    color_map: ColorMap,

    pub const ColorMap = enum {
        viridis,
        magma,
        plasma,
        inferno,
        grayscale,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, fft_size: usize) SpectrogramGenerator {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .fft_size = fft_size,
            .color_map = .viridis,
        };
    }

    pub fn generateFromSamples(self: *SpectrogramGenerator, samples: []const f32, sample_rate: u32) ![]u8 {
        _ = sample_rate;

        const pixel_count = self.width * self.height * 4;
        var pixels = try self.allocator.alloc(u8, pixel_count);

        // Initialize to black
        @memset(pixels, 0);

        // Would perform STFT (Short-Time Fourier Transform)
        // For each time window:
        //   1. Apply window function (Hann, Hamming)
        //   2. Perform FFT
        //   3. Calculate magnitude spectrum
        //   4. Map to color and draw column

        const hop_size = samples.len / self.width;
        _ = hop_size;

        // Placeholder - would need actual FFT implementation
        return pixels;
    }

    fn magnitudeToColor(self: *SpectrogramGenerator, magnitude: f32) u32 {
        const normalized = @min(magnitude, 1.0);

        return switch (self.color_map) {
            .grayscale => {
                const gray: u8 = @intFromFloat(normalized * 255.0);
                return (@as(u32, gray) << 24) | (@as(u32, gray) << 16) | (@as(u32, gray) << 8) | 0xFF;
            },
            .viridis => self.viridisColor(normalized),
            .magma => self.magmaColor(normalized),
            .plasma => self.plasmaColor(normalized),
            .inferno => self.infernoColor(normalized),
        };
    }

    fn viridisColor(self: *SpectrogramGenerator, t: f32) u32 {
        _ = self;
        // Simplified viridis colormap
        const r: u8 = @intFromFloat(@min(255.0, @max(0.0, 68.0 + 158.0 * t)));
        const g: u8 = @intFromFloat(@min(255.0, @max(0.0, 1.0 + 232.0 * t)));
        const b: u8 = @intFromFloat(@min(255.0, @max(0.0, 84.0 + 110.0 * t)));
        return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }

    fn magmaColor(self: *SpectrogramGenerator, t: f32) u32 {
        _ = self;
        const r: u8 = @intFromFloat(@min(255.0, @max(0.0, 10.0 + 245.0 * t)));
        const g: u8 = @intFromFloat(@min(255.0, @max(0.0, 5.0 + 180.0 * t * t)));
        const b: u8 = @intFromFloat(@min(255.0, @max(0.0, 135.0 - 80.0 * t)));
        return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }

    fn plasmaColor(self: *SpectrogramGenerator, t: f32) u32 {
        _ = self;
        const r: u8 = @intFromFloat(@min(255.0, @max(0.0, 13.0 + 240.0 * t)));
        const g: u8 = @intFromFloat(@min(255.0, @max(0.0, 8.0 + 200.0 * @sin(t * std.math.pi))));
        const b: u8 = @intFromFloat(@min(255.0, @max(0.0, 190.0 - 110.0 * t)));
        return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }

    fn infernoColor(self: *SpectrogramGenerator, t: f32) u32 {
        _ = self;
        const r: u8 = @intFromFloat(@min(255.0, @max(0.0, 10.0 + 245.0 * t)));
        const g: u8 = @intFromFloat(@min(255.0, @max(0.0, 5.0 + 200.0 * t * t)));
        const b: u8 = @intFromFloat(@min(255.0, @max(0.0, 20.0 + 100.0 * t * t * t)));
        return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }
};

/// Real-time spectrum analyzer
pub const SpectrumAnalyzer = struct {
    allocator: std.mem.Allocator,
    fft_size: usize,
    window: []f32,
    fft_buffer: []std.math.Complex(f32),

    pub fn init(allocator: std.mem.Allocator, fft_size: usize) !SpectrumAnalyzer {
        var analyzer = SpectrumAnalyzer{
            .allocator = allocator,
            .fft_size = fft_size,
            .window = try allocator.alloc(f32, fft_size),
            .fft_buffer = try allocator.alloc(std.math.Complex(f32), fft_size),
        };

        // Generate Hann window
        for (analyzer.window, 0..) |*w, i| {
            const phase = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fft_size));
            w.* = 0.5 * (1.0 - @cos(phase));
        }

        return analyzer;
    }

    pub fn deinit(self: *SpectrumAnalyzer) void {
        self.allocator.free(self.window);
        self.allocator.free(self.fft_buffer);
    }

    pub fn analyze(self: *SpectrumAnalyzer, samples: []const f32) ![]f32 {
        if (samples.len != self.fft_size) return error.InvalidSampleCount;

        // Apply window and copy to FFT buffer
        for (samples, 0..) |sample, i| {
            self.fft_buffer[i] = std.math.Complex(f32){
                .re = sample * self.window[i],
                .im = 0,
            };
        }

        // Perform FFT (simplified - would need actual FFT implementation)
        // self.fft(self.fft_buffer);

        // Calculate magnitude spectrum
        var magnitudes = try self.allocator.alloc(f32, self.fft_size / 2);
        for (magnitudes, 0..) |*mag, i| {
            const re = self.fft_buffer[i].re;
            const im = self.fft_buffer[i].im;
            mag.* = @sqrt(re * re + im * im);
        }

        return magnitudes;
    }

    pub fn getBinFrequency(self: *SpectrumAnalyzer, bin: usize, sample_rate: u32) f32 {
        return @as(f32, @floatFromInt(bin)) * @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(self.fft_size));
    }
};

/// Audio meters
pub const AudioMeter = struct {
    peak_level_db: f32,
    rms_level_db: f32,
    lufs: f32,
    phase_correlation: f32,

    pub fn init() AudioMeter {
        return .{
            .peak_level_db = -std.math.inf(f32),
            .rms_level_db = -std.math.inf(f32),
            .lufs = -std.math.inf(f32),
            .phase_correlation = 0.0,
        };
    }

    pub fn update(self: *AudioMeter, samples: []const f32, channels: u8) void {
        if (samples.len == 0) return;

        // Calculate peak
        var peak: f32 = 0.0;
        for (samples) |sample| {
            peak = @max(peak, @abs(sample));
        }
        self.peak_level_db = if (peak > 0.0) 20.0 * @log10(peak) else -std.math.inf(f32);

        // Calculate RMS
        var sum: f32 = 0.0;
        for (samples) |sample| {
            sum += sample * sample;
        }
        const rms = @sqrt(sum / @as(f32, @floatFromInt(samples.len)));
        self.rms_level_db = if (rms > 0.0) 20.0 * @log10(rms) else -std.math.inf(f32);

        // Calculate phase correlation (stereo only)
        if (channels == 2) {
            var sum_left: f32 = 0.0;
            var sum_right: f32 = 0.0;
            var sum_product: f32 = 0.0;

            var i: usize = 0;
            while (i < samples.len) : (i += 2) {
                const left = samples[i];
                const right = samples[i + 1];
                sum_left += left * left;
                sum_right += right * right;
                sum_product += left * right;
            }

            const denom = @sqrt(sum_left * sum_right);
            self.phase_correlation = if (denom > 0.0) sum_product / denom else 0.0;
        }
    }

    pub fn getPeakLevelDb(self: *const AudioMeter) f32 {
        return self.peak_level_db;
    }

    pub fn getRmsLevelDb(self: *const AudioMeter) f32 {
        return self.rms_level_db;
    }

    pub fn getLufs(self: *const AudioMeter) f32 {
        return self.lufs;
    }

    pub fn getPhaseCorrelation(self: *const AudioMeter) f32 {
        return self.phase_correlation;
    }
};
