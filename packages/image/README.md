
### Checked RGBA input

[RGBA views](docs/rgba-view.md) validate padded straight-alpha RGBA8 rows and copy
only active pixels into caller-owned compact storage. The standalone helper has
no codec, allocator or renderer dependencies and exports as `RgbaView`.

### Image regions

[Region validation](docs/region.md) is available independently of image objects and
rejects overflow-prone coordinates/extents without arithmetic traps. Existing
`crop.Region` and `image.Region` exports retain their fields and methods.

### Display viewports

[Viewport plans](docs/viewport.md) combine checked regions and exact orientation
maps for integer aspect fitting, overlay placement and independent texture UVs.
They own no pixels or renderer and export as `ViewportPlan`.

### Selected Exif metadata

[Exif parsing and serialization](docs/exif.md) validate bounded classic-TIFF
metadata before owned reads, support typed IFD construction and copy thumbnail
bytes. Standalone tests include an independent libexif reader/writer. This is
metadata support; embedding and camera capture policy are separate layers.

### Image metadata embedding

[ICC/Exif embedding](docs/metadata-embedding.md) writes both families together in
JPEG/PNG/classic TIFF while preserving encoded pixels. It validates metadata,
relocates TIFF directories and uses independent container/Exif readers and pixel
decoders in tests. Exports as `MetadataEmbedding`; `IccEmbedding` stays available.

### Tuning documents

[Owned tuning documents](docs/tuning.md) support both Raspberry Pi tuning JSON
layouts, exact number text, bounded parsing and transactional algorithm edits.
The standalone `Tuning` export owns data and never applies sensor/ISP settings.

### Bounded PNG/APNG decoding

`@import("png_decoder.zig").decode(allocator, bytes, options)` returns independently
owned default pixels, raw animation rectangles/controls, palette RGBA entries and
validated ICC/Exif plus scalar PNG color metadata. Call `result.deinit()` once.
The portable core supports Zig 0.15.2 and development Zig with libc/zlib linked.
It reuses Home's pixel views and metadata validation. See the [PNG specification](https://www.w3.org/TR/png-3/).

All legal PNG color/depth combinations, PNG filters, Adam7 and transparency keys
are reconstructed. Native 16-bit samples retain their low words; output words are
little endian and alpha is straight. Packed grayscale promotes to gray8; packed
indices retain a palette unless `expand_palette = true` requests RGBA8. No gamma
conversion, frame compositing or Exif orientation is automatic. APNG keeps a
separate default image, exact delay numerator/denominator (including denominator
zero), rectangle coordinates, dispose/blend controls and play count. Included
frame zero owns a distinct allocation from the default image.

The decoder validates complete chunk CRCs/order, zlib checksum/end, pixel lengths,
palette indices, APNG counts/sequences and metadata before returning an owner.
Limits cover encoded input, aggregate pixel output, metadata, chunks, frames and
conservative peak working storage. Inflation streams through two reconstruction
rows with bounded native workspace instead of allocating a full raw image.
Caller checkpoints can cancel parsing, inflation sinks, rows and frame processing;
all error/cancellation/allocation paths discard provisional results. The source
must remain immutable during decode and is never retained on return.

`Png.decode`/`Image.loadFromMemory` adopt the same checked pixels/palette/frame
owners. The legacy `Image` adapter exposes millisecond delays and has no ICC/Exif
fields or excluded-poster flag; use the core result for exact fractions, metadata
and poster-preserving APNG re-encoding with `AnimationEncoder`. Encoding
metadata remains an explicit caller choice. The `Image` root requires development
Zig; the leaf decoder remains portable. Independent libpng fixtures exercise 936
color/depth/interlace/filter/transparency/geometry combinations per build mode.
