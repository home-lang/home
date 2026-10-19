# Packing captured image planes

`core/plane_pack.zig` provides allocation-free checked copies for capture buffers
whose row padding is not part of the image. It is also exported as
`video.plane_pack`.

- `rows(source, stride, active_row_bytes, height, destination)` copies active bytes.
- `packI420(planes, strides, width, height, destination)` packs separate Y, U, V
  planes into tight I420; each source plane can have its own stride.

Both validate sizes with checked arithmetic before writing. Final row padding
need not be present. I420 requires positive even dimensions. Truncated chroma,
undersized output and overflow are errors; the destination remains unchanged.
Sources remain borrowed, the caller owns the destination, and source and output
must not overlap. These helpers do not convert color, resize, or synchronize DMA.

zig-camera uses these helpers after beginning CPU access to a leased DMA buffer.
The camera ISP produces its low-resolution stream; packing only happens for an
explicit owned copy. A mapped view keeps the original padding and ownership.

Focused validation: `zig test packages/video/src/core/plane_pack.zig` on Zig
0.15.2 and Home's 0.17 development toolchain. This does not establish correctness
of the entire video package's unrelated codecs or conversion paths.
