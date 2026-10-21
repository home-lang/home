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
