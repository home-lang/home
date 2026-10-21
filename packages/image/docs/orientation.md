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
