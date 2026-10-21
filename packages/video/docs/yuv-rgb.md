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

## Shared chroma decoding

I420 decoding now computes each chroma pair's channel contributions once for its
2x2 luma block. All four pixels keep the original fixed-point rounding and clipping;
source/destination ownership and non-overlap requirements are unchanged. There is
no allocation or intermediate image. The per-pixel `Conversion.toRgb` API remains
unchanged. An exhaustive block test checks 75,264 blocks (301,056 pixels) against
that legacy path across all six matrix/range combinations and preserves padding.

The reproducible [benchmark](../benchmarks/i420-decode.zig) retains the old loop,
uses identical deterministic padded 640x480 planes, warms each path, alternates
execution order, checks complete output equality and records checksums. Run with
the camera's pinned Zig 0.15.2; the helper itself also passes development-Zig tests.

```sh
zig build-exe -O ReleaseSafe --dep yuv -Mroot=packages/video/benchmarks/i420-decode.zig -Myuv=packages/video/src/core/yuv_rgb.zig -femit-bin=/tmp/home-i420-decode
/tmp/home-i420-decode 2> /tmp/i420-decode.csv
```

Machine-local macOS/arm64 runs targeted macOS 15.0 with `-lc`. Three batches of 20
frames per method/matrix/range are retained as raw rows:

- [ReleaseFast](../benchmarks/i420-decode-releasefast-local.csv): ratios of median
  legacy/block batch times range from 1.77 to 1.89.
- [ReleaseSafe](../benchmarks/i420-decode-releasesafe-local.csv): ratios range from
  0.94 to 1.46, including a small regression for full-range BT.709 in this run.
- [Earlier concurrent ReleaseSafe run](../benchmarks/i420-decode-releasesafe-concurrent-local.csv):
  recorded while compiler jobs ran, retained to expose timing variance rather than
  used for the comparison above.

These are shared-development-host samples, not Pi measurements, a latency guarantee,
a camera FPS result or a Picamera2 comparison. Build mode and workload matter;
there is no claim that every conversion/target becomes faster. CI correctness uses
pixel equivalence and bounds tests rather than timing thresholds.
