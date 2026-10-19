# Keyframe-aligned packet history

`core/packet_ring.zig` (exported as `video.packet_ring`) adapts the existing video
ring-buffer structure to encoded pre-roll: storage consists of one fixed byte
arena and a fixed entry array. Push copies borrowed packets without allocating
or blocking. The caller serializes all access and chooses timestamp units.

Byte capacity, frame capacity and duration are hard upper bounds. Eviction
removes dependent packets until the oldest retained packet is a keyframe.
If the limits cannot hold a GOP, history can be empty until the next key.
Oversized packets and non-increasing timestamps are rejected without modifying
retained history. Parameter sets/codec configuration belong outside the ring.
`entry` returns metadata; `copy` explicitly copies a retained payload to caller
storage, including when it wraps in the byte arena. Views expire on mutation.

Three standalone regression tests cover arena wrap, byte/frame/time eviction,
keyframe gating, rejected-input atomicity, zero capacities and allocator failure
cleanup. Tested on Zig 0.15.2 and the installed 0.17 development toolchain. This
focused validation does not establish correctness of the wider video graph.

zig-camera uses this module with Home JPEG/Matroska and x264/x265/fragmented MP4.
It retains compressed access units, without retaining camera DMA leases or raw
RGB frames. Explicit snapshots need scratch space for one largest retained
packet; remuxing starts with fresh codec headers and resets file timestamps.

For time-shifted streaming, `pushQueued` uses the same owned arena as a bounded
FIFO: it never evicts or filters dependent frames, and rejects full/oversized or
non-monotonic input without mutation. Use `ready(now, delay)` then `copy(0, scratch)`
and `pop()` to forward matured packets; `ready(null, delay)` flushes EOF. Queue
capacity must cover the delay. The caller controls keyframe starts and output
errors; a full FIFO must not silently discard encoded dependencies.

`cloneFrom(allocator, start)` owns a minimally sized copy of a selected suffix.
Serialize it with source mutation; the resulting data can move to a worker and
outlive the source. It copies wrapped bytes directly into a contiguous arena and
cleans up partial allocation failures. The module creates no threads or file I/O.
