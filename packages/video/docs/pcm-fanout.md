# Shared PCM sample windows

`core/pcm_fanout.zig` composes the existing `pcm_timeline.Queue` and
`packet_output.Slots`. It owns one fixed rolling PCM arena and bounded block
metadata, with an independent absolute sample watermark per consumer. Callers
serialize access; this helper has no capture device, clock thread or codec.

Create `Fanout(capacity)` with a caller allocator, sample rate, channels, maximum
frames and maximum blocks. Both bounds apply: small input blocks can exhaust
metadata retention before filling the sample arena. `push` copies each source
block once through the timeline's validated rolling path, preserving fractional
sample phase and timestamps. No payload allocation occurs after initialization.

`prepare(id, minimum, cut, chunks)` selects samples before cut, starting at the
consumer's last accepted sample end, or minimum for a new consumer. It preflights
descriptor capacity before writing views. The returned exact ticket reserves
borrowed slices: `push` rejects while any preparation remains live. Copy the views
into the codec producer's own bounded input storage before `finish(id, ticket,
true)`. Rejection/cancellation uses false and keeps the prior sample watermark.
It does not roll back a codec that already wrote media. Retirement cancels any
borrow and removes the consumer; stale tickets cannot affect replacements.

Advancing to the requested video cut would silently lose late PCM. Acceptance
therefore advances only to the end of samples actually returned. Empty windows
preserve the watermark. Separate last-cut tracking still rejects backwards cuts;
several video frames inside one audio sample interval may validly receive empty
batches. The timeline carries fractional 44.1 kHz phase across blocks and wrap.
Source gaps remain gaps; the helper does not resample or repair a capture clock.

A consumer whose watermark falls behind rolling eviction is quarantined, with an
overrun counter, rather than silently dropping PCM. `check(id)` detects this even
while a video producer is busy. `prepare` also checks new consumers against their
first requested minimum. Healthy peers remain active. Slow video consumers can
skip frames while accumulating continuous PCM within the configured retention
and their producer byte/descriptor budgets. Indefinite retention is unsupported.

Statistics distinguish frames admitted into producer copies, cancelled batches,
source frames copied into shared history and history eviction. History eviction
is not necessarily lost audio: healthy consumers may already own every sample.
Identities/tickets reject exhaustion, observation counters saturate, and all
payload ownership remains bounded. Device ownership, read budgets, per-consumer
failure handling, output drains and hardware drift validation belong to callers.

Standalone tests run on Zig 0.15.2 and Home development Zig in Debug/ReleaseSafe:

```sh
zig test packages/video/src/core/pcm_fanout.zig
zig test packages/video/src/core/pcm_fanout.zig -O ReleaseSafe
```
