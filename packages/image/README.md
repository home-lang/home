
### Checked RGBA input

[RGBA views](docs/rgba-view.md) validate padded straight-alpha RGBA8 rows and copy
only active pixels into caller-owned compact storage. The standalone helper has
no codec, allocator or renderer dependencies and exports as `RgbaView`.

### Image regions

[Region validation](docs/region.md) is available independently of image objects and
rejects overflow-prone coordinates/extents without arithmetic traps. Existing
`crop.Region` and `image.Region` exports retain their fields and methods.
