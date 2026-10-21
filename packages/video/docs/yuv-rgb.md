# Checked strided YCbCr conversion

`core/yuv_rgb.zig` converts borrowed RGB24 and planar I420 without allocating.
`Conversion.init(matrix, range)` precomputes fixed point coefficients for BT.601,
BT.709 or BT.2020 non-constant luminance with full or limited range. Chroma uses
224 code values for studio range and 255 for full range, centered at 128.
It converts encoded R'G'B' values; transfer functions and primaries are not changed.

`decode420(view, conversion, out, stride)` checks each source plane and the RGB
output before writing. I420 planes have independent strides. Final-row padding
need not be present. `encode420(rgb, width, height, stride, planes, strides,
conversion)` averages all four pixels for each chroma sample. Both reject empty
or odd dimensions, short planes, and short strides. Destination padding is left
unchanged. Callers must synchronize access, retain source/destination ownership,
and provide non-overlapping source and destination storage.

The public `pixel_convert` RGB24/I420 paths use this helper. Other supported
8-bit pixel layouts share its pixel matrix operations. This fixes doubled chroma
in the old YUV-to-RGB path and halved chroma in its inverse. Generic subsampled
layouts beyond RGB24/I420 still use their existing pixel sampling policy.
The codec `rgb_i420.convert` remains its existing integer limited-BT.601 recipe;
its rounding and recording behavior are unchanged.

Tests use external color-vector calculations, full/studio black and white,
all three matrices, a floating reference grid including clipped values, padded
planes, missing final padding, chroma averaging, and rejection before writes.
Run `zig test packages/video/src/core/pixel_convert.zig` in Debug and ReleaseSafe.

`core/yuv_remap.zig` maps planar I420 directly between BT.601/709/2020 matrices
and full/studio ranges. It allocates no RGB intermediate and does not clamp
through RGB before remapping. The common same-matrix path scales each plane
independently; identity preserves all 256 codes, including footroom/headroom.
General remapping uses one affine luma transform per pixel and one chroma transform
per 2x2 block. Both input and output planes are checked before writing, with
independent strides and no destination padding writes. Primaries and transfer
functions must match: YCbCr matrix conversion alone does not change gamut/gamma.
The destination must not overlap the source. Reference tests compare unclipped
floating calculations, known full-to-studio values, clipping, and rejection.
