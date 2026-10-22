# Header-checked native video adapter

`codecs/video/native_encoder.{c,h,zig}` compiles the x264/x265 boundary against
installed vendor headers. Only Home-owned scalar configuration and borrowed
length-prefixed packet data cross the interface. The Zig wrapper validates input
geometry, timestamps and encode/drain state. Link the C source and libx264/libx265.

`Encoder.initWithColor(config, color)` / `home_encoder_open_color` adds explicit
ISO color signaling without extending the existing 32-byte configuration ABI.
The separate 20-byte `Color` recipe contains its exact `struct_size`, primaries
(1 Rec.709, 6 SMPTE 170M, 9 Rec.2020), transfer (1 Rec.709, 8 linear, 13 sRGB),
matrix (1 BT.709, 6 BT.601, 9 BT.2020 nonconstant luminance), and `full_range`
(0 limited, 1 full). Unknown/reserved values and incorrect sizes fail before
allocation. Failed C construction clears the output handle. The recipe is copied
at construction; it is not retained. The original `Encoder.init` and C open
function keep Rec.709 primaries, sRGB transfer, BT.601 matrix and limited range.

The caller must supply I420 pixels matching that description. This API sets
AVC/HEVC VUI fields; it does not convert gamma/gamut or matrix/range. Portable
`color_description.Description.signal()` maps processed YCbCr descriptions into
the ISO values; do not pass the portable enum IDs directly to a codec.

For MP4, use `mp4_stream.Writer.initWithColor` or `initAvWithColor` with the same
values (the MP4 recipe uses `u16` codes and a boolean full-range flag). This writes
`colr/nclx` with the full-range flag in bit 7 and reserved bits zero. Invalid color
fails before any sink write. The old MP4 constructors retain the legacy tags.
The container does not infer VUI or check SPS/tag agreement: the owner must pass
the same color recipe to both components, including replacements and snapshots.

`tests/color_signal.zig` independently parses actual SPS/VUI and MP4 `nclx` bytes
for all 54 supported combinations under both AVC and HEVC, with video-only and
AAC track descriptions. It also checks old constructors, scalar ABI sizes and
rejection before output. Run `test-native-media.sh` for Debug/ReleaseSafe with
the pinned and development Zig toolchains. These are signaling tests, not gamut,
transfer, physical-camera or colorimetric conformance measurements.

`Encoder.requestKeyframe()` / `home_encoder_request_keyframe` requests an IDR for
the next submitted input. Requests coalesce. This supports independently decodable
recording splits without waiting for the regular GOP interval. Inspect emitted
packet timestamps and key flags before switching outputs: buffered AVC output
can precede the newly requested IDR. Keep headers outside packet history and
remux each segment with a fresh sample description and a rebased timeline.

Use requests only on an active encoder before draining, serialize every operation,
and consume borrowed output before another adapter call. The Zig wrapper rejects
requests after drain/failure. A request neither drains nor resets the encoder.

The standalone `tests/native_encoder_idr.zig` imports this module as `encoder` and
links its compiled C boundary. Its regression encodes eight frames under GOP100,
forces IDRs at inputs 3 and 6, checks actual AVC/HEVC IDR NAL types and packet keys,
counts every delayed/flushed frame, and rejects requests after drain. It passes
on Zig 0.15.2 and Home's installed 0.17 development toolchain with x264/x265.
zig-camera additionally remuxes split files and pre-roll snapshots and validates
them with independent decoders. No FFmpeg or Libav is used in this path.

`Encoder.initWithOptions(config, color, options)` /
`home_encoder_open_options` adds a copied 16-byte `Options` recipe without
changing either existing configuration ABI. Its profile selects a compatibility
ceiling: 0 retains codec defaults (AVC High, HEVC Main), 1 AVC Baseline, 2 Main,
3 AVC High, 4 AVC Constrained Baseline. x264's Baseline is constrained; a simpler
compatible stream may signal a lower profile than the selected ceiling. HEVC
accepts only default/Main because this bridge supplies 8-bit I420.

Preset IDs are 0 veryfast (legacy default), 1 ultrafast, 2 superfast, 3 faster,
4 fast, 5 medium, 6 slow, 7 slower, 8 veryslow, 9 placebo. Presets control codec
search/compression work; single-thread, no-B-frame/lookahead and fixed CTU16
ownership remain in force. HEVC transform depths are capped to fit CTU16 even
when a slower preset assumes larger CTUs. No preset is a measured speed promise.

QP zero preserves quality/ABR behavior. QP 1..51 selects constant quantization,
disables adaptive QP and I/P/B offsets, and requires bitrate zero. It takes
precedence over the scalar quality field. Unknown IDs, incompatible HEVC
profiles, wrong sizes and mixed QP/bitrate policies reject before allocation;
C failures clear the output handle. Zig's portable policy checks run on pinned
0.15.2 and development 0.18. The standalone IDR suite also checks actual AVC SPS
profile constraints, preset construction and complete frame/key/drain behavior
under CQP. Independent decoded-media coverage lives in zig-camera's integration
suite; these checks do not establish a full codec conformance corpus.

The container configuration builder accepts emitted AVC Baseline (66), Main (77)
and High (100) SPS headers. Baseline/Main omit the High-only chroma/bit-depth
extension in avcC and Matroska CodecPrivate. High preserves its 8-bit 4:2:0
extension. Profile/compatibility/level and parameter-set bytes are retained
exactly, unsupported profiles reject before caller destination mutation, and
bounds remain checked. Pure tests cover the shorter records and unchanged
failure buffers; zig-camera independently decodes actual MP4 output under every
preset/profile policy on Linux. C admission tests additionally exercise null and
malformed option recipes, clear failed handles and preserve the scalar ABI sizes.

`Encoder.initWithLimits(config, color, options, limits)` /
`home_encoder_open_limits` adds a separate copied 16-byte `Limits` recipe. Earlier
configuration, color and options layouts stay unchanged. `level` is a decimal
level ceiling times ten (41 is 4.1), zero automatic. AVC uses the exported x264
level table for macroblock-rounded geometry, nominal rational frame rate,
profile-aware bitrate/CPB, references and motion range. HEVC uses checked Main-tier
picture/rate/CPB bounds with u64 cross-products before vendor floating-point/u32
conversion. Explicit construction inspects actual SPS requirement/profile before
returning ownership; a vendor warning cannot publish an over-ceiling header.
AVC retains automatic minimum-level selection after bounding resources; a high
ceiling does not force a needlessly high SPS label on a small stream.
The raw High-profile IDC 9 denotes level 1b and exceeds a 1.0 ceiling; automatic
1b selection is accepted only for ceilings of 1.1 or above.

`max_bitrate` is bits/sec and `buffer_bits` is CPB capacity in bits. Both are zero
or both are positive multiples of 1000; the buffer must cover at least one nominal
frame at the maximum rate. Nonzero target bitrate must fit the maximum, and VBV
requires non-CQP rate control. HEVC explicit levels also reject fixed QP. C errors
clear failed output handles. These are codec CPB controls, not container/network
packet caps, complete HRD conformance or optical/performance measurements.

The shared HEVC CTU16 policy remains in force. Higher requested ceilings are
constrained to at most effective level 4.1 so x265 cannot silently switch CTU size
and conflict with another instance. Inputs/rates requiring higher effective levels
reject; a safe CTU32/higher-resolution HEVC path remains separate work. Explicit
HEVC levels with CRF can cause the vendor to enable the level's default VBV limits
when none are supplied. Recipes describe requested policy, not measured/effective
vendor statistics. Legacy calls with no limits retain earlier behavior.

Tests cover every represented level ID, invalid units and CQP/rate conflicts,
failed C owners, emitted levels, IDRs/drains and exact versus fractional nominal
rate boundaries. Camera integration additionally checks state/header preservation,
restart/mode/recovery propagation, explicit resets, high-complexity VBV volume and
all accepted frames. Linux supplies independent AVC/HEVC decoders; local codec
checks and independent AAC/image readers are recorded separately. Vendor references:
https://github.com/mirror/x264/blob/master/common/tables.c and
https://github.com/videolan/x265/blob/master/source/encoder/level.cpp .
