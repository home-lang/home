# Native AVC/HEVC and streamed MP4

`src/codecs/video/native_encoder.zig` is the supported standalone Home integration
for libx264/libx265. Compile `native_encoder.c` against the installed vendor
headers, then link x264/x265 directly. Only Home-owned fixed scalar structs cross
the C/Zig boundary; the old handwritten vendor structures in x264.zig/x265.zig
are not reused. There is no FFmpeg/Libav or encoder subprocess dependency.
The Zig wrapper works with Zig 0.15.2 and the Home 0.17 development toolchain.
Vendor libraries keep their GPL/commercial licenses; Home modules remain MIT.

The wrapper accepts checked I420 planes, returns borrowed length-prefixed NAL
packets, and preserves microsecond PTS. Serialize operations per encoder; packets
expire on the next call. Encode may return null while AVC VFR buffers one input.
Always drain `flush()` until null before deinit. Encoding after drain or error is
rejected. The integration fixes presets to veryfast, one frame thread, no B frames
or lookahead, closed GOPs, AVC High / HEVC Main, 8-bit 4:2:0. Quality 1..100 maps
linearly to CRF 51..0 (AVC minimum 1 to retain High-profile compatibility); bitrate >0 selects ABR in bits/sec, not strict CBR. Zero GOP
means 60. HEVC uses CTU16 across instances to avoid global x265 CTU mismatches.

`rgb_i420.zig` is a bounded, stride-checked conversion from RGB24. It improves
Home's existing RGB conversion approach with actual 2x2 chroma averaging. Output
is limited-range BT.601 with sRGB transfer / BT.709 primaries. This is SDR.

`src/containers/mp4_stream.zig` provides a sink-based single-video-track fragmented
MP4 writer, adapted from Home's existing MP4 box code. It writes complete AVC/HEVC
sample descriptions, avcC/hvcC from encoder headers, mvex/trex, accurate moof/traf/
tfhd/trun offsets, 64-bit tfdt, and one mdat per sample. Payload writes go straight
to the sink; there is no whole-recording buffer or growing sample table.

The writer accepts length-prefixed samples with PTS=DTS and explicit microsecond
durations. A recorder should retain one encoded packet to compute duration from
the next timestamp, preserving capture gaps; use nominal duration for the last.
The writer rejects malformed NAL lengths and non-increasing decode times. Partial
sink failure poisons the writer. It has a fixed 16KiB header bound, no seek index,
no audio, and supports the fixed 8-bit profiles emitted by this adapter.

Home's older pure-Zig H.264/HEVC slice encoders and fragmented-muxer implementation
remain legacy code; their feature lists are not conformance evidence for these
new modules. The new modules are available through video.native_encoder,
video.rgb_i420 and video.mp4_stream without pulling in the old codec graph.

From the repository root on Linux:

```sh
sudo apt install libx264-dev libx265-dev pkg-config
packages/video/test-native-media.sh
```

Focused tests validate geometry, original timestamps, all frames through drain,
invalid lifecycle, averaged chroma, fragment sizes/data offsets/64-bit time and
sink failure. They pass in Debug/ReleaseSafe with Zig 0.15.2 and Home's installed
0.17 development toolchain. zig-utils/zig-camera integration additionally checks
MP4 regular/gapped capture timelines and GOPs, and decodes AVC/HEVC using independent
Apple AVFoundation and Linux OpenH264/libde265. These are synthetic correctness
tests, not Pi hardware FPS, long-run reliability or compression-quality benchmarks.

References: [x265 API](https://x265.readthedocs.io/en/master/api.html),
[x264 public header](https://code.videolan.org/videolan/x264/-/blob/master/x264.h),
[ISO BMFF streaming requirements](https://www.w3.org/TR/mse-byte-stream-format-isobmff/).
