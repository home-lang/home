# Shared capture leases

lease_pool.Pool(resources, references) supplies allocation-free resource ownership
with a distinct generation-checked token for every reference. acquire reserves a
previously unleased resource. retain issues another token for the same resource.
release retires exactly that token and reports whether the final owner left.

Releasing a parent token never invalidates a retained token, and a stale/double
release cannot decrement another owner's reference count. Tokens encode their
reference-table slot for constant-time lookup; generation exhaustion rejects
without wrapping. Failed acquisition/retention leaves the source unchanged.

The caller owns synchronization, resource mappings, DMA synchronization and
recycling. Keep the resource mapped until the final release. Consumers must use
tokens with the pool that issued them. Pools are bounded; callers can reserve
reference-table capacity for other physical resources before admitting retains.

Tests cover parent release, distinct children, slot reuse, stale tokens, atomic
limits, generation exhaustion and one-slot/non-power-of-two configurations.
zig-camera reuses this helper for retained completed requests and only ends DMA
access/requeues a request on its final reference.
