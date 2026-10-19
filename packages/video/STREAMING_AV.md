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

`Queue.pushRolling` adds bounded circular PCM history. It validates the entire
input before evicting whole oldest blocks to meet both sample and descriptor
limits. `retention_floor` reports the end of the discarded prefix. Invalid or
oversized blocks leave history untouched. `window(minimum, cut, cursor)` reads
non-destructively with sample-exact clipping, including arena wrap. Each replay
uses a fresh cursor; chunks and cursors expire on mutation. `Chunk.end_ns` uses
the original block clock to avoid accumulating fractional sample rounding.
Consumers can align an encoded keyframe ring to the PCM retention floor and
replay separate snapshots without consuming live audio. If eviction passes a
live consumer's watermark, report loss rather than silently producing a gap.
No encoder, thread or file I/O is performed by these history methods.

`Queue.cloneWindow(allocator, minimum, cut)` freezes just the selected sample
window into independent storage. It preserves capture timestamps and sample phase,
handles a wrapped source block even when all 4096 descriptors are occupied, and
frees partial allocations on failure. The source is unchanged. Serialize cloning
with source mutation; after return the copy may move to an independent worker and
outlive the source. No audio encoder or worker runtime is imported by this module.

Contiguous blocks carry a fractional sample-clock numerator as well as the
integer nanosecond timestamp. At 44.1 kHz, independently flooring every block
can otherwise move an exact segment cut by one sample. `take`, rolling windows,
wrapped chunks and frozen partial windows preserve this phase. A timestamp gap
starts a new phase origin; samples are never synthesized to fill it. `Chunk.phase`
is the fractional numerator in units of `1 / sample_rate` nanoseconds. Keep
source timestamps on a cumulative sample clock rather than rounding each block's
duration independently.
