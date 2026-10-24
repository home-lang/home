
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

[RTP sending primitives](docs/rtp-sending.md) provide bounded allocation-free
AVC/HEVC/AAC packetization, exact clock scaling and compound RTCP reports.

`SocketWriteCursor` (`core/socket_write.zig`) provides allocation-free checked
progress for hosted media byte sinks. TCP accepts prefixes; raw UDP accepts a
whole bounded datagram or zero for backpressure. A cursor owns neither bytes nor
sockets. Empty inputs, u64 endpoints, invalid advances and short final chunks are
covered independently; transports and deadlines remain the caller's job.

`ByteTail` (`core/byte_tail.zig`) retains a fixed caller-owned binary suffix
without allocation; its exact u64 total includes discarded bytes. Append/copy
preflight state, overlap and counter overflow before mutation. It supports zero
capacity for drain-only diagnostics.

`process_output_wire` defines 32-byte inherited-fd readiness/result/problem
records. A problem with consumer PID zero proves failure/cancellation before a
successful fork. Other failures are followed by a joined consumer result.

The optional hosted POSIX supervisor is built with the native ABI profile:

```sh
zig build-exe -lc -O ReleaseSafe packages/video/src/process_output_host.zig -femit-bin=video-output-host
bun packages/video/tests/process_output_host.ts "$PWD/video-output-host"
```

Use Zig 0.15.2 for this standalone tool. The pure diagnostic/framing helpers also
run on current development Zig. The host expects media on fd 0, consumer output
on fd 1/2, and a private inherited stream control socket on fd 3. Invoke as
`video-output-host grace-ms -- executable argv...`; no shell is involved. Parents
must drain stdout/stderr concurrently and retain ownership until actual exit.
Control data/EOF cancels independently of stalled media input. Exec readiness is
confirmed by a close-on-exec pipe. Before reaping the leader the host terminates
its remaining group while the leader PID/PGID is still reserved; Linux also
adopts/reaps group descendants. A disconnected parent is handled by the same
control-fd path, and the Linux direct consumer additionally has PDEATHSIG.

These are hosted stdlib I/O helpers, separate from freestanding media and HomeOS
kernel drivers. Consumers that deliberately escape their process group, a
hard-killed supervisor and broader process-tree recovery need separate policy;
this interface is not a sandbox. No media encoder/muxer or external media tool
is invoked by the supervisor.

### Forward-only AAC fragmented MP4

`mp4_stream.Writer.initAvForward` / `initAvForwardWithColor` use the same
AVC/HEVC/AAC sample descriptions and fragments as the patchable writer. Supply a
finite borrowed byte arena, then call `startAudio(first_pcm_offset_us)` once
before feeding AAC access units. Video fragments wait in that arena until the
actual PCM start is known. Overflow is terminal and emits no partial initial
movie; callers choose the capacity and their output failure policy. The arena
must outlive the writer and must not overlap samples. The deferred prefix is released in writes of at most 64 KiB so a large
startup arena does not become a single oversized downstream queue entry. No
allocator, seek or file-sized buffer is introduced.

The initial empty edit places late audio on the movie clock; the following
media edit skips encoder delay and has duration zero to span subsequent
fragments. `finish` still validates PCM/encoded counts and shortens the last
fragment to exclude padding, but never patches bytes or finite header durations.
For an empty PCM session, bind offset zero before draining the encoder. Decode
all priming access units before applying the edit; discarding them before the
decoder loses state needed for the first audible samples.

This is general fragmented ISO BMFF with two edits. It does not promise the
single-edit CMAF/MSE profile or arbitrary player interoperability. A network
receiver must preserve fragment bytes and honor the edit list and final sample
duration. See ISO/IEC 14496-12 section 8.6.6 and the
[W3C ISO BMFF byte-stream note](https://www.w3.org/TR/mse-byte-stream-format-isobmff/)
for the distinction from its required single-edit subset. Apple's
[AAC encoding background](https://developer.apple.com/documentation/quicktime-file-format/background_aac_encoding)
explains why priming and remainder samples must be excluded from presentation.

Run `zig test packages/video/src/containers/mp4_stream.zig` and the public API
fixture `packages/video/tests/mp4_forward.zig`; CI checks Debug/ReleaseSafe on
pinned and development Zig across macOS, Linux x86_64 and Linux ARM64.

The supervised-output child verifies its actual process group if its redundant
`setpgid(0, 0)` fails. The parent can already have established the same group;
startup proceeds only when `getpgrp() == getpid()`. An unowned group remains a
terminal setup error, with the original errno preserved. The regression consumer
`tests/process_output_consumer.zig` independently checks group identity after exec,
echoes bounded media through EOF, and is exercised through 50 joined startups by
`process_output_host.ts` when passed as its second executable argument. The native
host CI compiles and runs both on macOS and both Linux architectures.

For hosted clients, invoke `grace-ms --control-fd4 -- executable argv...` with
independent inherited stream sockets: fd 3 carries only readiness/problem/final
exit records to the parent, while fd 4 receives only cancellation data or EOF.
The consumer inherits neither. This keeps a late unread cancellation byte from
sharing the stream carrying final joined-exit proof. Parents must drain fd 3 and
join both channels, diagnostics and the host process. The legacy CLI without the
flag retains duplex fd 3 for existing standalone clients. Record framing remains
ZCO1 with at most two records. Terminal problem/result records require no further
cancellation command from the parent.

The acceptance harness runs both CLI modes and 50 native group/descriptor checks
per mode. Split mode also receives late cancellation after failed exec. Its
optional third executable is `tests/process_output_terminal_fixture.zig`, compiled
with the `wire` module pointing to `src/core/process_output_wire.zig`; that peer
joins a real child, sends a problem, waits for cancellation without consuming it,
then sends final proof before exit. Twenty-five such cases verify independent
proof delivery. Native CI supplies both consumer and terminal fixture explicitly.

In the real failed-exec/late-cancel case, the joined consumer can exit 127 or be
terminated by the supervisor's TERM/KILL before reaching `_exit`. The harness
accepts those documented outcomes while requiring the final result and dead
consumer. The controlled terminal fixture has already reaped its child before
reporting the problem, so its result must remain exactly 127.

Read-only Linux display catalogs are available through
[`kms_discovery_host`](docs/kms-discovery.md). The bounded portable collector
retains connector/mode/CRTC/FOURCC identities and per-card failure diagnostics;
the hosted adapter closes all query FDs and never acquires display ownership.
