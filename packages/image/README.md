
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
