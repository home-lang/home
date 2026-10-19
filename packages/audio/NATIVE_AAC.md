# Native AAC-LC encoding

`src/encoding/native_aac.{c,h,zig}` is Home's opt-in streaming AAC-LC adapter.
It links the standalone FDK AAC library directly, without FFmpeg/Libav. The C
boundary uses the installed headers and opaque handles; no FDK layouts are
redeclared in Zig. Home's adapter is MIT; the FDK library retains its own license.

The older `AacEncoder` and `AacFullEncoder` prototypes emitted envelope bytes or
fixed-width coefficients as if they were AAC. Their encode entry points now
return `UnsupportedLegacyEncoder`. Configuration helpers remain available;
use `audio.NativeAacEncoder` or `audio.encoding.native_aac.Encoder` for real AAC.
The old prototype's partial-allocation cleanup is also fixed.

Compile `native_aac.c` with the system compiler, include the installed FDK header
root and link `fdk-aac`. Instantiate with an explicit sample rate, mono/stereo
channels and bitrate in bits/s. Supported rates are 8, 11.025, 12, 16, 22.05, 24,
32, 44.1 and 48kHz. Bitrate range is 16–320kb/s; unsupported combinations fail.
No resampling, HE-AAC, implicit input device access or ADTS transport is included.

`encode` accepts 1–1024 S16LE interleaved frames and returns the number consumed
plus an optional raw access unit. Retain and feed any unconsumed input. Borrowed
packet bytes expire at the next call. Fixed input/output buffers bound memory;
there is no frame-sized growing history. Serialize calls on each encoder.

The returned `Info` supplies the real AudioSpecificConfig, frame length and
codec delay in samples. Keep it with the stream. Drain `flush` until `null`, then
close. Encoding after drain fails. A codec failure poisons subsequent calls.
The muxer must account for codec delay and final zero padding; do not timestamp
packets from callback time or assume the codec delay is 1024/2048 samples.

Validation uses FDK 2.0.3 at commit
`716f4394641d53f0d79c9ddac3fa93b03a49f278`. Targeted tests exercise partial PCM,
configuration bytes, delayed drain, padding coverage and state rejection on Zig
0.15.2 and Home's development toolchain. Independent camera integration decodes
with FAAD2 and checks waveforms, segment sample counts and MP4 edit timelines.
See `.github/workflows/native-aac.yml`; no hardware performance claim is made.

```sh
zig test packages/audio/src/encoding/native_aac_test.zig \
  packages/audio/src/encoding/native_aac.c -lc -lfdk-aac
```
