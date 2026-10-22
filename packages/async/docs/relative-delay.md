# Relative idle intervals

`RelativeDelay` (`src/relative_delay.zig`) provides checked relative intervals in
one caller-supplied monotonic nanosecond clock domain. `arm(now, duration)` replaces
the current interval; overflow leaves the previous plan unchanged.
`remaining(now)` returns exact remaining nanoseconds or zero after the inclusive
deadline, records the last observation and rejects clock regression without
mutation. An unarmed observation rejects; `reset()` returns to unarmed state.
Zero durations and the full u64 range are supported without floating arithmetic.

The caller owns synchronization, actual clocks, platform timers, cancellation
and resource cleanup. This helper does not sleep, allocate, schedule work, measure
sensor cadence or derive timestamps. It implements an idle gap after completed
work; slow work does not create catch-up bursts against an earlier absolute epoch.
Explicit rearming starts a new interval in the caller's chosen clock domain.

Capture series can arm after a file operation joins, poll through a cancellable
host timer, and start the next capture only after the gap expires. Media PTS
rebasing and frame selection remain separate responsibilities. Standalone tests
cover late completion, exact boundaries, reset, regressions, atomic overflow,
zero duration and maximum integer clocks with pinned/development Zig.
