# Scoped frame access

core/frame_access.zig supplies an allocation-free Gate for a caller that already
owns generation-checked frame leases. beginning(write, owners) prepares a new gate;
publish it only after a scoped mapping has successfully retained its own lease.
Readers may coexist; a writer requires exactly one external owner and no readers
or writer. An active writer prevents additional mapped/retained access.

ending(write) prepares retirement without mutating its source. The caller must
first validate the mapping's generation/ownership; this gate alone is not a token
registry. An incorrect access mode, missing owner or exhausted reader counter
rejects. The gate stores no pointers, threads, DMA state or view objects.

Use lease_pool for retained mapping owners and reserved producer capacity. DMA
permissions/fences and scoped view invalidation remain the caller's responsibility.
zig-camera uses this gate to retain read maps and exclusive writable maps until
the mapping closes, even if the original frame reference has already been released.
Tests cover reader sharing, writer exclusivity, stale modes, immutable rejection
and maximum counters on pinned and development Zig.
