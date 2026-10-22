# Checked RGB16 word views

`Rgb16View` in `image.zig` reexports `ops/rgb16_view.zig`'s borrowed View.
The standalone module depends only on std. Layout `.rgb`/`.bgr` describes
memory word order; byte order is separately `.little` or `.big`. Unaligned
sources/destinations and odd/padded row strides are supported. Callers keep
source storage live and immutable for each synchronous call.

`View.init(data, width, height, stride, layout, endian)` checks positive
geometry, overflow, active row size and the final active span. Final padding
may be absent. `sample(x,y)` returns canonical RGB u16 words and requires
in-bounds coordinates. `convert(out,stride,layout,endian)` preserves every
sample, converting word/byte order without allocation. `toRgb8(out,stride)`
explicitly selects sample >> 8; it does not change gamma or color primaries.

Both writes preflight geometry, capacity and overlap before mutation. Exact
identity conversion is a no-op; other overlap rejects. Destination padding and
suffix bytes remain unchanged. No implicit precision expansion or quantization
is performed by convert. Existing raster_encoder Views accept the canonical
RGB16 result for lossless PNG16/TIFF16 encoding and explicit BMP high-byte output.

The two standalone tests cover all 16 source/destination layout/endian pairs,
low-bit boundary values, unaligned padded rows, short final spans, overflow,
identity, overlap and failure atomicity. Run Debug and ReleaseSafe tests on Zig
0.15.2 and development Zig. The image API adds an exported-alias test on Home's
development compiler; the hosted camera consumer additionally checks independent
PNG/TIFF decoders and bounded physical-word producer ownership.
