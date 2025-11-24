# Audio Library Implementation Guide

This document provides implementation guidance for complex features that require extensive development.

## Full Codec Implementations

### 1. MP3 Decoder (MPEG-1/2 Layer III)

**Complexity**: Very High (~5,000+ lines)
**Current Status**: Header parsing complete, frame decoding needed

**Required Components**:
- Huffman decoding tables (main_data, scalefac, etc.)
- IMDCT (Inverse Modified Discrete Cosine Transform)
- Polyphase synthesis filterbank (32 subbands)
- Bit reservoir management
- Joint stereo decoding (M/S, Intensity)
- Psychoacoustic model (for encoding)

**Implementation Steps**:
1. Decode Huffman-coded spectral coefficients
2. Requantize and reorder coefficients
3. Apply stereo processing (if joint stereo)
4. Perform IMDCT (18-point or 6-point for short blocks)
5. Apply synthesis polyphase filterbank
6. Handle bit reservoir for variable bitrate
7. Output PCM samples

**References**:
- ISO/IEC 11172-3 (MPEG-1 Audio)
- ISO/IEC 13818-3 (MPEG-2 Audio)
- minimp3 (C reference implementation)

---

### 2. AAC Decoder (Advanced Audio Coding)

**Complexity**: Very High (~6,000+ lines)
**Current Status**: ADTS header parsing complete

**Required Components**:
- MDCT/IMDCT implementation
- Temporal Noise Shaping (TNS)
- Prediction (Main/LTP profiles)
- Spectral Band Replication (SBR) for HE-AAC
- Parametric Stereo (PS) for HE-AAC v2
- Huffman decoding
- Quantization/Dequantization

**Implementation Steps**:
1. Parse ADTS/ADIF/LATM containers
2. Decode Huffman-coded spectral data
3. Dequantize coefficients using scale factors
4. Apply TNS filtering
5. Perform IMDCT (2048/256-point for long/short windows)
6. Apply window overlap-add
7. Optionally apply SBR (frequency extension)
8. Optionally apply PS (stereo reconstruction)

**References**:
- ISO/IEC 14496-3 (MPEG-4 Audio)
- FAAD2 (open-source AAC decoder)
- FDK-AAC (Fraunhofer implementation)

---

### 3. Vorbis Decoder

**Complexity**: High (~4,000+ lines)
**Current Status**: Ogg container parsing complete

**Required Components**:
- MDCT implementation
- Floor/residue decoding
- Codebook (Huffman-style VQ) decoding
- Window functions
- Channel coupling

**Implementation Steps**:
1. Parse Vorbis headers (identification, comment, setup)
2. Decode audio packet (floor, residue, coupling)
3. Reconstruct floor curve
4. Decode residue vectors
5. Apply inverse coupling
6. Perform IMDCT with windowing
7. Overlap-add synthesis

**References**:
- Xiph.org Vorbis I Specification
- libvorbis (reference implementation)
- stb_vorbis (single-file decoder)

---

### 4. Opus Decoder

**Complexity**: Very High (~8,000+ lines)
**Current Status**: Ogg Opus container parsing complete

**Required Components**:
- SILK decoder (speech codec, LP-based)
- CELT decoder (music codec, MDCT-based)
- Hybrid mode (SILK + CELT)
- Range decoder
- Packet loss concealment

**Implementation Steps**:
1. Parse Opus packet TOC (table of contents)
2. Range decode packet data
3. For SILK frames: LP synthesis, LTP prediction
4. For CELT frames: IMDCT, PVQ dequantization
5. For hybrid: Combine SILK and CELT outputs
6. Apply postfiltering
7. Handle packet loss with concealment

**References**:
- RFC 6716 (Opus specification)
- libopus (reference implementation)
- Opus codec website (opus-codec.org)

---

## SIMD-Optimized FFT

**Complexity**: Medium (~1,500 lines)
**Benefit**: 4-8x performance improvement

**Required**:
- AVX/AVX2 intrinsics for x86-64
- NEON intrinsics for ARM
- Radix-2/4/8 butterfly operations
- Twiddle factor lookup tables
- Bit-reversal permutation

**Implementation**:
```zig
const std = @import("std");
const Vector = @Vector;

pub fn fft_avx2(real: []f32, imag: []f32) void {
    const n = real.len;

    // Bit-reversal reordering
    bitReverse(real, imag, n);

    // Cooley-Tukey FFT with AVX2 vectorization
    var step: usize = 2;
    while (step <= n) : (step *= 2) {
        const half_step = step / 2;

        // Process 8 butterflies at a time with AVX2
        var k: usize = 0;
        while (k < n) : (k += step) {
            var j: usize = 0;
            while (j < half_step) : (j += 8) {
                // Load 8 complex values
                const r1: @Vector(8, f32) = real[k + j..][0..8].*;
                const i1: @Vector(8, f32) = imag[k + j..][0..8].*;
                const r2: @Vector(8, f32) = real[k + j + half_step..][0..8].*;
                const i2: @Vector(8, f32) = imag[k + j + half_step..][0..8].*;

                // Twiddle factors
                const wr: @Vector(8, f32) = getTwiddleReal(j, step);
                const wi: @Vector(8, f32) = getTwiddleImag(j, step);

                // Complex multiplication: (r2 + i*i2) * (wr + i*wi)
                const tr = r2 * wr - i2 * wi;
                const ti = r2 * wi + i2 * wr;

                // Butterfly
                real[k + j..][0..8].* = r1 + tr;
                imag[k + j..][0..8].* = i1 + ti;
                real[k + j + half_step..][0..8].* = r1 - tr;
                imag[k + j + half_step..][0..8].* = i1 - ti;
            }
        }
    }
}
```

---

## HTTP Streaming (Shoutcast/Icecast)

**Complexity**: Medium (~1,000 lines)

**Required Components**:
- HTTP client with streaming support
- Icecast metadata parsing
- Ring buffer for stream data
- Decoder integration (MP3/AAC/Opus)
- Reconnection logic

**Implementation**:
```zig
pub const StreamingClient = struct {
    allocator: Allocator,
    url: []const u8,
    http_client: std.http.Client,
    ring_buffer: RingBuffer,
    decoder: *AudioDecoder,
    metadata_callback: ?*const fn([]const u8) void,

    pub fn connect(self: *Self) !void {
        // Parse URL
        // Connect to server
        // Send HTTP GET with Icy-MetaData: 1
        // Parse headers for metaint
        // Start receive loop
    }

    pub fn receiveLoop(self: *Self) !void {
        while (true) {
            // Read data chunk
            // Extract metadata if present
            // Feed audio data to decoder
            // Push PCM to ring buffer
        }
    }
};
```

---

## VST/AU Plugin Hosting

**Complexity**: Very High (~10,000+ lines)

**VST3 Requirements**:
- COM-style interface implementation
- Parameter automation
- MIDI event handling
- Audio buffer processing
- GUI embedding (platform-specific)
- Preset management

**Audio Unit Requirements** (macOS):
- Core Audio component model
- Audio Unit v2/v3 APIs
- Property listeners
- Render callback
- View management (Cocoa)

**Recommendation**: Use existing bridge libraries
- JUCE (C++ framework with Zig bindings)
- clap (CLAP plugin API, simpler than VST)

---

## Dolby Atmos / Spatial Audio

**Complexity**: Very High (~15,000+ lines)
**Note**: Proprietary codec, requires licensing

**Open Alternative - Ambisonic Spatial Audio**:

**Required Components**:
- Spherical harmonics encoding/decoding
- HRTF convolution
- Binaural rendering
- Object-based panning
- Room acoustics simulation

**Implementation**:
```zig
pub const AmbisonicEncoder = struct {
    order: u8, // 1st order = 4 channels, 2nd = 9, 3rd = 16

    pub fn encodeSource(
        self: *Self,
        source: []const f32,
        azimuth: f32,
        elevation: f32,
        output: [][]f32, // [W, X, Y, Z, ...]
    ) void {
        // Compute spherical harmonic coefficients
        // Apply to source signal
    }
};

pub const BinauralRenderer = struct {
    hrtf_database: HrtfDatabase,

    pub fn renderBinaural(
        self: *Self,
        ambisonics: [][]const f32,
        left: []f32,
        right: []f32,
    ) void {
        // Decode ambisonics to virtual speakers
        // Apply HRTF for each speaker
        // Sum to stereo output
    }
};
```

---

## Speech Enhancement / Denoising AI

**Complexity**: Very High (~20,000+ lines with ML model)

**Approaches**:

1. **Traditional DSP** (Spectral Subtraction):
   - Already implemented in `noise.zig`
   - Simple but limited quality

2. **Deep Learning** (Recommended):

**Required Components**:
- RNN/LSTM or Transformer model
- ONNX runtime integration
- Pretrained models (e.g., Microsoft DNS Challenge models)
- Real-time inference pipeline

**Example with ONNX**:
```zig
pub const SpeechEnhancer = struct {
    model: onnx.Model,
    stft: STFT,

    pub fn enhance(self: *Self, noisy: []const f32, clean: []f32) !void {
        // 1. Compute STFT of input
        var magnitude = try self.stft.forward(noisy);

        // 2. Run neural network inference
        var mask = try self.model.infer(magnitude);

        // 3. Apply mask to magnitude
        for (magnitude, mask) |*mag, m| {
            mag.* *= m;
        }

        // 4. Inverse STFT
        try self.stft.inverse(magnitude, clean);
    }
};
```

**Pretrained Models**:
- Facebook's Demucs (source separation)
- Microsoft DNS Challenge models
- Nvidia's NeMo toolkit
- Speechbrain models

---

## Integration Checklist

For each completed feature:

1. ✅ Create module file in appropriate directory
2. ✅ Write comprehensive tests
3. ✅ Add to main `audio.zig` export
4. ✅ Update `build.zig` if needed
5. ✅ Document API in code comments
6. ✅ Add usage examples
7. ✅ Benchmark performance
8. ✅ Test on multiple platforms

---

## Performance Optimization

**General Guidelines**:
- Use SIMD where possible (@Vector types)
- Minimize allocations in hot paths
- Use comptime for constants
- Profile with `zig build -Doptimize=ReleaseFast`
- Consider CPU cache locality
- Batch process when feasible

**Example SIMD Optimization**:
```zig
// Before: Scalar processing
pub fn applyGain(samples: []f32, gain: f32) void {
    for (samples) |*s| {
        s.* *= gain;
    }
}

// After: SIMD processing
pub fn applyGainSIMD(samples: []f32, gain: f32) void {
    const vec_len = 8; // Process 8 samples at once
    const gain_vec: @Vector(vec_len, f32) = @splat(gain);

    var i: usize = 0;
    while (i + vec_len <= samples.len) : (i += vec_len) {
        var vec: @Vector(vec_len, f32) = samples[i..][0..vec_len].*;
        vec *= gain_vec;
        samples[i..][0..vec_len].* = vec;
    }

    // Handle remainder
    while (i < samples.len) : (i += 1) {
        samples[i] *= gain;
    }
}
```

---

## Priority Recommendations

**For Production Use**:
1. ✅ Complete multiband compressor (DONE)
2. ✅ Complete sidechain compression (DONE)
3. ✅ Complete modulation effects (DONE)
4. ⚠️ Implement SIMD FFT (HIGH PRIORITY)
5. ⚠️ Complete MP3 decoder (if needed)
6. ⏳ Other codecs as needed

**For Advanced Features**:
1. Implement basic HTTP streaming
2. Add Ambisonic spatial audio support
3. Integrate pretrained AI models for speech enhancement

**For Plugin Ecosystem**:
1. Consider CLAP plugin support (simpler than VST)
2. Build plugin scanner/manager
3. Implement preset system

---

This guide provides the roadmap for completing the audio library. Focus on features that provide the most value for your use case.
