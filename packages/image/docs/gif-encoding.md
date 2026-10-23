# Checked still GIF encoding

`Image.GifEncoder` (`formats/gif_encoder.zig`) supplies `encode(allocator, view,
options)` returning caller-owned bytes and `write(allocator, view, options, sink)`
for synchronous streaming. It accepts the checked PNG/BMP/TIFF `raster.View`:
gray/RGB/RGBA, 8 or 16 bits, explicit word endian, padded/unaligned rows, and no
required padding after the final active row. Dimensions must be 1..65,535, spans
and arithmetic must validate, and `max_colors` must be 2..256 before any allocation
or sink call. Callers keep immutable pixels alive for the complete call; no input
or sink pointer survives it.

GIF has indexed 8-bit color and one-bit transparency. Sixteen-bit samples reduce
to their high byte. For unassociated RGBA, high-byte alpha below
`alpha_threshold` (default 128) becomes transparent; the other pixels are opaque.
Threshold zero makes every pixel opaque. Transparent pixels do not consume
opaque palette entries or influence their colors. A transparent entry is reserved
only when needed and counts toward `max_colors`. All-transparent images are
valid. Partial alpha, premultiplied input, color-space conversion and dithering
are not implemented by this encoder. PNG/TIFF retain more source precision.

The encoder reuses the bounded median-cut quantizer improved in Home video and
the image package's dictionary LZW. Exact sparse palettes retain all source hues;
larger color sets use a population-weighted five-bit histogram with actual
channel sums. A row of indices feeds the LZW stream and 255-byte GIF sub-block
writer. There is no full RGB or indexed-image copy. Scratch allocation is at
most one fixed 1 MiB histogram, 768 palette bytes and one width-sized index row,
plus bounded quantizer/LZW stack state. Owned encoded output is additional.
Streaming callers can enforce their own output cap. Sink/allocator failures may
leave a streaming prefix; callers own file staging and rollback. The byte-returning
convenience publishes only complete output and unwinds all allocation failures.

Optional synchronous sink `checkpoint() !void` runs before scratch preparation,
on every source/compression row and between palette partitions. Errors stop
preparation even when compressed rows have not filled an output sub-block.
The shared quantizer's `quantizeSource` accepts checked, stable, borrowed sources
with `len`, `pixel(index) !?[3]u8` and optional `checkpoint`; null pixels are omitted.
An all-omitted source returns an empty palette, and failed replacement retains
the previous palette. The image/video packages keep verbatim copies of this
std-only module for their independent module roots; CI compares the copies.

The public `Image.encode(.gif)` adapter delegates to the checked encoder. This
fixes equal-luminance hue collisions, black output for 16-bit pixels and ignored
alpha in the old adapter. Indexed input shares PNG's checked RGBA expansion,
including missing/short/out-of-range palette rejection and alpha. Indexed expansion
does allocate one RGBA owner, released before returning. PNG and GIF use the same
helper. Nonempty `Image.frames` now explicitly rejects with `UnsupportedAnimation`
instead of silently discarding animation. The separate video GIF writer continues
to support its existing opaque RGB frames; general Image animation/compositing
semantics remain work.

The four local pinned/development Zig Debug/ReleaseSafe builds each pass 21
checked-GIF/raster/palette/LZW/zlib tests and 13 video-GIF/palette tests. Test-only
giflib independently checks 252 raster fixtures per build, covering gray/RGB/RGBA,
8/16-bit input, both word orders, unaligned padded rows, exact palettes, explicit
alpha thresholds, all-transparent images, retired source owners and a declared
channel-error bound on a dense color cube. Failure tests cover preflight ordering,
cooperative cancellation while palette and compressed data are buffered, and every
allocation site. The complete Image API passes 153 tests on Home development Zig.
These fixtures do not establish physical camera quality or performance.

Home OS main at 151269666bc09aa15a271f1c1f4603f681132e65 was fetched and inspected:
ADR-MC3, camera/media sources and palette/GIF/LZW searches. Camera capture still
returns a nominal size and the nominal decoder routines do not implement a hosted
raster encoder. Shared algorithms remain Home stdlib code, as ADR-MC3 directs;
no OS code is copied, modified or executed.
