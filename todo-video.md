# Home Video Library - Implementation TODO

A comprehensive, dependency-free video processing library for the Home language, implemented in Zig. Inspired by MediaBunny's feature set, designed for video editors and application developers.

---

## Table of Contents

1. [Core Architecture](#1-core-architecture)
2. [Container Formats](#2-container-formats)
3. [Video Codecs](#3-video-codecs)
4. [Audio Codecs](#4-audio-codecs)
5. [Subtitle Support](#5-subtitle-support)
6. [Video Operations](#6-video-operations)
7. [Audio Operations](#7-audio-operations)
8. [File I/O System](#8-file-io-system)
9. [Conversion Pipeline](#9-conversion-pipeline)
10. [Media Sources & Sinks](#10-media-sources--sinks)
11. [Metadata System](#11-metadata-system)
12. [Streaming & Live Support](#12-streaming--live-support)
13. [Hardware Acceleration](#13-hardware-acceleration)
14. [Performance Optimizations](#14-performance-optimizations)
15. [Home Language Bindings](#15-home-language-bindings)
16. [Testing & Validation](#16-testing--validation)
17. [Timeline & Editing](#17-timeline--editing)
18. [GIF Support](#18-gif-support)
19. [Thumbnails & Previews](#19-thumbnails--previews)
20. [Audio Visualization](#20-audio-visualization)
21. [GPU Compute](#21-gpu-compute)
22. [Documentation & Examples](#22-documentation--examples)

---

## 1. Core Architecture

### 1.1 Foundation Types
- [ ] `VideoFormat` enum (mp4, mov, webm, mkv, avi, etc.)
- [ ] `AudioFormat` enum (mp3, aac, ogg, wav, flac, etc.)
- [ ] `PixelFormat` enum (yuv420p, yuv422p, yuv444p, rgb24, rgba32, nv12, etc.)
- [ ] `SampleFormat` enum (s16, s24, s32, f32, f64, u8, etc.)
- [ ] `Timestamp` struct with microsecond precision internally, second-based API
- [ ] `Duration` struct with conversion utilities
- [ ] `Rational` struct for frame rates and time bases (num/denom)
- [ ] `ColorSpace` enum (bt601, bt709, bt2020, srgb, etc.)
- [ ] `ColorRange` enum (limited, full)
- [ ] `ChromaLocation` enum (left, center, topleft, etc.)

### 1.2 Core Structures
- [ ] `VideoFrame` - raw decoded video frame with pixel data
- [ ] `AudioFrame` - raw decoded audio samples
- [ ] `Packet` - encoded compressed data unit
- [ ] `Stream` - track within a container (video/audio/subtitle)
- [ ] `MediaFile` - container holding multiple streams
- [ ] `CodecContext` - encoder/decoder state and configuration
- [ ] `FormatContext` - muxer/demuxer state

### 1.3 Memory Management
- [ ] Custom allocator support throughout
- [ ] Frame pools for efficient reuse
- [ ] Zero-copy operations where possible
- [ ] Reference counting for shared buffers
- [ ] Lazy evaluation for reduced memory footprint

### 1.4 Error Handling
- [ ] `VideoError` comprehensive error set
- [ ] Detailed error messages with context
- [ ] Recovery suggestions where applicable

---

## 2. Container Formats

### 2.1 Video Containers (Read & Write)
- [ ] **MP4** (.mp4) - ISO Base Media File Format
  - [ ] ftyp, moov, mdat box parsing
  - [ ] Edit lists support
  - [ ] Fragmented MP4 (fMP4) for streaming
  - [ ] Fast-start (moov before mdat) option
  - [ ] Multiple audio/video tracks
- [ ] **QuickTime** (.mov) - Apple QuickTime format
  - [ ] Full moov atom support
  - [ ] ProRes marker handling
- [ ] **WebM** (.webm) - Matroska subset for web
  - [ ] EBML parsing
  - [ ] Cluster-based seeking
  - [ ] Append-only streaming mode
- [ ] **Matroska** (.mkv) - Full container support
  - [ ] Chapter markers
  - [ ] Attachment support (fonts, etc.)
  - [ ] Multiple subtitle tracks
- [ ] **AVI** (.avi) - Legacy container
  - [ ] RIFF chunk parsing
  - [ ] OpenDML extensions for >2GB files

### 2.2 Audio Containers (Read & Write)
- [ ] **MP3** (.mp3) - MPEG Audio Layer III
  - [ ] ID3v1 and ID3v2 tags
  - [ ] Xing/VBRI headers for VBR
- [ ] **Ogg** (.ogg) - Ogg container
  - [ ] Page structure parsing
  - [ ] Vorbis comment metadata
- [ ] **WAV** (.wav) - RIFF WAVE
  - [ ] PCM and compressed formats
  - [ ] Broadcast WAV extensions
  - [ ] RF64 for >4GB files
- [ ] **FLAC** (.flac) - Free Lossless Audio Codec container
  - [ ] Metadata blocks
  - [ ] Seek table support
- [ ] **AAC/ADTS** (.aac) - Raw AAC stream
  - [ ] ADTS header parsing
  - [ ] LATM support

### 2.3 Container Utilities
- [ ] Format detection from magic bytes
- [ ] Format detection from file extension
- [ ] MIME type generation with codec strings
- [ ] Container capability queries (supported codecs, track limits)
- [ ] Metadata format options per container

---

## 3. Video Codecs

### 3.1 Modern Codecs (Encode & Decode)
- [ ] **H.264/AVC** - Advanced Video Coding
  - [ ] Baseline, Main, High profiles
  - [ ] B-frame support
  - [ ] CABAC/CAVLC entropy coding
  - [ ] SPS/PPS handling
  - [ ] NAL unit parsing
- [ ] **H.265/HEVC** - High Efficiency Video Coding
  - [ ] Main, Main10 profiles
  - [ ] CTU size configuration
  - [ ] VPS/SPS/PPS handling
- [ ] **VP9** - Google's open codec
  - [ ] Profile 0, 1, 2, 3
  - [ ] Superframe parsing
  - [ ] Alpha channel support
- [ ] **AV1** - Alliance for Open Media
  - [ ] Main, High profiles
  - [ ] Film grain synthesis
  - [ ] OBU parsing

### 3.2 Legacy Codecs (Decode priority, Encode optional)
- [ ] **VP8** - WebM legacy codec
- [ ] **MPEG-4 Part 2** - DivX/Xvid compatibility
- [ ] **MPEG-2** - DVD video
- [ ] **MJPEG** - Motion JPEG
- [ ] **ProRes** (decode only) - Apple intermediate codec

### 3.3 Codec Configuration
- [ ] Bitrate control (CBR, VBR, CRF, CQP)
- [ ] Quality presets (very_low, low, medium, high, very_high)
- [ ] Profile/level selection
- [ ] GOP structure (keyframe interval)
- [ ] B-frame count and reference frames
- [ ] Motion estimation parameters
- [ ] Rate control lookahead
- [ ] Latency modes (quality vs realtime)

### 3.4 Codec Utilities
- [ ] Capability queries (canEncode, canDecode)
- [ ] Best codec selection for format
- [ ] Codec parameter string generation (avc1.64001f, etc.)

---

## 4. Audio Codecs

### 4.1 Compressed Audio (Encode & Decode)
- [ ] **AAC** - Advanced Audio Coding
  - [ ] LC, HE-AAC, HE-AACv2 profiles
  - [ ] ADTS wrapping
- [ ] **Opus** - Modern open codec
  - [ ] Voice and music modes
  - [ ] Variable bitrate
- [ ] **MP3** - MPEG Layer 3
  - [ ] CBR and VBR encoding
  - [ ] Layer I/II/III decoding
- [ ] **Vorbis** - Open audio in Ogg
- [ ] **FLAC** - Lossless compression
  - [ ] Compression levels 0-8
  - [ ] Seeking support
- [ ] **AC3/E-AC3** - Dolby Digital
- [ ] **DTS** (decode only) - DTS audio

### 4.2 PCM Audio (Always supported, no external deps)
- [ ] **PCM signed** - s8, s16le, s16be, s24le, s24be, s32le, s32be
- [ ] **PCM unsigned** - u8
- [ ] **PCM float** - f32le, f32be, f64le, f64be
- [ ] **A-law** - ITU G.711 A-law
- [ ] **μ-law** - ITU G.711 μ-law

### 4.3 Audio Configuration
- [ ] Sample rate selection (8000-192000 Hz)
- [ ] Channel count and layout
- [ ] Bitrate/quality settings
- [ ] Channel mapping for surround sound

---

## 5. Subtitle Support

### 5.1 Text-based Subtitles
- [ ] **WebVTT** (.vtt) - Web Video Text Tracks
  - [ ] Cue timing and text
  - [ ] Styling support
  - [ ] Positioning
- [ ] **SRT** (.srt) - SubRip format
  - [ ] Basic formatting tags
- [ ] **ASS/SSA** (.ass/.ssa) - Advanced SubStation Alpha
  - [ ] Style definitions
  - [ ] Positioning and effects

### 5.2 Image-based Subtitles (decode only)
- [ ] **PGS** - Blu-ray subtitles
- [ ] **VobSub** - DVD subtitles

### 5.3 Subtitle Operations
- [ ] Timing adjustment (offset, scale)
- [ ] Format conversion
- [ ] Encoding for container embedding

---

## 6. Video Operations

### 6.1 Frame Transformations
- [ ] **Resize** - Change resolution
  - [ ] Fit modes: fill, contain, cover, stretch
  - [ ] Scaling algorithms: nearest, bilinear, bicubic, lanczos
  - [ ] Aspect ratio preservation options
- [ ] **Crop** - Extract region (left, top, width, height)
- [ ] **Pad** - Add borders with color
- [ ] **Rotate** - 0°, 90°, 180°, 270° (with transpose)
- [ ] **Flip** - Horizontal and vertical
- [ ] **Transpose** - Diagonal flip

### 6.2 Color Operations
- [ ] **Color space conversion** (BT.601 ↔ BT.709 ↔ BT.2020)
- [ ] **Pixel format conversion** (YUV ↔ RGB, etc.)
- [ ] **Brightness/Contrast adjustment**
- [ ] **Saturation adjustment**
- [ ] **Hue rotation**
- [ ] **Gamma correction**
- [ ] **Color curves**
- [ ] **LUT application** (1D and 3D)

### 6.3 Temporal Operations
- [ ] **Trim** - Cut start/end by timestamp
- [ ] **Frame rate conversion**
  - [ ] Drop/duplicate frames
  - [ ] Frame interpolation (basic)
- [ ] **Speed adjustment** (0.25x - 4x)
- [ ] **Reverse playback**
- [ ] **Frame extraction** - Export single frames as images

### 6.4 Compositing
- [ ] **Alpha channel handling** (keep, discard, premultiply)
- [ ] **Overlay** - Picture-in-picture
- [ ] **Blend modes** (normal, multiply, screen, overlay, etc.)
- [ ] **Fade in/out**
- [ ] **Crossfade/dissolve transitions**

### 6.5 Filters & Effects
- [ ] **Blur** - Box, Gaussian
- [ ] **Sharpen** - Unsharp mask
- [ ] **Denoise** - Basic temporal/spatial
- [ ] **Deinterlace** - Bob, Weave, YADIF-style
- [ ] **Stabilization** (basic) - Motion analysis and compensation
- [ ] **Text overlay** - Burn-in text/watermarks
- [ ] **Image overlay** - Logos, watermarks

### 6.6 Analysis
- [ ] **Frame difference detection** - Scene change
- [ ] **Black frame detection**
- [ ] **Silence detection**
- [ ] **Histogram generation**
- [ ] **PSNR/SSIM calculation** - Quality metrics

---

## 7. Audio Operations

### 7.1 Sample Operations
- [ ] **Resample** - Sample rate conversion
  - [ ] Linear, sinc interpolation
- [ ] **Channel mixing**
  - [ ] Mono to stereo
  - [ ] Stereo to mono
  - [ ] Upmix/downmix (5.1 ↔ stereo)
  - [ ] Custom channel matrices
- [ ] **Sample format conversion**
- [ ] **Volume adjustment** - Gain in dB
- [ ] **Normalization** - Peak and loudness (EBU R128)

### 7.2 Temporal Operations
- [ ] **Trim** - Cut by timestamp
- [ ] **Speed adjustment** (with pitch preservation option)
- [ ] **Reverse**
- [ ] **Fade in/out**
- [ ] **Crossfade**

### 7.3 Filters & Effects
- [ ] **Equalization** - Parametric EQ bands
- [ ] **Compression** - Dynamic range compression
- [ ] **Limiter**
- [ ] **High-pass/Low-pass filters**
- [ ] **Noise gate**

### 7.4 Analysis
- [ ] **Peak level detection**
- [ ] **RMS level calculation**
- [ ] **Loudness metering** (LUFS)
- [ ] **Waveform generation**
- [ ] **Spectrum analysis**

---

## 8. File I/O System

### 8.1 Input Sources
- [ ] **FileSource** - Read from file path
- [ ] **BufferSource** - Read from memory buffer ([]u8)
- [ ] **StreamSource** - Read from reader interface
- [ ] Lazy loading - Only read bytes as needed
- [ ] Seeking support with fallback for non-seekable sources

### 8.2 Output Targets
- [ ] **FileTarget** - Write to file path
- [ ] **BufferTarget** - Write to growable buffer
- [ ] **StreamTarget** - Write to writer interface
- [ ] **NullTarget** - Discard output (for analysis only)

### 8.3 I/O Options
- [ ] Buffered I/O with configurable buffer size
- [ ] Memory-mapped file support (optional)
- [ ] Progress callbacks
- [ ] Cancellation support

---

## 9. Conversion Pipeline

### 9.1 High-Level Conversion API
- [ ] `convert()` - One-shot file conversion
- [ ] `ConversionOptions` struct with all parameters
- [ ] Progress tracking (0.0 - 1.0)
- [ ] Cancellation with cleanup
- [ ] Error recovery options

### 9.2 Conversion Modes
- [ ] **Transmux** - Change container, keep codec (fast)
- [ ] **Transcode** - Re-encode media
- [ ] **Passthrough** - Copy specific streams without re-encoding
- [ ] **Mixed** - Transcode some streams, passthrough others

### 9.3 Conversion Options
- [ ] Video codec selection and configuration
- [ ] Audio codec selection and configuration
- [ ] Subtitle handling (copy, burn-in, discard)
- [ ] Metadata handling (copy, transform, discard)
- [ ] Two-pass encoding support
- [ ] Target file size encoding

### 9.4 Batch Processing
- [ ] Multiple file conversion
- [ ] Parallel processing
- [ ] Queue management
- [ ] Per-file and overall progress

---

## 10. Media Sources & Sinks

### 10.1 Video Sources (for creating video)
- [ ] **ImageSequenceSource** - Create video from images
- [ ] **CanvasSource** - Frame-by-frame procedural generation
- [ ] **RawVideoSource** - From raw pixel buffers
- [ ] **EncodedPacketSource** - From pre-encoded packets

### 10.2 Audio Sources (for creating audio)
- [ ] **RawAudioSource** - From raw sample buffers
- [ ] **ToneGeneratorSource** - Synthesize test tones
- [ ] **SilenceSource** - Generate silence
- [ ] **EncodedPacketSource** - From pre-encoded packets

### 10.3 Video Sinks (for extracting video)
- [ ] **VideoFrameSink** - Get decoded frames
- [ ] **ImageSequenceSink** - Export as image files
- [ ] **EncodedPacketSink** - Get raw packets

### 10.4 Audio Sinks (for extracting audio)
- [ ] **AudioSampleSink** - Get decoded samples
- [ ] **WaveformSink** - Generate waveform data
- [ ] **EncodedPacketSink** - Get raw packets

---

## 11. Metadata System

### 11.1 Container Metadata
- [ ] Duration
- [ ] Bitrate (overall and per-stream)
- [ ] Creation date
- [ ] Modification date
- [ ] MIME type with codec string

### 11.2 Track/Stream Metadata
- [ ] Codec name and parameters
- [ ] Resolution (video)
- [ ] Frame rate (video)
- [ ] Sample rate, channels (audio)
- [ ] Language code (ISO 639-2)
- [ ] Track name
- [ ] Track disposition (default, forced, hearing_impaired, etc.)

### 11.3 Descriptive Metadata (ID3, Vorbis Comments, etc.)
- [ ] Title, Artist, Album
- [ ] Album Artist
- [ ] Track number / Total tracks
- [ ] Disc number / Total discs
- [ ] Genre
- [ ] Release date / Year
- [ ] Composer, Lyricist
- [ ] Copyright
- [ ] Comments
- [ ] Lyrics
- [ ] Cover art (multiple: front, back, etc.)

### 11.4 Technical Metadata
- [ ] Color space and primaries
- [ ] HDR metadata (mastering display, content light levels)
- [ ] Rotation
- [ ] Stereo 3D mode
- [ ] Spherical/VR projection

### 11.5 Metadata Operations
- [ ] Read metadata without full decode
- [ ] Write/update metadata
- [ ] Copy metadata between files
- [ ] Transform metadata during conversion
- [ ] Strip all metadata

---

## 12. Streaming & Live Support

### 12.1 Streaming Formats
- [ ] **HLS** output - Generate m3u8 playlist and segments
  - [ ] Segment duration control
  - [ ] Multiple quality variants
- [ ] **DASH** output - Generate MPD and segments
- [ ] **Fragmented MP4** - For MSE playback
- [ ] **WebM streaming** - Append-only clusters

### 12.2 Live Input
- [ ] Real-time encoding from frame sources
- [ ] Timestamp generation for live sources
- [ ] Backpressure handling

### 12.3 Network Output
- [ ] Write to network streams
- [ ] Chunked transfer support
- [ ] Reconnection handling

---

## 13. Hardware Acceleration

### 13.1 Platform Detection
- [ ] Detect available hardware encoders/decoders
- [ ] Fallback to software when unavailable

### 13.2 macOS/iOS - VideoToolbox
- [ ] H.264 hardware encode/decode
- [ ] HEVC hardware encode/decode
- [ ] ProRes decode

### 13.3 Linux - VAAPI/VDPAU
- [ ] Hardware decode support
- [ ] Hardware encode where available

### 13.4 Windows - D3D11/DXVA2
- [ ] Hardware decode support
- [ ] Hardware encode (NVENC, QSV, AMF)

### 13.5 Configuration
- [ ] Hardware preference hints (prefer_hardware, prefer_software, no_preference)
- [ ] Device selection for multi-GPU systems

---

## 14. Performance Optimizations

### 14.1 SIMD Acceleration
- [ ] Use Zig's @Vector for pixel operations
- [ ] YUV ↔ RGB conversion
- [ ] Scaling filters
- [ ] Audio resampling
- [ ] Color space conversion

### 14.2 Threading
- [ ] Multi-threaded encoding
- [ ] Multi-threaded decoding
- [ ] Parallel filter processing
- [ ] Thread pool with configurable size

### 14.3 Memory Efficiency
- [ ] Frame buffer pools
- [ ] Copy-on-write for immutable operations
- [ ] Lazy evaluation chains
- [ ] Streaming processing (avoid loading entire file)

### 14.4 I/O Optimization
- [ ] Asynchronous I/O
- [ ] Read-ahead buffering
- [ ] Write coalescing
- [ ] Memory-mapped files (optional)

---

## 15. Home Language Bindings

### 15.1 Core Video Type
```home
struct Video {
    // Follows pattern from packages/image
    width: u32
    height: u32
    duration: f64  // seconds
    frame_rate: f64
    // ... internal state
}
```

### 15.2 API Design (Home Language)
- [ ] `Video.load(path: string) -> Video`
- [ ] `Video.load_from_memory(data: [u8]) -> Video`
- [ ] `video.save(path: string)`
- [ ] `video.encode(format: VideoFormat) -> [u8]`
- [ ] `video.resize(width: u32, height: u32) -> Video`
- [ ] `video.crop(x: u32, y: u32, w: u32, h: u32) -> Video`
- [ ] `video.trim(start: f64, end: f64) -> Video`
- [ ] `video.rotate(degrees: i32) -> Video`
- [ ] `video.add_audio(audio: Audio) -> Video`
- [ ] `video.extract_audio() -> Audio`
- [ ] `video.get_frame(timestamp: f64) -> Image`
- [ ] `video.to_images(output_pattern: string)`
- [ ] `Video.from_images(pattern: string, fps: f64) -> Video`

### 15.3 Audio Type
- [ ] `Audio.load(path: string) -> Audio`
- [ ] `audio.save(path: string)`
- [ ] `audio.resample(sample_rate: u32) -> Audio`
- [ ] `audio.to_mono() -> Audio`
- [ ] `audio.to_stereo() -> Audio`
- [ ] `audio.trim(start: f64, end: f64) -> Audio`
- [ ] `audio.normalize() -> Audio`
- [ ] `audio.adjust_volume(db: f64) -> Audio`

### 15.4 Metadata Type
- [ ] `video.metadata() -> Metadata`
- [ ] `video.set_metadata(metadata: Metadata) -> Video`
- [ ] `Metadata.title`, `.artist`, `.album`, etc.

### 15.5 Streaming/Builder Pattern
- [ ] Method chaining: `video.resize(1920, 1080).trim(0, 60).save("out.mp4")`
- [ ] Lazy evaluation - operations applied on save/encode

---

## 16. Testing & Validation

### 16.1 Unit Tests
- [ ] Each codec encoder/decoder
- [ ] Each container muxer/demuxer
- [ ] All filter operations
- [ ] Metadata read/write
- [ ] Edge cases (empty files, corrupted data, etc.)

### 16.2 Integration Tests
- [ ] Full encode → decode round-trip
- [ ] Format conversion accuracy
- [ ] Metadata preservation
- [ ] Large file handling
- [ ] Streaming output verification

### 16.3 Conformance Tests
- [ ] H.264 conformance streams
- [ ] HEVC conformance streams
- [ ] Container format compliance

### 16.4 Performance Tests
- [ ] Benchmark encoding speed (fps)
- [ ] Benchmark decoding speed (fps)
- [ ] Memory usage profiling
- [ ] Comparison with reference implementations

### 16.5 Test Media
- [ ] Sample files for each format
- [ ] Edge case files (unusual resolutions, frame rates)
- [ ] Corrupted file samples for error handling

---

## Implementation Priority

### Phase 1: Foundation (MVP)
1. Core types and structures
2. WAV container (simple, for audio testing)
3. PCM audio (no compression)
4. Raw video frames
5. Basic file I/O
6. Home language bindings skeleton

### Phase 2: Basic Video
1. MP4 container (read)
2. H.264 decoder
3. MP4 container (write)
4. H.264 encoder
5. Basic resize/crop operations

### Phase 3: Audio
1. MP3 container
2. AAC codec
3. Audio resampling
4. Channel mixing
5. Volume/normalization

### Phase 4: Advanced Formats
1. WebM/Matroska container
2. VP9 codec
3. AV1 codec (decode first)
4. HEVC codec
5. Opus audio

### Phase 5: Features
1. Full metadata system
2. Subtitle support
3. Color operations
4. Advanced filters
5. Streaming output

### Phase 6: Performance
1. SIMD optimization
2. Multi-threading
3. Hardware acceleration stubs
4. Memory optimization

---

## File Structure

```
packages/video/
├── src/
│   ├── video.zig              # Main module, public API
│   ├── core/
│   │   ├── types.zig          # Core types (Timestamp, Rational, etc.)
│   │   ├── frame.zig          # VideoFrame, AudioFrame
│   │   ├── packet.zig         # Encoded packets
│   │   ├── stream.zig         # Stream abstraction
│   │   └── error.zig          # Error types
│   ├── containers/
│   │   ├── mp4.zig            # MP4/MOV muxer/demuxer
│   │   ├── webm.zig           # WebM/MKV muxer/demuxer
│   │   ├── wav.zig            # WAV container
│   │   ├── mp3.zig            # MP3 container
│   │   ├── ogg.zig            # Ogg container
│   │   └── flac.zig           # FLAC container
│   ├── codecs/
│   │   ├── video/
│   │   │   ├── h264.zig       # H.264/AVC codec
│   │   │   ├── hevc.zig       # H.265/HEVC codec
│   │   │   ├── vp9.zig        # VP9 codec
│   │   │   ├── av1.zig        # AV1 codec
│   │   │   └── mjpeg.zig      # Motion JPEG
│   │   └── audio/
│   │       ├── aac.zig        # AAC codec
│   │       ├── mp3.zig        # MP3 codec
│   │       ├── opus.zig       # Opus codec
│   │       ├── vorbis.zig     # Vorbis codec
│   │       ├── flac.zig       # FLAC codec
│   │       └── pcm.zig        # PCM (uncompressed)
│   ├── filters/
│   │   ├── video/
│   │   │   ├── scale.zig      # Resize/scale
│   │   │   ├── crop.zig       # Crop
│   │   │   ├── rotate.zig     # Rotation
│   │   │   ├── color.zig      # Color adjustments
│   │   │   └── overlay.zig    # Compositing
│   │   └── audio/
│   │       ├── resample.zig   # Sample rate conversion
│   │       ├── mix.zig        # Channel mixing
│   │       ├── volume.zig     # Volume/normalize
│   │       └── eq.zig         # Equalization
│   ├── io/
│   │   ├── source.zig         # Input sources
│   │   ├── target.zig         # Output targets
│   │   └── buffer.zig         # Buffer utilities
│   ├── metadata/
│   │   ├── metadata.zig       # Metadata types
│   │   ├── id3.zig            # ID3 tags
│   │   └── vorbis_comment.zig # Vorbis comments
│   ├── subtitles/
│   │   ├── webvtt.zig         # WebVTT parser/writer
│   │   ├── srt.zig            # SRT parser
│   │   └── ass.zig            # ASS/SSA parser
│   └── util/
│       ├── bitstream.zig      # Bit-level reading/writing
│       ├── math.zig           # Math utilities
│       └── simd.zig           # SIMD helpers
├── tests/
│   ├── unit/
│   ├── integration/
│   └── samples/               # Test media files
└── build.zig
```

---

## Notes

- **Zero Dependencies**: All codec implementations must be pure Zig, no FFmpeg or other C libraries
- **Follow Image Package Pattern**: API design should mirror `packages/image` for consistency
- **Lazy Evaluation**: Operations should be chainable and only execute on save/encode
- **Microsecond Precision**: Internal timing uses microseconds, API uses seconds (f64)
- **Thread Safety**: All public types should be safe to share across threads
- **Streaming First**: Design for streaming use cases, not just file-to-file conversion

---

## 17. Timeline & Editing

### 17.1 Timeline Structure
- [ ] `Timeline` - Multi-track editing container
- [ ] `Track` - Video, audio, or subtitle track lane
- [ ] `Clip` - Media segment on a track
- [ ] `Transition` - Effect between clips

### 17.2 Non-Linear Editing (NLE) Operations
- [ ] **Insert clip** at position
- [ ] **Overwrite clip** at position
- [ ] **Ripple delete** - Remove and shift subsequent clips
- [ ] **Roll edit** - Adjust cut point between clips
- [ ] **Slip edit** - Move media within clip boundaries
- [ ] **Slide edit** - Move clip while adjusting neighbors
- [ ] **Razor/split** - Cut clip at position

### 17.3 Multi-Track Support
- [ ] Unlimited video tracks with layering/compositing
- [ ] Unlimited audio tracks with mixing
- [ ] Track enable/disable (solo, mute)
- [ ] Track opacity and blend modes

### 17.4 Timeline Export
- [ ] Render timeline to single output file
- [ ] Progress reporting during render
- [ ] Preview render (lower quality, faster)
- [ ] Render queue for batch exports

### 17.5 Project Serialization
- [ ] Save/load timeline projects (JSON or custom format)
- [ ] EDL (Edit Decision List) export
- [ ] XML export (Final Cut Pro XML, etc.)

---

## 18. GIF Support

### 18.1 GIF Container
- [ ] **GIF reader** - Parse GIF87a/GIF89a
  - [ ] Frame extraction
  - [ ] Global/local color tables
  - [ ] Animation timing (delay)
  - [ ] Disposal methods
  - [ ] Transparency
- [ ] **GIF writer** - Generate animated GIFs
  - [ ] Color quantization (median cut, octree)
  - [ ] Dithering (Floyd-Steinberg, ordered)
  - [ ] Frame optimization (delta frames)
  - [ ] Loop count control

### 18.2 GIF Operations
- [ ] `video.to_gif()` - Convert video to GIF
- [ ] `gif.to_video()` - Convert GIF to video format
- [ ] Quality/size tradeoff options
- [ ] Max colors configuration (2-256)
- [ ] Frame rate reduction for smaller files

### 18.3 GIF Optimization
- [ ] Lossy compression (color reduction)
- [ ] Transparency optimization
- [ ] Frame coalescing
- [ ] Global vs local palette selection

---

## 19. Thumbnails & Previews

### 19.1 Thumbnail Generation
- [ ] `video.thumbnail()` - Extract representative frame
- [ ] `video.thumbnail_at(timestamp)` - Frame at specific time
- [ ] `video.thumbnail_grid(rows, cols)` - Contact sheet / sprite
- [ ] `video.thumbnails(count)` - Multiple evenly-spaced frames

### 19.2 Thumbnail Options
- [ ] Output size configuration
- [ ] Smart scene detection for best frame
- [ ] Skip black frames option
- [ ] Quality/compression settings

### 19.3 Video Preview Generation
- [ ] Proxy/preview video generation (lower res)
- [ ] Preview timeline (scrubbing preview strip)
- [ ] Hover preview frames
- [ ] Animated thumbnail (mini video preview)

### 19.4 Sprite Sheet Generation
- [ ] `video.sprite_sheet(options)` - Generate sprite image + metadata
  - [ ] Single image containing all thumbnails in grid
  - [ ] Configurable sprite dimensions (width, height per frame)
  - [ ] Configurable interval (e.g., every 5 seconds)
  - [ ] Configurable grid layout (rows x columns per sheet)
  - [ ] Multiple output sheets for long videos
- [ ] **WebVTT sprite metadata** - For HTML5 video players
  - [ ] Generate .vtt file with sprite coordinates
  - [ ] Compatible with Video.js, JW Player, etc.
- [ ] **JSON sprite metadata** - For custom implementations
  - [ ] Frame timestamps and coordinates
  - [ ] Sheet index for multi-sheet sprites
- [ ] **Sprite options**
  - [ ] Output format (PNG, JPEG, WebP)
  - [ ] Quality/compression settings
  - [ ] Max sprites per sheet
  - [ ] Total number of sprites
  - [ ] Start/end time range

---

## 20. Audio Visualization

### 20.1 Waveform Generation
- [ ] `audio.waveform(width, height)` - Generate waveform image
- [ ] `audio.waveform_data()` - Get raw waveform data points
- [ ] Multiple styles (bars, line, filled)
- [ ] Color customization
- [ ] Stereo (dual channel) display

### 20.2 Spectrum Visualization
- [ ] FFT-based frequency analysis
- [ ] Spectrogram generation (time vs frequency)
- [ ] Real-time spectrum data for visualizers

### 20.3 Audio Meters
- [ ] Peak level metering
- [ ] RMS level metering
- [ ] LUFS loudness metering
- [ ] Phase correlation meter

---

## 21. GPU Compute

### 21.1 Compute Shader Support (Future)
- [ ] Metal compute shaders (macOS/iOS)
- [ ] Vulkan compute (cross-platform)
- [ ] OpenCL fallback (legacy)

### 21.2 GPU-Accelerated Operations
- [ ] Color space conversion
- [ ] Scaling/resize
- [ ] Blur/sharpen filters
- [ ] Compositing/blending
- [ ] LUT application

### 21.3 GPU Memory Management
- [ ] Texture pooling
- [ ] CPU ↔ GPU transfer optimization
- [ ] Pipeline state caching

---

## 22. Documentation & Examples

### 22.1 API Documentation
- [ ] Complete API reference (doc comments)
- [ ] Type documentation
- [ ] Error handling guide

### 22.2 Tutorials & Guides
- [ ] Quick start guide
- [ ] Format conversion tutorial
- [ ] Video editing tutorial
- [ ] Streaming output guide
- [ ] Custom codec guide (for advanced users)

### 22.3 Example Programs
- [ ] Basic conversion example
- [ ] Thumbnail generator
- [ ] Video trimmer
- [ ] Audio extractor
- [ ] Watermark overlay
- [ ] GIF creator
- [ ] Timeline editor (mini NLE)
- [ ] Streaming encoder
- [ ] Batch processor

### 22.4 Migration Guides
- [ ] From FFmpeg command line
- [ ] From other video libraries

---

## Additional Considerations

### Accessibility Features
- [ ] Audio description track support
- [ ] Closed caption extraction/embedding
- [ ] Sign language video track flag

### DRM & Protection (Read-only)
- [ ] Detect encrypted content (report, don't bypass)
- [ ] Clear key decryption (when keys provided)

### Format-Specific Features
- [ ] **MP4**: Chapter markers, alternate tracks
- [ ] **MKV**: Attachments (fonts), editions
- [ ] **WebM**: Cues for seeking

### Interoperability
- [ ] Integration with `packages/image` (frame ↔ image)
- [ ] Raw frame export for ML/CV pipelines
- [ ] Audio buffer export for audio processing libs

### Edge Cases & Robustness
- [ ] Handle truncated/corrupted files gracefully
- [ ] Seek to nearest keyframe when exact seek impossible
- [ ] Variable frame rate (VFR) handling
- [ ] Timecode discontinuities
- [ ] Large file support (>4GB, >2 hours)

### Compliance & Standards
- [ ] ITU-R BT.601, BT.709, BT.2020 compliance
- [ ] SMPTE timecode support
- [ ] Broadcast-safe levels option
