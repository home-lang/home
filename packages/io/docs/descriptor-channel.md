# Local descriptor records

`DescriptorChannel` (`src/descriptor_channel.zig`) provides connected Unix
datagram pairs, nonblocking atomic `send`, and explicitly owned `Received`
records for hosted 64-bit little-endian Linux/Darwin with libc. It has no VM,
runtime, thread, allocator, process supervisor or userspace queue dependency.
`io.DescriptorChannel` exposes it alongside `io.PosixSharedMemory`.

Each record has 1–4096 bytes and up to 16 descriptors. Sending borrows fds for
the call; success duplicates them into the peer queue, and `WouldBlock` leaves
the complete record unsent. EINTR retries the same atomic datagram. Full queues
report `WouldBlock` (including Darwin ENOBUFS). Pairs request 64 KiB send/receive
socket buffers; kernels may round/account this differently. The caller supplies
the event-loop readiness/retry/deadline policy and limits outstanding records.

Receiving returns a fixed-size owner. `take(index)` moves one fd out; `close`
closes remaining fds once and can be repeated. Truncated payload/control,
unknown ancillary types, excess descriptors and CLOEXEC failures reject the
record and close all delivered descriptors. Receive-buffer bytes are invalid
on error. Closing endpoints discards queued records according to the OS; an
empty datagram queue is not a reliable peer-exit signal. Supervise separately.

Linux creates endpoints and receives fds atomically CLOEXEC. Darwin sets
FD_CLOEXEC immediately after creation/receive; callers must serialize concurrent
exec/inheritance with those operations there. Socket-specific options suppress
SIGPIPE without changing process-global signal handling. Owners are move-only
by convention; calls must be serialized.

Pinned Zig lacks target cmsghdr definitions. The helper uses the verified Linux
64-bit little-endian glibc/musl and Darwin layouts/alignment (Darwin ALIGN32).
Independent C CMSG_* interoperability in zig-camera checks both directions
across exec. Other OSes, 32-bit and big-endian ABIs are unsupported.

The receiving ancillary buffer accommodates 512 fds despite the public limit
of 16. A local macOS regression initially transferred 24 rights into a 16-fd
buffer and left eight installed fds inaccessible. XNU externalizes rights
before copying control bytes. Its [UIPC_MAX_CMSG_FD bound/externalization](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/uipc_usrreq.c)
and [control copying/bounds](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/uipc_syscalls.c)
were inspected. Receive the complete permitted rights record, then close rights
above the application limit. Linux's [SCM_MAX_FD=253](https://github.com/torvalds/linux/blob/v6.12/include/net/scm.h)
also fits. No kernel source is copied.

Three channel tests plus two imported shared-memory tests cover aliasing,
offsets, CLOEXEC, move/close, queue saturation/drain/retry, peer closure and
repeated excess-rights/truncated-payload rejection with unchanged fd counts.
All pass on Zig 0.15.2 and Home's development compiler in Debug/ReleaseSafe;
both compiler lines cross-link Linux x86_64/aarch64 tests. The consumer separately
tests C/Bun exec, metadata/mapping admission and camera retirement after ACK or
verified exit. These checks do not establish physical Pi DMA or throughput.

This is a primitive for cooperating local processes. Passing rights is not a
device lease; readonly flags are not an adversarial sandbox. Extent checks
require owners not to truncate backing files while mapped. Applications own
acknowledgements, generation routing, cancellation, process joining and device
lifetime. Kernel/file-description costs are additional to explicit record bounds.
