# Exact image orientation geometry

`ops/orientation.zig` provides an allocation-free `Transform` for exact rotations,
flips and transposition. `ops/transform.zig` exports it as `OrthogonalTransform`.
It leaves allocation, pixel format, strides, buffer lifetimes and synchronization
to callers, so the same coordinates work for RGB, planar chroma and Bayer samples.

`fromRotation(0|90|180|270, hflip, vflip)` rotates clockwise first, then applies
flips on the output axes. `fromBits(0..7)` describes source-axis flips followed by
transposition: bit 0 horizontal, bit 1 vertical, bit 2 transpose. These orders
matter for 90/270 degree rotations. `extent` swaps dimensions when transposed;
`sourcePoint` inverse-maps a checked output coordinate into its source image.
No multiplication of width and height is needed by the mapping itself.

`orientation` and `fromOrientation` map libcamera's eight named Orientation
values, including Rotate90=8 and Rotate270=6. Do not assume that numeric ordering
describes clockwise angles, or write the value into an EXIF tag on pixels which
have already been physically transformed. Camera format negotiation is still
responsible for determining the orientation actually produced by hardware.

`tile(T, input, sourceExtent)` transforms a repeating 2x2 tile without reading
pixels. It accounts for source dimension parity, so CFA colours and per-site
black levels preserve phase for even, odd and single-pixel dimensions. The caller
must separately validate output sample storage and any subsampling constraints.

Tests check bijections for all eight transforms over rectangular/odd/singleton
dimensions, explicit clockwise corner mappings, output-axis flip composition,
tile phases, invalid inputs and maximal coordinate arithmetic. zig-camera reuses
this module for C/Bun transform admission and synthetic stream generation. The
module is not a camera driver, software fallback policy or image ownership API.

## Checked pixels and public Image operations

`oriented_pixels.zig` reuses `Transform` for exact gray/RGB/RGBA8/16 raster copies.
`info` validates dimensions/strides and reports compact output geometry/size;
`into` validates source and destination extents and rejects all overlap before
writing. Destination padding is untouched. `copy` allocates an independent packed
`PixelView.Owned` through the caller's allocator. Row copies cover identity and
vertical flips; other orientations move whole pixels, preserving low words,
channel order, endian and straight alpha without reading them as eight-bit colors.
The helper imposes checked machine arithmetic and existing positive i32 geometry;
hosted applications must impose their own allocation/admission limits.

Public `Transform.orthogonal`, `rotate`, `flip`, `flop`, `flipInPlace` and
`flopInPlace` now preserve native words and indexed palette indices. Allocating
operations deep-copy palettes and animation frames, preserve loop counts and
frame timing/disposal/blend, and transform subframe rectangles with the canvas.
Nullable full-canvas frame dimensions retain their meaning after transposition.
All frame geometry is checked before allocation or mutation; existing void
in-place APIs leave all owners/pixels unchanged on invalid geometry. These
operations permute pixels rather than compositing frames. General affine and
arbitrary-angle resampling are separate policies; they are not covered by this
native-precision claim.

Nine portable raster/geometry tests cover all eight transforms with padded,
unaligned, singleton, odd, gray/RGB/RGBA8/16/endian samples, invalid spans,
pre-write overlap rejection and allocation cleanup. An independent C reference
checks 480 fixtures after source retirement. Development-compiler Image tests
exercise palette/animated rectangle ownership, native words, in-place equivalence,
late invalid frames and all allocator failure points; an external public Image
API test checks the original low-word regression. Dedicated entry points ensure
these tests are actually discovered, rather than relying on a filtered image-root
command that may omit lazy transform imports. No device/codec performance or
camera hardware claims follow from these software checks.
