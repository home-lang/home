# Header-checked native video adapter

`codecs/video/native_encoder.{c,h,zig}` compiles the x264/x265 boundary against
installed vendor headers. Only Home-owned scalar configuration and borrowed
length-prefixed packet data cross the interface. The Zig wrapper validates input
geometry, timestamps and encode/drain state. Link the C source and libx264/libx265.

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
