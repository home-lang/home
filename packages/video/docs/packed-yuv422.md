# Checked packed YUV 4:2:2

`core/packed_yuv422.zig` supplies allocation-free borrowed views for YUYV, YVYU,
UYVY and VYUY byte order. Each four-byte horizontal pair is logically Y0,U,Y1,V.
Width must be positive and even; height can be odd. Checked pitches and final
sample spans allow unaligned rows and absent final padding. Source/destination
ownership and synchronization remain with the caller.

`View.decode` writes RGB/BGR/RGBA/BGRA/ARGB/X layouts through Home's packed RGB
layout definitions; alpha/X is opaque. Chroma terms are shared across each pair.
`encodeRgb` accepts checked RGB layouts and computes U/V from both contributors
before rounding, rather than picking a corner. `View.copy` rearranges packed
layouts with independent pitches. Bounds/overlap failures occur before writes;
exact pointer/pitch/layout identity is a no-op. Padding and suffix are untouched.

`yuv_remap.Remap.apply422` writes I420 directly without RGB scratch storage. Each
source row's chroma contributes to that row's luma when changing matrices. Output
chroma uses the average of the two adjacent source rows, rounded half up, before
matrix/range remapping. It requires even height for I420 output and preflights
all source/output bounds and overlap. This is a defined box downsampling policy,
not a claim of arbitrary resampling or gamut/transfer conversion.

Public `pixel_convert` uses these paths for RGB to/from all four packed formats,
packed repacking, and packed-to-I420. The old packed output fallthrough wrote
nothing; it now initializes complete pairs. YVYU/VYUY are appended to the enum,
preserving existing IDs. Other YUV conversion routes keep their earlier behavior
and are not declared universally bounds-safe or correctly resampled by this work.

Tests cover layout pairs, independent floating color/chroma references, odd
height, padded/truncated/unaligned spans, opaque alpha, horizontal/vertical
averaging, overlap and unchanged output on failure. Pinned and development Zig
pass Debug/ReleaseSafe checks. No camera, kernel or allocator is needed for the
helper; physical camera format support and performance need separate acceptance.
