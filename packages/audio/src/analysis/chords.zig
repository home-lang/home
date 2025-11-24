// Home Audio Library - Chord and Key Detection
// Music theory analysis from audio signals

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Musical note (pitch class)
pub const PitchClass = enum(u8) {
    C = 0,
    Cs = 1, // C# / Db
    D = 2,
    Ds = 3, // D# / Eb
    E = 4,
    F = 5,
    Fs = 6, // F# / Gb
    G = 7,
    Gs = 8, // G# / Ab
    A = 9,
    As = 10, // A# / Bb
    B = 11,

    pub fn toString(self: PitchClass) []const u8 {
        return switch (self) {
            .C => "C",
            .Cs => "C#",
            .D => "D",
            .Ds => "D#",
            .E => "E",
            .F => "F",
            .Fs => "F#",
            .G => "G",
            .Gs => "G#",
            .A => "A",
            .As => "A#",
            .B => "B",
        };
    }
};

/// Chord quality/type
pub const ChordQuality = enum {
    major,
    minor,
    diminished,
    augmented,
    major7,
    minor7,
    dominant7,
    suspended2,
    suspended4,

    pub fn getIntervals(self: ChordQuality) []const u8 {
        return switch (self) {
            .major => &[_]u8{ 0, 4, 7 }, // Root, M3, P5
            .minor => &[_]u8{ 0, 3, 7 }, // Root, m3, P5
            .diminished => &[_]u8{ 0, 3, 6 }, // Root, m3, d5
            .augmented => &[_]u8{ 0, 4, 8 }, // Root, M3, A5
            .major7 => &[_]u8{ 0, 4, 7, 11 }, // Root, M3, P5, M7
            .minor7 => &[_]u8{ 0, 3, 7, 10 }, // Root, m3, P5, m7
            .dominant7 => &[_]u8{ 0, 4, 7, 10 }, // Root, M3, P5, m7
            .suspended2 => &[_]u8{ 0, 2, 7 }, // Root, M2, P5
            .suspended4 => &[_]u8{ 0, 5, 7 }, // Root, P4, P5
        };
    }

    pub fn toString(self: ChordQuality) []const u8 {
        return switch (self) {
            .major => "",
            .minor => "m",
            .diminished => "dim",
            .augmented => "aug",
            .major7 => "maj7",
            .minor7 => "m7",
            .dominant7 => "7",
            .suspended2 => "sus2",
            .suspended4 => "sus4",
        };
    }
};

/// Detected chord
pub const Chord = struct {
    root: PitchClass,
    quality: ChordQuality,
    confidence: f32, // 0.0 - 1.0

    pub fn toString(self: Chord, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ self.root.toString(), self.quality.toString() });
    }
};

/// Musical key (major or minor)
pub const Key = struct {
    tonic: PitchClass,
    is_major: bool,
    confidence: f32,

    pub fn toString(self: Key, buf: []u8) ![]const u8 {
        const mode = if (self.is_major) "major" else "minor";
        return std.fmt.bufPrint(buf, "{s} {s}", .{ self.tonic.toString(), mode });
    }
};

/// Chromagram (12-bin pitch class profile)
pub const Chromagram = struct {
    bins: [12]f32, // Energy per pitch class

    const Self = @This();

    pub fn init() Self {
        return Self{ .bins = [_]f32{0} ** 12 };
    }

    pub fn clear(self: *Self) void {
        @memset(&self.bins, 0);
    }

    pub fn normalize(self: *Self) void {
        var sum: f32 = 0;
        for (self.bins) |b| {
            sum += b;
        }
        if (sum > 0) {
            for (&self.bins) |*b| {
                b.* /= sum;
            }
        }
    }

    /// Compute correlation with a chord template
    pub fn correlate(self: *Self, template: []const u8) f32 {
        var score: f32 = 0;
        for (template) |pitch| {
            score += self.bins[pitch];
        }
        return score / @as(f32, @floatFromInt(template.len));
    }
};

/// Chord detector
pub const ChordDetector = struct {
    allocator: Allocator,
    sample_rate: u32,
    fft_size: usize,

    // Current chromagram
    chroma: Chromagram,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32) Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .fft_size = 4096,
            .chroma = Chromagram.init(),
        };
    }

    /// Update chromagram from audio samples
    pub fn processAudio(self: *Self, samples: []const f32) !void {
        self.chroma.clear();

        // Simplified: Analyze frequency content and map to pitch classes
        // In a real implementation, this would use FFT
        for (samples, 0..) |sample, i| {
            // Simple frequency estimation via zero-crossing
            if (i > 0 and samples[i - 1] < 0 and sample >= 0) {
                // Estimate frequency from sample position
                const freq = @as(f32, @floatFromInt(self.sample_rate)) / @as(f32, @floatFromInt(i * 2));

                // Map frequency to pitch class (simplified)
                const midi_note = 12.0 * @log2(freq / 440.0) + 69.0;
                const pitch_class = @as(usize, @intFromFloat(@mod(midi_note, 12.0)));

                if (pitch_class < 12) {
                    self.chroma.bins[pitch_class] += @abs(sample);
                }
            }
        }

        self.chroma.normalize();
    }

    /// Detect the most likely chord
    pub fn detectChord(self: *Self) Chord {
        var best_chord = Chord{
            .root = .C,
            .quality = .major,
            .confidence = 0,
        };

        // Try all root notes and chord qualities
        var root_idx: u8 = 0;
        while (root_idx < 12) : (root_idx += 1) {
            const qualities = [_]ChordQuality{
                .major,
                .minor,
                .diminished,
                .augmented,
                .major7,
                .minor7,
                .dominant7,
                .suspended2,
                .suspended4,
            };

            for (qualities) |quality| {
                // Create chord template
                const intervals = quality.getIntervals();
                var template: [4]u8 = undefined;
                for (intervals, 0..) |interval, i| {
                    template[i] = @intCast((root_idx + interval) % 12);
                }

                // Compute correlation
                const score = self.chroma.correlate(template[0..intervals.len]);

                if (score > best_chord.confidence) {
                    best_chord.root = @enumFromInt(root_idx);
                    best_chord.quality = quality;
                    best_chord.confidence = score;
                }
            }
        }

        return best_chord;
    }
};

/// Key detector using Krumhansl-Schmuckler algorithm
pub const KeyDetector = struct {
    allocator: Allocator,

    // Krumhansl-Kessler key profiles
    major_profile: [12]f32,
    minor_profile: [12]f32,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        // Krumhansl-Kessler major key profile
        const major = [12]f32{
            6.35, // Tonic
            2.23, // Minor 2nd
            3.48, // Major 2nd
            2.33, // Minor 3rd
            4.38, // Major 3rd
            4.09, // Perfect 4th
            2.52, // Tritone
            5.19, // Perfect 5th
            2.39, // Minor 6th
            3.66, // Major 6th
            2.29, // Minor 7th
            2.88, // Major 7th
        };

        // Krumhansl-Kessler minor key profile
        const minor = [12]f32{
            6.33, // Tonic
            2.68, // Minor 2nd
            3.52, // Major 2nd
            5.38, // Minor 3rd
            2.60, // Major 3rd
            3.53, // Perfect 4th
            2.54, // Tritone
            4.75, // Perfect 5th
            3.98, // Minor 6th
            2.69, // Major 6th
            3.34, // Minor 7th
            3.17, // Major 7th
        };

        return Self{
            .allocator = allocator,
            .major_profile = major,
            .minor_profile = minor,
        };
    }

    /// Detect key from chromagram
    pub fn detectKey(self: *Self, chroma: *Chromagram) Key {
        var best_key = Key{
            .tonic = .C,
            .is_major = true,
            .confidence = 0,
        };

        // Try all 24 keys (12 major + 12 minor)
        var root_idx: u8 = 0;
        while (root_idx < 12) : (root_idx += 1) {
            // Try major
            var major_score: f32 = 0;
            for (0..12) |i| {
                const chroma_idx = (i + root_idx) % 12;
                major_score += chroma.bins[chroma_idx] * self.major_profile[i];
            }

            if (major_score > best_key.confidence) {
                best_key.tonic = @enumFromInt(root_idx);
                best_key.is_major = true;
                best_key.confidence = major_score;
            }

            // Try minor
            var minor_score: f32 = 0;
            for (0..12) |i| {
                const chroma_idx = (i + root_idx) % 12;
                minor_score += chroma.bins[chroma_idx] * self.minor_profile[i];
            }

            if (minor_score > best_key.confidence) {
                best_key.tonic = @enumFromInt(root_idx);
                best_key.is_major = false;
                best_key.confidence = minor_score;
            }
        }

        return best_key;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PitchClass toString" {
    try std.testing.expectEqualStrings("C", PitchClass.C.toString());
    try std.testing.expectEqualStrings("F#", PitchClass.Fs.toString());
}

test "ChordQuality intervals" {
    const major_intervals = ChordQuality.major.getIntervals();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 4, 7 }, major_intervals);

    const minor_intervals = ChordQuality.minor.getIntervals();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 3, 7 }, minor_intervals);
}

test "Chromagram correlate" {
    var chroma = Chromagram.init();
    chroma.bins[0] = 1.0; // C
    chroma.bins[4] = 0.8; // E
    chroma.bins[7] = 0.9; // G

    const c_major_template = [_]u8{ 0, 4, 7 };
    const score = chroma.correlate(&c_major_template);

    try std.testing.expect(score > 0.8);
}

test "ChordDetector init" {
    const allocator = std.testing.allocator;

    const detector = ChordDetector.init(allocator, 44100);
    try std.testing.expectEqual(@as(u32, 44100), detector.sample_rate);
}

test "KeyDetector init" {
    const allocator = std.testing.allocator;

    const detector = KeyDetector.init(allocator);
    try std.testing.expectEqual(@as(f32, 6.35), detector.major_profile[0]);
}

test "Chord toString" {
    const chord = Chord{
        .root = .C,
        .quality = .major,
        .confidence = 0.9,
    };

    var buf: [32]u8 = undefined;
    const str = try chord.toString(&buf);
    try std.testing.expectEqualStrings("C", str);
}

test "Key toString" {
    const key = Key{
        .tonic = .D,
        .is_major = false,
        .confidence = 0.85,
    };

    var buf: [32]u8 = undefined;
    const str = try key.toString(&buf);
    try std.testing.expectEqualStrings("D minor", str);
}
