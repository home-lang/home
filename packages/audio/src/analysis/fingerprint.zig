// Home Audio Library - Audio Fingerprinting
// Basic audio fingerprinting for identification

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Fingerprint hash
pub const FingerprintHash = u32;

/// Single fingerprint frame
pub const FingerprintFrame = struct {
    hash: FingerprintHash,
    time_offset: f64, // In seconds
};

/// Audio fingerprint
pub const AudioFingerprint = struct {
    hashes: []FingerprintFrame,
    duration: f64,
    sample_rate: u32,

    pub fn deinit(self: *AudioFingerprint, allocator: Allocator) void {
        allocator.free(self.hashes);
    }
};

/// Fingerprint match result
pub const FingerprintMatch = struct {
    score: f32, // Match score (0-1)
    time_offset: f64, // Time offset in seconds
    matched_frames: usize,
    total_frames: usize,

    pub fn isMatch(self: FingerprintMatch, threshold: f32) bool {
        return self.score >= threshold;
    }
};

/// Frequency band for fingerprinting
const FrequencyBand = struct {
    low: f32,
    high: f32,
};

/// Audio fingerprinter
/// Uses a simplified version of the Shazam-style algorithm
pub const AudioFingerprinter = struct {
    allocator: Allocator,
    sample_rate: u32,

    // Analysis parameters
    fft_size: usize,
    hop_size: usize,
    num_bands: usize,

    // Frequency bands for analysis
    bands: []FrequencyBand,

    // Window function
    window: []f32,

    const Self = @This();

    pub const DEFAULT_FFT_SIZE = 2048;
    pub const DEFAULT_HOP_SIZE = 512;
    pub const DEFAULT_NUM_BANDS = 6;

    // Default frequency bands (logarithmic spacing)
    pub const DEFAULT_BANDS = [_]FrequencyBand{
        .{ .low = 30, .high = 60 },
        .{ .low = 60, .high = 120 },
        .{ .low = 120, .high = 250 },
        .{ .low = 250, .high = 500 },
        .{ .low = 500, .high = 1000 },
        .{ .low = 1000, .high = 2000 },
    };

    pub fn init(allocator: Allocator, sample_rate: u32) !Self {
        return initWithParams(allocator, sample_rate, DEFAULT_FFT_SIZE, DEFAULT_HOP_SIZE);
    }

    pub fn initWithParams(
        allocator: Allocator,
        sample_rate: u32,
        fft_size: usize,
        hop_size: usize,
    ) !Self {
        var fp = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .fft_size = fft_size,
            .hop_size = hop_size,
            .num_bands = DEFAULT_NUM_BANDS,
            .bands = try allocator.alloc(FrequencyBand, DEFAULT_NUM_BANDS),
            .window = try allocator.alloc(f32, fft_size),
        };

        // Copy default bands
        @memcpy(fp.bands, &DEFAULT_BANDS);

        // Initialize Hann window
        for (0..fft_size) |i| {
            fp.window[i] = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fft_size))));
        }

        return fp;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bands);
        self.allocator.free(self.window);
    }

    /// Generate fingerprint from audio samples
    pub fn generateFingerprint(self: *Self, samples: []const f32, channels: u8) !AudioFingerprint {
        // Mix to mono
        var mono: []f32 = undefined;
        var allocated_mono = false;

        if (channels == 1) {
            mono = @constCast(samples);
        } else {
            const num_frames = samples.len / channels;
            mono = try self.allocator.alloc(f32, num_frames);
            allocated_mono = true;

            for (0..num_frames) |i| {
                var sum: f32 = 0;
                for (0..channels) |ch| {
                    sum += samples[i * channels + ch];
                }
                mono[i] = sum / @as(f32, @floatFromInt(channels));
            }
        }
        defer if (allocated_mono) self.allocator.free(mono);

        // Calculate number of frames
        const num_frames = if (mono.len > self.fft_size)
            (mono.len - self.fft_size) / self.hop_size + 1
        else
            0;

        if (num_frames == 0) {
            return AudioFingerprint{
                .hashes = try self.allocator.alloc(FingerprintFrame, 0),
                .duration = @as(f64, @floatFromInt(samples.len / channels)) / @as(f64, @floatFromInt(self.sample_rate)),
                .sample_rate = self.sample_rate,
            };
        }

        var hashes = try self.allocator.alloc(FingerprintFrame, num_frames);
        const prev_band_energy = try self.allocator.alloc(f32, self.num_bands);
        defer self.allocator.free(prev_band_energy);
        @memset(prev_band_energy, 0);

        var frame_idx: usize = 0;
        var pos: usize = 0;
        while (pos + self.fft_size <= mono.len) : (pos += self.hop_size) {
            // Apply window
            var windowed = try self.allocator.alloc(f32, self.fft_size);
            defer self.allocator.free(windowed);

            for (0..self.fft_size) |i| {
                windowed[i] = mono[pos + i] * self.window[i];
            }

            // Calculate band energies (simplified - no actual FFT)
            const band_energy = try self.allocator.alloc(f32, self.num_bands);
            defer self.allocator.free(band_energy);

            self.calculateBandEnergies(windowed, band_energy);

            // Generate hash from energy differences
            const hash = self.generateHash(band_energy, prev_band_energy);

            hashes[frame_idx] = FingerprintFrame{
                .hash = hash,
                .time_offset = @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(self.sample_rate)),
            };

            @memcpy(prev_band_energy, band_energy);
            frame_idx += 1;

            if (frame_idx >= num_frames) break;
        }

        return AudioFingerprint{
            .hashes = hashes[0..frame_idx],
            .duration = @as(f64, @floatFromInt(samples.len / channels)) / @as(f64, @floatFromInt(self.sample_rate)),
            .sample_rate = self.sample_rate,
        };
    }

    /// Calculate energy in each frequency band
    fn calculateBandEnergies(self: *Self, samples: []const f32, energies: []f32) void {
        // Simplified: use time-domain filtering approximation
        // Real implementation would use FFT

        const nyquist = @as(f32, @floatFromInt(self.sample_rate)) / 2.0;

        for (0..self.num_bands) |band| {
            var energy: f32 = 0;

            // Simple bandpass approximation using sample differences
            const low_ratio = self.bands[band].low / nyquist;
            const high_ratio = self.bands[band].high / nyquist;
            const center_freq = (self.bands[band].low + self.bands[band].high) / 2.0;
            const period = @as(usize, @intFromFloat(@as(f32, @floatFromInt(self.sample_rate)) / center_freq));

            if (period > 0 and period < samples.len) {
                for (period..samples.len) |i| {
                    // Bandpass approximation
                    const diff = samples[i] - samples[i - period];
                    energy += diff * diff;
                }
            } else {
                // Fallback: use raw energy
                for (samples) |s| {
                    energy += s * s;
                }
            }

            // Weight by band width
            energies[band] = energy * (high_ratio - low_ratio);
        }
    }

    /// Generate hash from band energies
    fn generateHash(self: *Self, current: []const f32, previous: []const f32) FingerprintHash {
        var hash: FingerprintHash = 0;
        var bit: u5 = 0;

        // Compare adjacent bands
        for (0..self.num_bands - 1) |band| {
            if (current[band] > current[band + 1]) {
                hash |= (@as(FingerprintHash, 1) << bit);
            }
            bit +%= 1;
        }

        // Compare with previous frame
        for (0..self.num_bands) |band| {
            if (current[band] > previous[band]) {
                hash |= (@as(FingerprintHash, 1) << bit);
            }
            bit +%= 1;
            if (bit >= 32) break;
        }

        // Add energy ratio bits
        var total_energy: f32 = 0;
        for (current) |e| {
            total_energy += e;
        }

        for (0..self.num_bands) |band| {
            if (bit >= 32) break;
            if (total_energy > 0 and current[band] / total_energy > 1.0 / @as(f32, @floatFromInt(self.num_bands))) {
                hash |= (@as(FingerprintHash, 1) << bit);
            }
            bit +%= 1;
        }

        return hash;
    }

    /// Compare two fingerprints
    pub fn compareFingerprints(self: *Self, fp1: *const AudioFingerprint, fp2: *const AudioFingerprint) FingerprintMatch {
        _ = self;

        if (fp1.hashes.len == 0 or fp2.hashes.len == 0) {
            return FingerprintMatch{
                .score = 0,
                .time_offset = 0,
                .matched_frames = 0,
                .total_frames = @max(fp1.hashes.len, fp2.hashes.len),
            };
        }

        // Try different time offsets
        var best_score: f32 = 0;
        var best_offset: f64 = 0;
        var best_matched: usize = 0;

        const max_offset = @as(i32, @intCast(@min(fp1.hashes.len, fp2.hashes.len)));

        var offset: i32 = -max_offset + 1;
        while (offset < max_offset) : (offset += 1) {
            var matched: usize = 0;
            var compared: usize = 0;

            const start1: usize = if (offset < 0) @intCast(-offset) else 0;
            const start2: usize = if (offset > 0) @intCast(offset) else 0;
            const end1 = fp1.hashes.len;
            const end2 = fp2.hashes.len;

            var idx1 = start1;
            var idx2 = start2;
            while (idx1 < end1 and idx2 < end2) : ({
                idx1 += 1;
                idx2 += 1;
            }) {
                // Count matching bits
                const xor = fp1.hashes[idx1].hash ^ fp2.hashes[idx2].hash;
                const matching_bits = 32 - @popCount(xor);
                if (matching_bits >= 24) { // High similarity threshold
                    matched += 1;
                }
                compared += 1;
            }

            if (compared > 0) {
                const score = @as(f32, @floatFromInt(matched)) / @as(f32, @floatFromInt(compared));
                if (score > best_score) {
                    best_score = score;
                    best_offset = if (offset >= 0)
                        fp2.hashes[@intCast(offset)].time_offset
                    else
                        -fp1.hashes[@intCast(-offset)].time_offset;
                    best_matched = matched;
                }
            }
        }

        return FingerprintMatch{
            .score = best_score,
            .time_offset = best_offset,
            .matched_frames = best_matched,
            .total_frames = @max(fp1.hashes.len, fp2.hashes.len),
        };
    }

    /// Generate compact hash for quick lookup
    pub fn generateCompactHash(self: *Self, fingerprint: *const AudioFingerprint) u64 {
        _ = self;

        if (fingerprint.hashes.len == 0) return 0;

        var hash: u64 = 0;
        const sample_count = @min(8, fingerprint.hashes.len);
        const step = fingerprint.hashes.len / sample_count;

        for (0..sample_count) |i| {
            const idx = i * step;
            hash ^= @as(u64, fingerprint.hashes[idx].hash) << @as(u6, @intCast((i * 8) % 64));
        }

        return hash;
    }
};

/// Fingerprint database for matching
pub const FingerprintDatabase = struct {
    allocator: Allocator,

    // Store: compact hash -> list of (fingerprint_id, full fingerprint)
    entries: std.AutoHashMap(u64, std.ArrayList(DatabaseEntry)),

    const Self = @This();

    const DatabaseEntry = struct {
        id: u64,
        name: []const u8,
        fingerprint: AudioFingerprint,
    };

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .entries = std.AutoHashMap(u64, std.ArrayList(DatabaseEntry)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |*e| {
                self.allocator.free(e.name);
                e.fingerprint.deinit(self.allocator);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Add fingerprint to database
    pub fn add(self: *Self, fingerprinter: *AudioFingerprinter, id: u64, name: []const u8, fingerprint: AudioFingerprint) !void {
        const compact_hash = fingerprinter.generateCompactHash(&fingerprint);

        const gop = try self.entries.getOrPut(compact_hash);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        const name_copy = try self.allocator.dupe(u8, name);
        try gop.value_ptr.append(self.allocator, DatabaseEntry{
            .id = id,
            .name = name_copy,
            .fingerprint = fingerprint,
        });
    }

    /// Search for matching fingerprint
    pub fn search(
        self: *Self,
        fingerprinter: *AudioFingerprinter,
        query: *const AudioFingerprint,
        threshold: f32,
    ) ?struct { id: u64, name: []const u8, match: FingerprintMatch } {
        const compact_hash = fingerprinter.generateCompactHash(query);

        // Check exact hash match first
        if (self.entries.get(compact_hash)) |bucket| {
            for (bucket.items) |*entry| {
                const match = fingerprinter.compareFingerprints(query, &entry.fingerprint);
                if (match.isMatch(threshold)) {
                    return .{ .id = entry.id, .name = entry.name, .match = match };
                }
            }
        }

        // Try similar hashes (flip bits)
        for (0..8) |bit| {
            const similar_hash = compact_hash ^ (@as(u64, 1) << @as(u6, @intCast(bit)));
            if (self.entries.get(similar_hash)) |bucket| {
                for (bucket.items) |*entry| {
                    const match = fingerprinter.compareFingerprints(query, &entry.fingerprint);
                    if (match.isMatch(threshold)) {
                        return .{ .id = entry.id, .name = entry.name, .match = match };
                    }
                }
            }
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AudioFingerprinter init" {
    const allocator = std.testing.allocator;

    var fp = try AudioFingerprinter.init(allocator, 44100);
    defer fp.deinit();
}

test "AudioFingerprinter generate" {
    const allocator = std.testing.allocator;

    var fp = try AudioFingerprinter.init(allocator, 44100);
    defer fp.deinit();

    // Create simple test audio
    var samples: [8820]f32 = undefined; // 0.2 second
    for (0..8820) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        samples[i] = @sin(t * 440 * 2 * math.pi);
    }

    var fingerprint = try fp.generateFingerprint(&samples, 1);
    defer fingerprint.deinit(allocator);

    try std.testing.expect(fingerprint.hashes.len > 0);
}

test "AudioFingerprinter compare" {
    const allocator = std.testing.allocator;

    var fp = try AudioFingerprinter.init(allocator, 44100);
    defer fp.deinit();

    // Create two identical audio buffers
    var samples1: [8820]f32 = undefined;
    var samples2: [8820]f32 = undefined;
    for (0..8820) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        const val = @sin(t * 440 * 2 * math.pi);
        samples1[i] = val;
        samples2[i] = val;
    }

    var fp1 = try fp.generateFingerprint(&samples1, 1);
    defer fp1.deinit(allocator);
    var fp2 = try fp.generateFingerprint(&samples2, 1);
    defer fp2.deinit(allocator);

    const match = fp.compareFingerprints(&fp1, &fp2);
    try std.testing.expect(match.score > 0.5);
}

test "FingerprintDatabase init" {
    const allocator = std.testing.allocator;

    var db = FingerprintDatabase.init(allocator);
    defer db.deinit();
}
