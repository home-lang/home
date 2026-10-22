# GIF codec corrections

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

The Image GIF adapter uses this encoder without changing its public call. Its
large grayscale regression verifies dimensions and every decoded pixel. Existing
palette/alpha policy and still-only image encoding remain separate work; this
change does not claim arbitrary image GIF animation or camera GIF/APNG capture.

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
compositing/interlacing, quantizer resource behavior and advanced GIF features
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
