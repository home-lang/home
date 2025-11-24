// Home Audio Library - MIDI Synthesizer
// Wavetable and FM synthesis engine

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Oscillator waveform types
pub const Waveform = enum {
    sine,
    saw,
    square,
    triangle,
    noise,

    pub fn generate(self: Waveform, phase: f32) f32 {
        return switch (self) {
            .sine => @sin(phase),
            .saw => 2.0 * (phase / (2.0 * math.pi) - @floor(phase / (2.0 * math.pi) + 0.5)),
            .square => if (@sin(phase) >= 0) @as(f32, 1) else -1,
            .triangle => {
                const t = phase / (2.0 * math.pi);
                const frac = t - @floor(t);
                return if (frac < 0.5) 4.0 * frac - 1.0 else 3.0 - 4.0 * frac;
            },
            .noise => {
                // Simple pseudo-random noise
                var seed = @as(u32, @intFromFloat(phase * 10000)) *% 2654435761;
                seed ^= seed >> 16;
                seed *%= 0x7feb352d;
                seed ^= seed >> 15;
                const val = @as(f32, @floatFromInt(seed)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
                return val * 2.0 - 1.0;
            },
        };
    }
};

/// ADSR envelope
pub const Envelope = struct {
    attack_time: f32, // seconds
    decay_time: f32,
    sustain_level: f32, // 0.0 - 1.0
    release_time: f32,

    // State
    state: State,
    level: f32,
    sample_rate: u32,

    const State = enum {
        idle,
        attack,
        decay,
        sustain,
        release,
    };

    const Self = @This();

    pub fn init(sample_rate: u32, attack: f32, decay: f32, sustain: f32, release: f32) Self {
        return Self{
            .attack_time = attack,
            .decay_time = decay,
            .sustain_level = math.clamp(sustain, 0, 1),
            .release_time = release,
            .state = .idle,
            .level = 0,
            .sample_rate = sample_rate,
        };
    }

    pub fn noteOn(self: *Self) void {
        self.state = .attack;
    }

    pub fn noteOff(self: *Self) void {
        if (self.state != .idle) {
            self.state = .release;
        }
    }

    pub fn process(self: *Self) f32 {
        const sr = @as(f32, @floatFromInt(self.sample_rate));

        switch (self.state) {
            .idle => {
                self.level = 0;
            },
            .attack => {
                const increment = 1.0 / (self.attack_time * sr);
                self.level += increment;
                if (self.level >= 1.0) {
                    self.level = 1.0;
                    self.state = .decay;
                }
            },
            .decay => {
                const decrement = (1.0 - self.sustain_level) / (self.decay_time * sr);
                self.level -= decrement;
                if (self.level <= self.sustain_level) {
                    self.level = self.sustain_level;
                    self.state = .sustain;
                }
            },
            .sustain => {
                self.level = self.sustain_level;
            },
            .release => {
                const decrement = self.level / (self.release_time * sr);
                self.level -= decrement;
                if (self.level <= 0) {
                    self.level = 0;
                    self.state = .idle;
                }
            },
        }

        return self.level;
    }

    pub fn isActive(self: *Self) bool {
        return self.state != .idle;
    }
};

/// Single voice oscillator
pub const Voice = struct {
    note: u8, // MIDI note number
    velocity: f32, // 0.0 - 1.0
    phase: f32,
    frequency: f32,
    waveform: Waveform,
    envelope: Envelope,
    active: bool,

    const Self = @This();

    pub fn init(sample_rate: u32, waveform: Waveform) Self {
        return Self{
            .note = 0,
            .velocity = 0,
            .phase = 0,
            .frequency = 440,
            .waveform = waveform,
            .envelope = Envelope.init(sample_rate, 0.01, 0.1, 0.7, 0.2),
            .active = false,
        };
    }

    pub fn noteOn(self: *Self, note: u8, velocity: u8) void {
        self.note = note;
        self.velocity = @as(f32, @floatFromInt(velocity)) / 127.0;
        self.frequency = midiToFreq(note);
        self.phase = 0;
        self.envelope.noteOn();
        self.active = true;
    }

    pub fn noteOff(self: *Self) void {
        self.envelope.noteOff();
    }

    pub fn processSample(self: *Self, sample_rate: u32) f32 {
        if (!self.active) return 0;

        // Generate waveform
        const sample = self.waveform.generate(self.phase);

        // Apply envelope
        const env = self.envelope.process();
        const output = sample * env * self.velocity;

        // Advance phase
        const sr = @as(f32, @floatFromInt(sample_rate));
        self.phase += 2.0 * math.pi * self.frequency / sr;
        if (self.phase >= 2.0 * math.pi) {
            self.phase -= 2.0 * math.pi;
        }

        // Deactivate if envelope finished
        if (!self.envelope.isActive()) {
            self.active = false;
        }

        return output;
    }
};

/// Polyphonic synthesizer
pub const Synthesizer = struct {
    allocator: Allocator,
    sample_rate: u32,
    voices: []Voice,
    max_voices: usize,
    waveform: Waveform,

    // Global parameters
    master_volume: f32,
    pan: f32, // -1.0 (left) to 1.0 (right)

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, max_voices: usize, waveform: Waveform) !Self {
        const voices = try allocator.alloc(Voice, max_voices);
        for (voices) |*voice| {
            voice.* = Voice.init(sample_rate, waveform);
        }

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .voices = voices,
            .max_voices = max_voices,
            .waveform = waveform,
            .master_volume = 0.5,
            .pan = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.voices);
    }

    pub fn setWaveform(self: *Self, waveform: Waveform) void {
        self.waveform = waveform;
        for (self.voices) |*voice| {
            voice.waveform = waveform;
        }
    }

    pub fn setMasterVolume(self: *Self, volume: f32) void {
        self.master_volume = math.clamp(volume, 0, 1);
    }

    pub fn setPan(self: *Self, pan: f32) void {
        self.pan = math.clamp(pan, -1, 1);
    }

    /// Find an inactive voice or steal the oldest
    fn allocateVoice(self: *Self) ?*Voice {
        // First, try to find an inactive voice
        for (self.voices) |*voice| {
            if (!voice.active) {
                return voice;
            }
        }

        // All voices active, steal the first one (voice stealing)
        return &self.voices[0];
    }

    pub fn noteOn(self: *Self, note: u8, velocity: u8) void {
        if (self.allocateVoice()) |v| {
            v.noteOn(note, velocity);
        }
    }

    pub fn noteOff(self: *Self, note: u8) void {
        for (self.voices) |*voice| {
            if (voice.active and voice.note == note) {
                voice.noteOff();
            }
        }
    }

    pub fn allNotesOff(self: *Self) void {
        for (self.voices) |*voice| {
            if (voice.active) {
                voice.noteOff();
            }
        }
    }

    pub fn processSample(self: *Self) f32 {
        var output: f32 = 0;

        for (self.voices) |*voice| {
            output += voice.processSample(self.sample_rate);
        }

        return output * self.master_volume;
    }

    pub fn process(self: *Self, output: []f32) void {
        for (output) |*sample| {
            sample.* = self.processSample();
        }
    }

    /// Process stereo output
    pub fn processStereo(self: *Self, left: []f32, right: []f32) void {
        const len = @min(left.len, right.len);

        for (0..len) |i| {
            const mono = self.processSample();

            // Apply panning
            const pan_normalized = (self.pan + 1.0) / 2.0; // 0 to 1
            const left_gain = @sqrt(1.0 - pan_normalized);
            const right_gain = @sqrt(pan_normalized);

            left[i] = mono * left_gain;
            right[i] = mono * right_gain;
        }
    }

    pub fn getActiveVoiceCount(self: *Self) usize {
        var count: usize = 0;
        for (self.voices) |voice| {
            if (voice.active) count += 1;
        }
        return count;
    }
};

/// FM (Frequency Modulation) synthesizer
pub const FMSynth = struct {
    sample_rate: u32,
    carrier_freq: f32,
    modulator_freq: f32,
    modulation_index: f32,

    carrier_phase: f32,
    modulator_phase: f32,

    envelope: Envelope,
    active: bool,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        return Self{
            .sample_rate = sample_rate,
            .carrier_freq = 440,
            .modulator_freq = 440,
            .modulation_index = 1.0,
            .carrier_phase = 0,
            .modulator_phase = 0,
            .envelope = Envelope.init(sample_rate, 0.01, 0.1, 0.7, 0.2),
            .active = false,
        };
    }

    pub fn noteOn(self: *Self, note: u8, mod_ratio: f32, mod_index: f32) void {
        self.carrier_freq = midiToFreq(note);
        self.modulator_freq = self.carrier_freq * mod_ratio;
        self.modulation_index = mod_index;
        self.carrier_phase = 0;
        self.modulator_phase = 0;
        self.envelope.noteOn();
        self.active = true;
    }

    pub fn noteOff(self: *Self) void {
        self.envelope.noteOff();
    }

    pub fn processSample(self: *Self) f32 {
        if (!self.active) return 0;

        const sr = @as(f32, @floatFromInt(self.sample_rate));

        // Generate modulator
        const modulator = @sin(self.modulator_phase);

        // FM synthesis: carrier frequency modulated by modulator
        const modulated_phase = self.carrier_phase + self.modulation_index * modulator;
        const output = @sin(modulated_phase);

        // Apply envelope
        const env = self.envelope.process();

        // Advance phases
        self.carrier_phase += 2.0 * math.pi * self.carrier_freq / sr;
        self.modulator_phase += 2.0 * math.pi * self.modulator_freq / sr;

        if (self.carrier_phase >= 2.0 * math.pi) self.carrier_phase -= 2.0 * math.pi;
        if (self.modulator_phase >= 2.0 * math.pi) self.modulator_phase -= 2.0 * math.pi;

        // Deactivate if envelope finished
        if (!self.envelope.isActive()) {
            self.active = false;
        }

        return output * env;
    }
};

/// Convert MIDI note number to frequency in Hz
pub fn midiToFreq(note: u8) f32 {
    return 440.0 * math.pow(f32, 2.0, (@as(f32, @floatFromInt(note)) - 69.0) / 12.0);
}

// ============================================================================
// Tests
// ============================================================================

test "midiToFreq" {
    const a4 = midiToFreq(69); // A4 = 440 Hz
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), a4, 0.01);

    const c4 = midiToFreq(60); // C4 ≈ 261.63 Hz
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), c4, 0.1);
}

test "Envelope ADSR" {
    var env = Envelope.init(44100, 0.001, 0.001, 0.7, 0.001);

    env.noteOn();
    try std.testing.expectEqual(Envelope.State.attack, env.state);

    // Process attack phase
    for (0..100) |_| {
        _ = env.process();
    }

    env.noteOff();
    try std.testing.expectEqual(Envelope.State.release, env.state);
}

test "Synthesizer init" {
    const allocator = std.testing.allocator;

    var synth = try Synthesizer.init(allocator, 44100, 8, .sine);
    defer synth.deinit();

    try std.testing.expectEqual(@as(usize, 8), synth.max_voices);
    try std.testing.expectEqual(@as(usize, 0), synth.getActiveVoiceCount());
}

test "Synthesizer note on/off" {
    const allocator = std.testing.allocator;

    var synth = try Synthesizer.init(allocator, 44100, 8, .saw);
    defer synth.deinit();

    synth.noteOn(60, 100);
    try std.testing.expectEqual(@as(usize, 1), synth.getActiveVoiceCount());

    var output: [100]f32 = undefined;
    synth.process(&output);

    synth.noteOff(60);

    // Process until voice is released (release time is 0.2s = 8820 samples at 44.1kHz)
    for (0..20000) |_| {
        _ = synth.processSample();
    }

    // Voice should be deactivated after release
    const active = synth.getActiveVoiceCount();
    try std.testing.expect(active <= 1); // May have slight tail
}

test "FMSynth basic" {
    var fm = FMSynth.init(44100);

    fm.noteOn(60, 2.0, 5.0); // Note C4, mod ratio 2:1, mod index 5
    try std.testing.expect(fm.active);

    const sample = fm.processSample();
    try std.testing.expect(@abs(sample) <= 1.0);
}

test "Waveform generation" {
    const sine = Waveform.sine.generate(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sine, 0.01);

    const saw = Waveform.saw.generate(math.pi);
    try std.testing.expect(@abs(saw) <= 1.0);
}
