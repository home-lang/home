# Checked integer image pixels and copies

`Image.PixelView` (`formats/pixel_view.zig`) contains the shared borrowed raster
`View`, `Format` and allocator-owned `Owned.copy`. PNG/BMP/TIFF and GIF/APNG use
the same view through `raster_encoder`. Validation preserves that API's positive
i32 dimensions, 8/16-bit depth, checked row/span arithmetic and optional padding
between rows. No padding is required after the final active row. Word order is
explicit, and samples can be unaligned. Source pixels remain immutable during a
call; neither conversion nor encoding retains a borrowed pointer.

`View.convert` validates source and destination spans and rejects overlap before
writing, except identical no-op views. Identical formats use active-row memcpy;
destination padding and bytes beyond the active final row remain untouched.
Other conversions support gray/RGB/RGBA, 8/16 bits and either word order. RGB16
and RGBA16 retain every word. Eight-bit samples promote by byte replication
(`value * 257`); sixteen-bit samples reduce by selecting the high byte. Missing
alpha becomes 65535, and dropping alpha is explicit rather than compositing.
Grayscale uses floor((299R+587G+114B)/1000) at source precision. This is an encoded
integer luma policy, without transfer/gamut conversion or alpha premultiplication.

`View.crop` validates a borrowed rectangle; `Owned.copy` makes an independent
compact converted/cropped copy with the caller's allocator. Owned data survives
the source and is retired with `deinit`. No hosted I/O, threading or codec runtime
is needed by this module. Callers choose resource limits above the allocator.

The public Home Image API now uses these checked conversions. Previously,
`toFormat` allocated 16-bit/indexed targets without writing their pixels, and
sixteen-bit source reads returned null and became black. Conversion now prepares
all main/frame pixel replacements before publishing, retains low bits and frame
controls/loop counts, expands indexed sources through the checked PNG/GIF helper,
and unwinds every failure with the original owners intact. It validates pixel
spans and frame dimensions; it is not an animation compositor. Indexed destinations
explicitly reject rather than publishing uninitialized bytes. Encoding palette
quantization remains a separate codec operation.

`clone` now independently copies all frame/palette/pixel owners and loop counts
instead of dropping animation. `Color16`, `getPixel16` and `setPixel16` expose
native words; the existing eight-bit pixel accessors explicitly reduce/promote
sixteen-bit images. Home Image's packed sixteen-bit storage remains little-endian.
General resampling, indexed destination conversion, external decoder hardening
and arbitrary image-object/animation operations remain separate work.

Local pinned/development Zig Debug/ReleaseSafe runs each pass three view/owner
tests and 576 independent C-reference fixtures across color models, depths, word
orders, padding, unaligned samples, source retirement and native-precision luma.
APNG's 216-fixture matrix and GIF's 252-fixture matrix also pass in all four
builds after the shared-view extraction. The complete Home Image API passes 159
tests on development Zig, including deep copies, multi-frame/indexed conversion
allocation failures, unsupported targets and preflight of every frame.
These tests do not establish camera quality, physical format acceptance or speed.

Home OS main at 151269666bc09aa15a271f1c1f4603f681132e65 was fetched and inspected
through ADR-MC3, camera/media, framebuffer and VideoCore7 sources. Kernel RGB565,
framebuffer formats and container image-name copying do not provide a checked
hosted gray/RGB/RGBA16 owner/converter. Shared algorithms improve Home stdlib;
camera leases/native I/O remain hosted ownership. No OS source is copied, changed
or executed.
