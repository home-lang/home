# GIF codec corrections

The current checked still encoder and Image adapter are documented in
[gif-encoding.md](gif-encoding.md), including explicit precision/alpha policy,
bounded palette/LZW streaming and independent readback. The corrections below
describe the dictionary and video-writer foundations it reuses.

`formats/gif_lzw.zig` supplies a std-only, caller-serialized `Encoder` and owned
`encode(allocator, indices, minimum_code_size)` convenience. It improves Home's
image encoder and follows the width/first-code tracking already present in the
video writer. That writer's literal code-width handling remains valid; the image
writer's old fixed-width literal stream corrupted larger images. Independent
giflib readback reproduces an exact pixel mismatch at 257 pixels with minimum 8.

The new encoder uses a fixed 4096-code dictionary and 8192-slot bounded hash table,
LSB-first 3..12-bit codes, clear/EOI, dictionary resets and correct EOI width at
boundaries. `write` consumes slices synchronously and retains no input pointer;
`finish` seals the stream. Every write checks indices before mutation. A sink
failure poisons further operations; invalid indices leave the previous stream
usable. Code sizes outside 2..8 reject. Caller-owned encoded output survives the
source. Repeated patterns use dictionary codes instead of one literal per pixel.
This is software coding evidence, not a camera throughput measurement.

The Image GIF adapter uses dictionary encoding without changing its public call. Its
large grayscale regression verifies dimensions and every decoded pixel. Existing
palette/alpha policy is now supplied by the checked encoder linked above;
arbitrary Image GIF animation/compositing remain separate work.

The video GIF writer already models multiple opaque RGB frames and loop counts.
It now borrows the quantizer palette only while that owner is alive, copies the
frame's own palette and unwinds all append/allocation failures once. Quantizer
replacement frees the old palette only on successful publication; errors retain
it. The returned palette is borrowed until replacement/deinit. RGB triples,
positive frame dimensions and color counts 1..256 are checked. Palette sums use
u64, and LZW workspace uses the supplied allocator. A small append writer replaces
the legacy ArrayList writer dependency so pinned and development Zig both work.

Its reader now represents 256-entry global/local tables as u16 counts, checks
those palette spans, and applies graphic-control delay/disposal/transparency to
only the following image. Missing controls reset to defaults, and truncated GCE
blocks reject. The additional checks are scoped: the complete generic decoder,
compositing/interlacing and advanced GIF features
are not declared fully hardened or complete by these tests.

Standalone unit tests run Debug/ReleaseSafe on Zig 0.15.2 and development Zig.
The independent C harness passes 357 LZW cases per build across minimum sizes
2..8, one-pixel/boundary/large inputs, constant/pattern/noisy data, dictionary
resets and terminal code widths. It also decodes two public video-writer frames at five dimensions (including
one million pixels) with giflib and checks every RGB value, local palettes, independent delays and
disposal after source/encoder owners retire. Host allocation-failure tests cover
writer cleanup and successful/failed quantizer replacement. The full Image API
runs on Home development Zig. giflib is test-only; encoders remain Zig with no
Python or FFmpeg tools/runtime.

Home OS at 151269666bc09aa15a271f1c1f4603f681132e65 was inspected through ADR-MC3,
camera/media sources and container/image.home. The latter manages OCI images,
and nominal kernel video declarations do not supply a GIF raster encoder.
Shared codecs remain Home stdlib code; no OS source is copied, modified or run.

The [GIF89a specification](https://www.w3.org/Graphics/GIF/spec-gif89a.txt) defines
variable code widths, clear/EOI and graphic-control scope. Tests use giflib rather
than treating a round trip through Home alone as independent conformance proof.

The video writer now reuses `video/src/containers/palette_quantizer.zig` through
its existing `MedianCutQuantizer` public name. The previous implementation copied
every RGB pixel into growing color arrays, sorted and copied those arrays again
for each split, and split uniform-color boxes into duplicate palette entries.
The replacement consumes packed RGB8 synchronously without retaining or changing
it. A fixed open-addressed sparse pass preserves every exact color when the input
fits the requested 1..256-color palette. A uniform million-pixel input needs only
three allocated palette bytes, rather than a pixel-sized workspace or duplicate
colors.

Larger color sets use a 32,768-bin histogram over five bits per channel, retain
the actual channel sums and population counts, then partition occupied bins in
place using population-weighted median cuts on the widest channel. Preparation
allocates one fixed 1 MiB histogram and at most 768 output bytes, independent of
pixel count; bounded sparse/box arrays additionally use about 10 KiB of stack.
An already published palette remains live until replacement succeeds. The input
limit remains u32 pixels. Nearest-color search returns immediately on exact
matches. Histogram cells may merge distinct colors once the exact sparse path
overflows; there is no dithering, alpha, perceptual color-space metric or promise
of identical palettes to the previous algorithm.

The initial four pinned/development Zig Debug/ReleaseSafe builds each passed 12 video and
palette tests, three LZW tests, 357 independent LZW fixtures and 11 two-frame
giflib writer fixtures. Cases preserve all 256 exact hues, independent delays,
disposal and source retirement, and bound decoded channel error for a 4,096-color
RGB cube reduced to 256 colors. Separate tests bound a 512-color cube reduced to
64 colors, preserve population-weighted low channel bits, prepare two million
pixels within fixed scratch space, and retain the previous owner across every
histogram/output allocation failure. These are scoped deterministic software
fixtures, not optical quality or Pi throughput measurements. The checked still
encoder now reuses this quantizer through borrowed sparse raster sources.

This follow-up again checks unchanged clean Home OS main at
151269666bc09aa15a271f1c1f4603f681132e65, ADR-MC3, camera and media sources. There
is no working raster palette quantizer to substitute there. The shared algorithm
stays in Home's standard library; no OS code is copied, changed or executed.
