# Hosted POSIX shared-memory owners

`src/posix_shared_memory.zig` provides `Fd`, `Mapping`, `Region` and checked `Span`
for hosted Linux/Darwin callers linking libc. `io.PosixSharedMemory` exposes the
module on those targets. It has no Bun/JSC/runtime dependency and is not a
freestanding kernel/media implementation.

`Fd.duplicate` atomically duplicates a borrowed descriptor with close-on-exec.
`Region.create` creates an exclusive 0600 POSIX shared-memory object, immediately
unlinks its random name, sizes it, and maps it shared/read-write. Newly allocated
bytes are zero. Linux entropy comes from getrandom; Darwin uses arc4random_buf.
Interrupted unlink is retried. The descriptor remains close-on-exec. Region and
mapping owners require explicit close and must not be copied as independent
owners. Closing a descriptor does not unmap existing views.

`Mapping.init` validates length/used/offset arithmetic and caller limits, checks
backing extent before mapping, and handles unaligned file offsets using the
actual page size. Darwin's reported shm extent may be rounded to a page.
Device descriptors with no reported extent are explicitly rejected by this
mapping helper; this is not a universal DMA-device mapper. `extent` uses each Zig
standard library's target ABI declarations (including Linux statx on development
Zig), without hardcoded stat layouts or @cImport. The pinned Linux fcntl fallback
is the verified UAPI F_DUPFD_CLOEXEC command omitted by that standard library.

Writable views require a writable mapping. No view may be used after unmapping;
consumers must be joined before owners retire. The helper does not supervise
processes, transfer descriptors, provide acknowledgements or retain device frames.
A raw integer fd is not an inter-process transfer and is not a camera lease.
Kernel/device and consumer ownership must remain explicit in the application.

The companion `video/core/owned_admission.Registry.resize` reconciles an existing
reservation with an exact payload cost without changing its identity, count or
cleanup fence. Reserve a bounded preparation allowance first; resize before
allocating the payload. Rejected growth/stale tickets preserve ownership and
accounting (apart from the rejection counter).

Two mapping/descriptor tests and four admission tests pass on pinned Zig 0.15.2
and Home's development Zig in Debug and ReleaseSafe. Both compiler lines also
cross-build the tests for Linux x86_64/aarch64. zig-camera separately checks real
exec/SCM_RIGHTS transfers, read/write access, joined retirement and failed staging
writeback against its native export owners. Those checks do not establish Pi
DMA acceptance, camera throughput or a complete process-pool implementation.
