# Bounded recording support

`src/containers/av_stream.zig` streams Matroska video plus lossless S16LE PCM
through a caller-owned synchronous sink. Supports MJPEG, AVC and HEVC; AVC/HEVC
samples must be four-byte NAL-length prefixed and accompanied by avcC/hvcC
CodecPrivate. Each packet is one cluster, using microsecond timecodes and one
common epoch. Per-track timestamps must increase; cross-track ordering may differ.
The writer keeps a fixed header buffer and no frame collection. A sink failure
poisons further writes. Final duration, seek cues and audio compression are absent.

`src/core/pcm_timeline.zig` owns a fixed PCM arena and descriptor queue. It rejects
capacity exhaustion without mutation, checks time arithmetic, and clips at sample
boundaries for initial trimming and segment splits. Borrowed output chunks expire
at the next mutation; consume them synchronously. It does not resample or correct
drift. Preserve the capture clock and gaps; never infer capture time from callbacks.

`src/core/recording_policy.zig` checks soft elapsed-time and byte thresholds. The
caller generates paths and requests a keyframe; it must not cut predicted frames.
It suppresses duplicate requests while a split is pending and ignores empty output.

`packages/audio/src/io/native_capture.{c,h,zig}` provides explicit Linux ALSA
S16LE capture using checked system headers and an opaque handle. Compile the C
source with the system compiler and link libasound. Rate 8–192kHz, mono/stereo,
block size 1–4096; nonblocking reads have a bounded timeout. It anchors the sample
clock from ALSA MONOTONIC timestamps, converts to Linux BOOTTIME, then advances
by sample count. Reported clock error is measured against ALSA status; >100ms
error, XRUN or device removal fails instead of silently dropping/recovering audio.
This is a new opt-in input backend; the older recorder abstraction is unchanged.
The existing simplified AAC implementations have not been adopted or represented
as a standards-verified capture encoder.

Call read and close serially. No queues, threads or implicit microphone access are
created by the Home adapter. Consumers must bound their own input/output queues.
Physical microphone latency, camera offset, suspend, drift and long recordings
still require hardware validation. No FFmpeg or Libav dependency is used.

Targeted Zig tests (0.15.2 and current Home toolchain):

```sh
zig test packages/video/src/core/pcm_timeline.zig
zig test packages/video/src/core/recording_policy.zig
zig test packages/video/src/containers/av_stream.zig
```

The Linux native smoke explicitly opens ALSA's `null` test device, never the
user's default microphone. See `.github/workflows/streaming-av.yml`.
