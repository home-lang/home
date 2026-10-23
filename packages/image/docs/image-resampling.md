# Checked integer image resizing

`formats/pixel_resample.zig` is a standard-library-only resampler over the shared
checked `pixel_view.View`. It borrows gray/RGB/RGBA8/16 in either byte order,
including unaligned/padded input. `resize` returns an independent `pixel.Owned`;
`into` writes caller storage with a checked stride, leaving padding untouched.
`checkedSize` checks output geometry and working-heap limits without allocation.
The allocator is injected. No threads, libc, codec or OS device owner is needed.

Nearest uses integer pixel-center selection. Bilinear, Home's existing
Mitchell-Netravali bicubic (B=C=1/3), Lanczos-2 and Lanczos-3 use normalized,
separable tables. Reductions widen the sampling window by the source/target
ratio; they no longer ignore most source pixels. Boundaries truncate the kernel
to valid samples and renormalize. These are explicit Home filter semantics,
not a promise of Pillow-identical samples. The old image operations used a
mixture of top-left, aligned-corner and pixel-center mappings and fixed windows.

Filtered RGBA is premultiplied while interpolating and returned as straight
alpha, preventing fully transparent RGB from bleeding into visible edges.
Samples round once at their native integer precision and saturate. Stored word
precision and endianness survive. No gamma, gamut or transfer conversion occurs;
callers needing linear-light resizing must convert explicitly. Same-size and
nearest copies preserve exact source bits, including hidden transparent RGB.

The default output bound is 256 MiB. The default working heap is 64 MiB, including
axis tables, one accumulated output row and a direct-mapped cache of at most
64 horizontal rows. There is no full floating-point intermediate image. Wide
reductions can recompute evicted rows; this bounds memory without claiming
uniform throughput. Limits are caller-configurable in Zig. Both source/target
spans, overlap, geometry and all scratch allocations are checked before the
first destination write. Failure retains the caller's original output. Identical
same-size no-op aliases are accepted; other overlapping spans reject.

`Image.PixelResample` exposes the module. `Image.Resize.resize` and mutating
`resizeNearest`/`resizeBilinear` now share it for all six integer formats.
Invalid geometry errors explicitly instead of silently doing nothing. Mutating
operations replace owners only after success. Indexed inputs expand through the
checked PNG/GIF palette path into RGBA8; that temporary expansion is separately
capped at 256 MiB. Animation resizing explicitly rejects instead of discarding
frames. Same-size cloning keeps frames and palettes. Fit-size arithmetic is
checked, and contain padding copies words at native precision; complete fit/
crop, animation compositing and further color semantics remain separate work.

The portable tests verify native-word means, alpha edges, source retirement,
byte order, padding, overlap/limits and every allocation failure. An independent
C long-double direct 2D reference validates 660 fixtures per compiler/build,
including single-axis images, enlarged/reduced/identity images and reductions
exceeding the 64-row cache. Nearest and identity are exact; filtered reference
comparisons allow one native integer unit for floating-point rounding. Pinned
Zig 0.15.2 and development Zig each pass Debug and ReleaseSafe. The public Image
API passes 167 development-Zig ReleaseSafe tests, including indexed and
transactional mutating resize. These are software checks, not camera quality or
physical hardware performance measurements.
