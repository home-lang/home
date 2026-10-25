# Retained frame timestamp matching

`video.frame_match.choose(timestamps, tolerance_ns)` compares two through eight
unsigned nanosecond timestamps in one caller-established clock domain. It makes
no allocations, retains no frames and does not alter clocks or configure sensors.
The result reports the earliest/latest timestamp, exact skew and an eight-bit
replacement mask in caller order. Equality at the tolerance boundary qualifies.

A caller keeps one owned candidate per stream. When the result is unmatched,
release every masked candidate before acquiring its replacement. Masked samples
are strictly older than the latest candidate minus the tolerance. They cannot
participate in any later qualifying tuple if every source remains nondecreasing.
At least one candidate stays owned and each unsuccessful decision advances a
stream. The caller must reject timestamp regressions, bound acquisition and
join cancellation and cleanup; this policy supplies none of those owners.

Sensor first-pixel timestamps are comparable on a shared host clock. Comparing
these values does not establish overlapping exposures, external clock mapping,
physical sensor synchronization or image-quality/performance acceptance. Missing
timestamps must not be replaced by zero or a local delivery timestamp. Backend
readiness and exposure freshness are independent selection policies; existing
`frame_barrier` supplies those request-local gates.

Tests cover inclusive boundaries, unsigned endpoints, all three-stream values
0..15 against an independent widened pairwise distance reference, and streaming
intersection against exhaustive tuple existence for small monotonic streams.

The retained-export link probe in `tests/frame_match_freestanding.zig` links an
aarch64 freestanding ELF with the actual matching function reachable and no libc
or caller allocator. It was checked on Zig 0.15.2 and
0.18.0-dev.567+7f0281900 in ReleaseSafe. The ELF has no startup entry and is a
link probe, not a bootable Home OS image or physical hardware test.
