# Checked image regions

`ops/region.zig` supplies the existing `Region` type independently of image objects,
codecs and allocators. `crop.Region` and `image.Region` remain aliases with the same
u32 x/y/width/height fields and `isValid`/`clamp` methods.

`isValid(imageWidth, imageHeight)` rejects zero area, coordinates outside the image
and extents past its right/bottom edges. It checks coordinates before subtraction
and compares extents with remaining width/height. It never adds untrusted u32
coordinates to extents, so maximal invalid rectangles return false instead of
trapping in safe builds or wrapping in unchecked builds.

`clamp` retains its prior intersection behavior: coordinates are bounded to the
image and extents shrink to available space. A rectangle outside an image may
become empty; clamping does not imply validity. No pixels are read or allocated.

Standalone Debug/ReleaseSafe tests include exact maximal edges and 15,625 boundary
combinations, comparing validation to wider integer arithmetic and checking every
clamped result remains within its image. Run `zig test packages/image/src/ops/region.zig`.
