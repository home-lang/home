# Checked RGBA rows

`ops/rgba_view.zig` exposes `View.init(data, width, height, stride)` for borrowed
straight-alpha RGBA8 pixels. Width/height must be nonzero. Checked row, extent and
packed-size arithmetic rejects overflow, short strides and truncated last rows.
The last row needs only active pixels, not trailing stride padding.

`row(y)` borrows active bytes; callers keep the source live and immutable.
`packed_size` bounds a caller-owned allocation. `copy(output)` checks capacity and
source/output overlap before writing tightly packed active pixels. It preserves
channel order and alpha exactly and leaves excess destination bytes untouched.
No premultiplication, color conversion, scaling, allocation or renderer is hidden.
It can prepare owned pixels for a renderer's synchronous texture upload without
copying borrowed camera buffers or importing the image object/codec dependency tree.

Tests cover padded rows, transparent/intermediate/opaque alpha, overflow, truncation,
all overlap directions and adjacent nonoverlapping buffers. Run standalone Debug
and ReleaseSafe tests with `zig test packages/image/src/ops/rgba_view.zig`.
