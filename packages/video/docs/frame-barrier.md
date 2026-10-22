# Frame selection barriers

core/frame_barrier.zig provides an allocation-free Gate for a serialized capture
consumer. It owns counters and selection policy; it retains no frame, starts no
thread and does not change delivery to other consumers.

Set remaining to a bounded u32 drop count and after_ns to an optional inclusive
timestamp threshold. observe(event, sensor_ns, exposure_us) rejects duplicate or
older completion identities, drops the configured number of distinct requests,
then accepts the first qualifying request. An accepted gate is terminal. Use a
nonwrapping completion identity, not a camera's wrapping hardware sequence.

Timing thresholds and sensor timestamps must use the same clock. The default
subtract_exposure policy compares max(0, sensor_ns - exposure_us * 1000) to the
threshold. This conservative guard matches Picamera2's flush selection formula;
it is not a calibration or a redefinition of a sensor's timestamp semantics.
Set subtract_exposure=false for a direct sensor timestamp threshold. Missing
required timing returns an error without consuming a frame/drop or mutating the
gate. A drop-only gate does not require timestamps or exposure metadata.

The caller must still deliver rejected requests to recording/preview and release
its owner normally. Cancellation discards the gate, with no hidden frame to drain.
Tests cover exact boundaries, duplicate/out-of-order observations, missing timing,
drop-only selection, immutable terminal acceptance, maximum counters and saturated
subtraction. zig-camera uses this policy in its native capture filter ABI and Bun
capture jobs, without implementing a second selection counter in TypeScript.

Set require_ready=true and use observeReady(event, sensor_ns, exposure_us, ready)
to require explicit per-observation readiness in addition to the existing drop
and timestamp criteria. False or missing readiness waits; it is never inferred
from timestamps or a previous observation. Repeating a pending completion with a
new ready value cannot qualify that same completion. Required timing is checked
before mutation, distinct drops are consumed first, then timing/readiness select
the first qualifying request. Terminal acceptance remains immutable. The legacy
observe method supplies absent readiness, so it cannot bypass require_ready.

This supports software-sync capture selection when a camera's own algorithm
reports readiness. It does not synchronize devices, estimate clock offsets or
establish physical exposure alignment. The caller owns those algorithm and clock
contracts and associates readiness with the exact request whose event is passed.
