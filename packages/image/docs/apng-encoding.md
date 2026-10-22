# Borrowed APNG encoding

`formats/apng_encoder.zig` (also `image.ApngEncoder` and
`image.Png.AnimationEncoder`) encodes noninterlaced APNG from checked borrowed
gray/RGB/RGBA views with 8- or 16-bit samples, per-frame endian and padded strides.
The last row needs no trailing padding. Input bytes and descriptors remain the
caller's responsibility during a synchronous call; no pointer is retained.

`Animation` supplies canvas width/height, frames, play count and PNG compression
and filter options. Each `Frame` supplies a raster view, x/y position, rational
delay, disposal (none/background/previous) and blend (source/over). All frames
must share color format and sample depth; endian and stride may differ. Frame
rectangles must fit the canvas. Delay denominator zero retains the PNG-defined
1/100-second interpretation. `Delay.fromMilliseconds` reduces the fraction
exactly and rejects unrepresentable durations instead of silently clamping.

With `default_image = null`, frame zero supplies IDAT and must cover the complete
canvas at (0,0). A separately supplied full-canvas `default_image` supplies IDAT
without participating in animation; all animation frames then use fdAT. The
first frame can be a rectangle in this form. acTL, fcTL and fdAT ordering follows
the [PNG third edition](https://www.w3.org/TR/png-3/#animation-information).
Frame controls and data share checked sequence numbers without wrapping.

`write(allocator, animation, sink)` preflights every frame span, geometry, format,
play count and compression option before allocating or calling the synchronous
`writeAll` sink. It reuses `raster_encoder.writePngData`, including PNG byte order,
all filters and the pinned streaming zlib owner. Each frame creates its own zlib
stream. Scratch storage is two rows plus bounded compression state, independent
of image height; there is no full filtered-image allocation or second compressed
frame copy. fdAT writes its sequence prefix and compressed data as separate parts
of one CRC-covered chunk. zlib's native workspace uses its separate C allocator.

A streaming sink can contain a prefix after an allocator/codec/sink failure;
the caller supplies staging or rollback. `encode` returns an owned slice only
on complete success. Neither API is a resumable asynchronous encoder or retains
camera requests. These ownership rules also apply to the newly shared PNG
`writePngHeader`, `writePngChunk` and `writePngData` helpers.

The Image PNG adapter uses `Image.frames[0].pixels` for the first frame instead
of mixing `Image.pixels` with that frame's controls. New nullable `Frame.width`
and `height` default to the legacy canvas dimensions; explicit sizes describe a
tightly packed rectangle. PNG and WebP readers preserve their decoded rectangle
sizes. Indexed still/animation input validates palette entries and expands to
RGBA, preserving palette alpha instead of omitting transparency information.
The adapter uses row streaming for every frame, fixes little-endian 16-bit data
and rejects short frames rather than encoding uninitialized scratch bytes.

Standalone tests cover descriptor preflight, exact delays, sequence overflow,
all host allocation failures, every sink write failure boundary and a 20,000-row
image encoded with a 1 KiB Zig allocation budget (bounded compression stack
output and native zlib workspace excluded).
An independent C harness checks CRCs, contiguous sequences, chunk ordering,
dimensions, controls and all decoded samples using libpng for each reconstructed
frame. Its 216 fixtures per build cover gray/RGB/RGBA, 8/16 bits, all six filter
choices, both default-image layouts, subrectangles, mixed endian, unaligned padded
rows without final padding, large multi-chunk frames, alpha and source retirement.
It checks frame data and controls; libpng is not used as an APNG compositor.
Debug/ReleaseSafe run on Zig 0.15.2 and Home development Zig. The full Image API
adds first-frame, rectangle, long-delay, indexed-alpha and cleanup regressions.
The C decoder is test-only. Encoding uses Zig and zlib, no Python or FFmpeg.

Home OS main 151269666bc09aa15a271f1c1f4603f681132e65 was fetched and inspected:
camera/media sources supply no APNG encoder, and mailbox/VGA palettes manage
display hardware rather than raster color tables. ADR-MC3 places shared media
algorithms in Home stdlib. No OS source is copied, modified or executed.

This does not complete generic APNG decoder validation, animation compositing,
interlacing, additional metadata, GIF palette quality/animation or camera-facing
animation capture. Those remain separate required work. No physical camera or
performance result is inferred from these software fixtures.
