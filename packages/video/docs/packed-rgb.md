# Checked packed RGB rows

`src/core/packed_rgb.zig` provides allocation-free borrowed views for memory-order
RGB, BGR, RGBX, BGRX, RGBA, BGRA and ARGB. The names are byte layouts, not FourCC
names. X is unused padding: reads produce alpha 255, and conversions that write
X produce 255. Alpha layouts retain straight alpha without premultiplication.

`View.init(data, width, height, stride, layout)` checks positive geometry, integer
overflow and the last active row, permitting absent final padding. `convert`
checks the whole destination and rejects source/destination overlap before any
write. Exact pointer/stride/layout identity is a no-op. Output row padding and
suffix are untouched. Caller retains both buffers and serializes access.

The public `pixel_convert.convertInPlace` packed RGB routes use this helper,
including equal-format copies with independent strides. This replaces unchecked
per-pixel reads and full-slice equal-format copies. Other format families keep
their existing dispatch and are not made universally bounds-safe by this change.
No allocation, camera, kernel, renderer or codec is needed for the helper.

Tests cover all 49 layout pairs, opaque X, retained alpha, padded/unaligned rows,
truncated final rows, both overlap directions, exact identity and geometry
overflow. The public converter also checks equal-layout padding and transactional
failure. Physical camera negotiation and throughput require separate acceptance.
