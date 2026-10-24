
### Indexed recording paths

`core/recording_path.zig` validates one `{index}` or `{index:06}` field and
formats a `u64` into caller-owned, NUL-terminated storage. Padding is bounded at
128 characters, maximum indices never truncate, malformed braces/NUL bytes fail,
and paths remain bounded at 4096 bytes. Use exclusive output creation and
identity-checked cancellation cleanup in the owner; this helper performs no I/O.
It complements `recording_policy` and `output_recovery` for async recording.

### Independent frame consumers

[Bounded frame fan-out](docs/frame-fanout.md) reuses `packet_output.Slots` for
never-reused consumer identities and exact in-flight tickets. Wait/drop policies,
retirement, failure isolation and saturating telemetry store no source frames or
PCM. Existing producer owners retain their own byte/count limits and cleanup.

### Shared PCM consumers

[PCM fan-out](docs/pcm-fanout.md) combines the existing sample timeline and stable
slots with independent watermarks and exact preparation tickets. One bounded
history can supply several codec producers without extra capture cursors. It
preserves fractional sample phase, never advances past missing audio, and
quarantines history overruns without affecting healthy consumers.

### Block I420 decoding

[Checked YCbCr conversion](docs/yuv-rgb.md#shared-chroma-decoding) reuses each chroma
pair across its four luma pixels while preserving legacy fixed-point bytes. The
standalone benchmark retains the old loop, raw local timing rows and checksum
checks; physical camera performance remains a separate acceptance task.

See [color descriptions and negotiation](docs/color-description.md) for checked
requested/effective/actual metadata and strict processed-stream policy.
The [native video adapter](docs/native-video.md) also accepts explicit ISO color
tags for AVC/HEVC VUI and MP4 nclx, with legacy defaults preserved and independent
SPS/container signaling tests. Callers remain responsible for matching samples.

[Sensor control helpers](docs/sensor-controls.md) provide portable shared/exclusive
manager admission, exact Linux device-tree sensor association and observed
boolean-control outcomes. Hardware IO and manager lifetime remain caller-owned.
