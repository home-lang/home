# Persistent capture allocation policy

`core/capture_allocation.zig` supplies bounded ownership policy for a host's
persistent camera buffers. It reuses `owned_admission.Registry` for exact byte
reservations and `lease_pool.Pool` for exclusive generation-checked checkouts.
There are no allocation, kernel, device, mapping, synchronization or I/O calls.
It is independently usable with Zig 0.15.2 and current Home development Zig.

`Layout.init` copies the full camera identity and up to three negotiated stream
descriptors. Reuse requires exact camera identity, stream order/count, dimensions,
stride, format, modifier, visible frame size, backing allocation size and buffer
count. Unused storage is normalized; equality never depends on padding, labels,
hash collisions or borrowed strings. The host fixes its backing provider for the
cache's lifetime and derives the layout from actual negotiated configuration.
At most 64 buffers per stream and 64 cache entries are admitted. Runtime entry and
aggregate backing-byte limits can be smaller. Checked multiplication/addition
rejects overflow before admission. Set each stream's `allocation_bytes` to the
actual backing size, including provider page rounding, before checkout.

The host serializes every access and keeps resource owners in storage indexed by
the checkout slot. Do not copy a live cache. A fresh checkout reserves its entire
cost **before** physical allocation, with state `preparing`. Prepare every buffer
and mapping, then call `publish` to become `borrowed`. A reused checkout is already
`borrowed` and requires no physical allocation. The host releases its claim only
after every request, frame, exported descriptor and CPU mapping using that
allocation has retired. `release` changes the entry to `idle`, keeping all backing
bytes charged. One entry has one exclusive borrower; request-level sharing
belongs to the camera's existing retained-frame lease pool. Ordinary `checkout`
rejects a busy matching layout. Explicit `checkoutConcurrent` may reserve an
independent entry for the same layout when every matching entry is busy, for
example while a disconnected camera still owns frames and its replacement opens.
It prefers available matching idle storage even if an earlier match is busy.
Every such allocation stays within the same entry/byte bounds and never shares
backing with an active borrower. Retirement remains entry-generation checked.

Eviction is explicit. `oldestIdle` selects the oldest released idle entry;
`retireIdle` makes it unavailable and returns a retirement ticket. Cleanup destroys
each host resource, clearing only successfully destroyed owners. Call
`finishRetirement` only after all cleanup succeeds. An error keeps the entry
`retiring` and fully charged; retry using the same ticket. There is deliberately
no operation to return partly destroyed storage to the reuse cache.

Failed preparation follows the same cleanup contract through `failPreparation`.
It consumes the preparation claim and returns a retirement ticket without
releasing its budget. Retirement tickets use the existing allocation generation,
so cleanup remains possible even when new checkout generations are exhausted.
Repeated or stale release/retirement calls cannot consume another owner. Rejected
checkout never evicts another entry, including idle entries. The caller may retire
idle storage and retry; a live borrower is never an eviction candidate.

The byte ledger is a backing-storage bound, not a total process-RSS bound. Fixed
policy storage and host resource descriptors are additional bounded overhead.
The policy does not implement a DMA heap allocator, libcamera buffer import,
read/write mappings, coherency fences, worker pinning or a public camera allocator
API. `capture_backing.zig` now supplies owned RAM and Linux DMA heap resources;
see capture-backing.md. Camera hosts must implement and test their remaining
SDK/request/worker ownership boundaries
before claiming persistent camera-allocation support or physical speedups.

Run the standalone suite, including imported ownership tests:

```sh
zig test packages/video/src/core/capture_allocation.zig
zig test -O ReleaseSafe packages/video/src/core/capture_allocation.zig
```
