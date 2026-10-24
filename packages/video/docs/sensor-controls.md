# Sensor control helpers

Three allocation-free helpers support hosted sensor operations without importing
kernel or device ownership into the shared library. They are exported from
`video.zig` as `manager_gate`, `sensor_node` and `boolean_control` and support Zig
0.15.2 and development Zig.

`manager_gate.Gate` admits shared manager users or one exclusive mutation when
idle. Shared users pin a generation; the next shared/exclusive lifetime advances
it. Exclusive mutation excludes camera, discovery and watch entry. Wrong releases,
full counters, invalid state and exhausted generations preserve the state. The
caller serializes access, balances successful entries, pins any configuration
resources through manager destruction and performs cleanup after the last leave.
The helper does not create threads, reset an SDK manager or change environment.

`sensor_node.matches` associates a `/base/...` camera ID with borrowed Linux sysfs
`device/driver` and `device/of_node` link targets. It compares the complete device
ID and exact driver basename without path normalization or substring selection.
Driver matching works with built-in drivers lacking a `driver/module` link. Paths
are bounded at 4095 bytes and reject malformed UTF-8, NUL, empty components and
traversal in device-tree identities. `subdeviceIndex` admits canonical
`v4l-subdev0` through `v4l-subdev65535`, rather than assuming a fixed first sixteen
nodes. Filesystem traversal, unique-node selection, character-device identity,
open descriptors, ioctl ABI and permission/error policy remain with the caller.

`boolean_control.apply(io, requested)` preflights `io.validate()`, reads the old
boolean and skips idempotent writes. Otherwise it calls `io.write` once and reads
back even if the write reported failure. An `Outcome` retains previous/current
observations, attempted/successful-write flags and the original error; unknown
state stays null, and a successful write that did not take effect is an error.
`changed()` is null without both observations. The caller owns device exclusion,
SDK cache invalidation after a layout mutation, errno diagnostics and publication.
No automatic retry or speculative rollback is performed by this helper.

The tests cover shared/exclusive interleavings and overflow, Pi device-tree
layouts and adversarial prefix/traversal/driver matches, high subdevice indices,
idempotence, validation/read/write failures, partial writes, failed readback and
snapshot independence. These are ownership/IO-policy tests, not physical sensor,
HDR image quality or camera throughput acceptance.
