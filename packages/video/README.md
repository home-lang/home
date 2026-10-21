
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
