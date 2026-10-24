# Imported capture planes and physical objects

`capture_backing.Owner` accepts `ImportFrame` records through `importFrames` or
`importFramesBorrowed`. Each frame has one to four explicit `{ fd, offset, bytes }`
planes. The provider checks descriptor identity, stable extent and access before
preparation. `capture_objects.Plan` normalizes those facts without acquiring any
resources or performing I/O.

Disjoint planes may refer to the same physical object using the same descriptor
or descriptor aliases. Such planes have one whole-object charge, one owned
provider resource and one mapped window spanning all their ranges. Plane views
retain their individual absolute offsets and lengths, including holes between
them. Overlapping ranges, inconsistent extents, SDK end-range overflow and
insufficient aggregate frame capacity reject before preparation. Physical objects
may not alias across independent frames, streams or retained cache entries.

The whole-object budget is reserved before duplication/mapping. Partially failed
preparation retires every acquired object and preserves its full charge until
physical cleanup succeeds. `reapPending()` retries that cleanup while preserving
idle source profiles. `trim()` additionally evicts idle profiles. A writable view
maps each physical object once even if several planes share it; physical CPU/DMA
coherency admission remains the consuming host's responsibility.

`planeCount` and `viewPlane` expose the prepared physical planes. Legacy `view`
continues to expose contiguous storage and rejects a multi-plane record. Existing
`importBuffers` constructs one-plane frames and remains compatible. The managed
RAM/DMA-heap paths keep their original single-resource views and capacities.

`importFramesBorrowed` and `importBuffersBorrowed` return the exact newly prepared
loan. An asynchronous factory must use that claim directly: importing into idle
storage then looking up a matching profile can select an older profile released
while the producer was preparing. Ordinary import methods release the new loan
into the cache for later configuration, while borrowed imports require one
explicit release/discard after all SDK/frame consumers retire.

The host serializes calls, validates pixel-format component minima and owns the
provider. Keep caller descriptors stable/inactive until synchronous import ends;
they remain caller-owned. The core implements no kernel allocator, GPU backend,
pixel conversion, hardware acceptance or camera frame timing.

The primary resource stays inline. Only frames with multiple physical planes
allocate a bounded metadata record, after full-byte admission and before any
provider import. Failed cleanup retains that record until all of its objects
retire; metadata allocation failure unwinds the reservation and earlier frames.
Managed and one-plane imported frames perform no metadata allocation.
`initWithAllocator` selects its allocator explicitly. `init` uses the provider
allocator when it exposes a `std.mem.Allocator` field, otherwise the page allocator.
The metadata allocator and backing provider must remain valid until owner close succeeds.
