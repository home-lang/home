# Processed-stream alignment

`core/stream_alignment.zig` exposes `aligned(width, height, layout, profile,
optimal)` with u32 extents. It returns a Plan containing rounded dimensions and
their width/height alignment quanta. It never enlarges an extent, allocates,
changes pixels or negotiates a hardware stream.

Explicit profiles follow Picamera2's processed-stream recipes: VC4 uses a base
width quantum of 32 pixels and PiSP uses 64. `packed_pixels` uses the base quantum;
`planar420` doubles it so half-width chroma planes retain the base alignment;
`wide` halves it for four/six-byte packed formats. Height rounds down to a
multiple of two. With optimal=false, every layout/profile uses a width quantum
of two. The caller classifies formats and selects the actual deployment profile.

Zero inputs reject. A positive extent that would round to zero rejects with
EmptyAlignment instead of silently becoming a backend's automatic/default size.
Callers preserve explicitly automatic dimensions outside this primitive. Raw
sensor modes are not processed output geometry and should not be changed by a
configuration alignment helper.

The implementation uses subtraction/remainders, avoiding alignment-up overflow
at u32 limits. Tests cover exact VC4/PiSP recipes, planar chroma, minimum/tiny
geometry, monotonic shrinkage, idempotence and maximum unsigned extents. The
caller still validates pixel-format support, dimensions, negotiated strides,
buffer sizes and ownership against its actual backend. Planning is not capture,
zero-copy, bandwidth or performance evidence.
