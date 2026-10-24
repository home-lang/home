# Owned persistent capture backing

`core/capture_backing.zig` implements resource ownership around
`capture_allocation.Cache`. The owner is fixed-capacity, must remain at a stable
address, must not be copied while live, and requires caller serialization.
The portable owner and RAM provider support Zig 0.15.2 and current Home development
Zig. Native Linux UAPI translation has an explicit Zig 0.15.2 entry point,
`core/capture_host.zig`, backed by `capture_dma_heap.zig`. Newer Home Zig removed
`@cImport` and parses even unused conditional imports, so portable `video` imports
deliberately do not import that native entry, matching the existing KMS boundary.
It prepares every buffer before publishing an exclusive loan. A returned view is
borrowed and valid only while that loan remains held. The camera must retire all
requests, frames, exports, readers and writers before releasing it.

`Ram` uses a supplied allocator and explicitly supplies synthetic storage with
fd -1. It does not manufacture physical addresses or simulate DMA completion.
`LinuxHeap` opens a Linux DMA heap and requests owned close-on-exec read/write
DMA-BUF descriptors through `DMA_HEAP_IOCTL_ALLOC`. It rounds and charges backing
bytes using the actual system page size before any allocation. It keeps one
read-only shared mapping per buffer. An explicit writable view lazily creates a
separate read/write mapping, preserving original read pointers and permissions
across writable and read-only camera reopens. Both mappings persist until trim.

Default discovery tries `vidbuf_cached`, modern `default_cma_region`, then legacy
`linux,cma` under `/dev/dma_heap/`. Only absent/unavailable heaps advance discovery;
permissions and other failures are reported. A caller may select an explicit
single heap path in that directory. There is no fallback to ordinary RAM or the
non-contiguous `system` heap. The Linux kernel documents the modern CMA name and
older platform names in its [DMA heap interface](https://docs.kernel.org/userspace-api/dma-buf-heaps.html).
Actual camera import compatibility and physical performance require hardware
acceptance; successful heap allocation alone does not prove either.

Mapping is not CPU coherency admission. The host must still issue the appropriate
DMA-BUF CPU START/END fences and serialize readers/writers around every actual CPU
access. No image bytes are read or written by `LinuxHeap`. Camera SDK FD imports
must own duplicates, while the pool keeps its original descriptor and mappings.
Discard all SDK requests and imported buffers before releasing a pool loan.

`checkout` reports full admission without eviction. `checkoutEvicting` retires
oldest idle entries only when bounded admission is full; borrowed storage is
never an eviction candidate. The `Concurrent` variants can prepare independent
backing for replacement cameras while old loans survive, under the same budget.
`trim` retries pending retirement and frees idle storage, leaving borrowers live.
`close` returns Busy while any loan survives, trims storage and closes the provider.
The host must also prevent close while async opens/mode workers hold native pins.

Failed preparation retires every partially owned resource. Failed unmap retains
its pointer and FD for retry; successful earlier cleanup stays cleared. Linux
close errors consume descriptor ownership, including EINTR, and are reported
once; retry never closes a recycled FD number. A cleanup error retains the entry,
its retirement generation and its full byte reservation until a later successful
trim/close. No partly destroyed entry becomes reusable. A failed provider close
retains the host owner for retry, even when all buffer entries are already empty.

`allocations` counts successfully prepared buffers and `writable_maps` counts
created additional Linux write mappings, not attempted system calls. Cache
telemetry supplies preparations/reuses, admitted bytes and entry counts;
`cleanup_errors` counts failed resource cleanup attempts. These are ownership
measurements, not Pi throughput or acceleration results.

Standalone RAM tests inject every allocation failure, retain data and addresses
across 1,000 reuse cycles, and cover live-loan eviction/busy/stale-view cases.
The independent Linux C peer intercepts the actual libc/UAPI calls and uses real
memfd-backed shared mappings. Twelve scenarios validate flags, rounded sizes,
RO/RW aliasing, reuse, independent same-layout replacement loans, partial
allocation/map/unmap/close failures, cleanup retry and current/legacy discovery.
It is a Linux ownership test, not emulated or physical camera acceptance.
