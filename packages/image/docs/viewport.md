# Checked display viewports

`ops/viewport.zig` exports an allocation-free `Plan` for source dimensions, output
dimensions, independent image/overlay orientations, aspect fitting and an optional
overlay rectangle. It imports the existing `orientation` and `region` helpers;
no renderer, window, image object or pixel storage is owned.

The image orientation first determines logical display dimensions. With aspect
preservation, integer fitting centers the image in the output and rounds the
constrained axis down, with a one-pixel minimum. Without it, the image fills the
output. All dimension products use u64 and support maximal nonzero u32 inputs.
Empty dimensions and unknown orientation values reject.

An optional overlay rectangle must fit entirely within the post-transform logical
image. Its half-open edges map to the fitted image with integer floor rounding;
adjacent rectangles share edges without seams. A subpixel rectangle may map to
zero pixels and should be skipped by the renderer. The default overlay fills the
fitted image. Validation occurs before returning any plan.

`image_uv` and `overlay_uv` give independent TL/TR/BR/BL texture coordinate pairs.
They use Home orientation values, including libcamera's clockwise naming; do not
substitute EXIF orientation numbers. Overlays are screen-oriented by default when
passed identity orientation, even when the image is flipped or rotated.

Tests cover letter/pillar boxes, stretching, placement, all 64 orientation pairs,
maximal arithmetic, subpixel rectangles and rejection. Dependency tests retain
checked region bounds and exact orthogonal pixel bijections. Run standalone Debug
and ReleaseSafe tests with `zig test packages/image/src/ops/viewport.zig`.
