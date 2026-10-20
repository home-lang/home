# Device identities across asynchronous reopens

core/device_identity.zig supplies Identity(capacity), an allocation-free owned
UTF-8 device key. init(bytes) rejects empty IDs, embedded NULs, malformed UTF-8
and byte lengths above capacity. The capacity is a byte bound, not a Unicode
character count. Caller input is copied and may be released or changed afterward.

bytes() borrows the owned key; matches(bytes) uses exact byte equality. IDs are
opaque: no trimming, case folding, path normalization, prefix matching or index
fallback is performed. copy(output) returns the exact byte count without adding a
terminator. A short output rejects without writing any prefix. The caller owns
synchronization, resource lookup and handle lifetime; initialize before use and
keep the identity unchanged while a borrowed slice is in flight.

A device's display name, truncated legacy field or enumeration index is not a
replacement for its backend ID. Resolve the original selector once, retain the
actual backend key, and use it to reopen the same device in a worker or rollback.
If the key is absent, report that failure instead of silently opening a different
device. The helper does not claim that a backend preserves IDs across hardware
changes, renumbering or reboot.

Tests exercise owned copies, exact case/whitespace/path matching, Unicode byte
boundaries, malformed input, bounds and atomic short copies on pinned Zig 0.15.2
and development Zig. zig-camera uses this helper for selected camera identity,
full-ID copy APIs and validation before asynchronous mode switches. Device lookup
and the camera-manager lease remain with its system backend.
