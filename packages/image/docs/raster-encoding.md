# Borrowed raster encoding

`formats/raster_encoder.zig` is the shared PNG/BMP/TIFF implementation for Home's
Image API and external strided image consumers such as zig-camera. A `View` borrows
its bytes for the synchronous call. The returned encoded slice belongs to the
caller and survives source release. Link libc and zlib (`-lc -lz`); both image
package builds now include that dependency.

Views describe width, height, stride, gray/RGB/RGBA channels, 8/16-bit samples and
sample byte order. Validation checks dimensions, stride, arithmetic and the last
active row before allocating. Final-row padding need not be present. Padding is
never encoded. `fromImage` describes Home Image storage, including little-endian
16-bit samples; indexed images require explicit palette expansion.

PNG emits 8/16-bit samples in network byte order. Options select genuine zlib
levels 0..9 and adaptive, none, Sub, Up, Average or Paeth filtering. Compression
streams rows into bounded IDAT chunks, retaining two row buffers and the encoded
output instead of a complete filtered image and another compressed-image copy.
`zlib_stream.Deflater` adapts Home's runtime zlib C ABI without its allocator or
runtime imports. The C stream stays at a pinned heap address; writes retain no
input pointer, sink failures poison the stream, and finish can publish only once.
Disposal always releases native workspace and never claims to have finished a
failed or aborted stream. The adapter works on pinned/development Zig without
depending on unfinished or changing standard-library compressor APIs.

BMP writes padded bottom-up gray8/RGB24 or V4 RGBA32 rows. V4 bit masks preserve
unassociated alpha. Sixteen-bit input deliberately reduces to each sample's high
byte. TIFF preserves 8/16-bit gray/RGB/RGBA samples, writes per-component bit-depth
arrays, unassociated ExtraSamples, orientation, planar layout and resolution tags,
and validates classic TIFF size bounds. Its indexed Image path expands palette
colours to RGBA instead of emitting inconsistent palette/strip tags.

Home's PNG and TIFF decoders correctly select the high byte when returning RGB8
from 16-bit samples. TIFF rejects unknown compression before attempting to free
borrowed strip storage. These changes do not claim complete palette/APNG/metadata,
TIFF tiling/compression or arbitrary input-decoder hardening coverage.

Tests cover strided/short/overflowing views, PNG CRCs and independently inflated
samples, 16-bit byte order, alpha, palette expansion, immutable finish/failure
states, multi-block input, invalid levels and host allocation failures. The
standalone raster/stream tests run on Zig 0.15.2 and development Zig; the full Image
API uses Home's development toolchain and adds public encode/decode regressions.
zig-camera also decodes RGB files through platform ImageIO or libpng/libtiff/SDL.
Native zlib workspace allocation failures are reported, but host allocator fault
injection does not intercept zlib's separate C allocations.
