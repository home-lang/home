
### Checked RGBA input

[RGBA views](docs/rgba-view.md) validate padded straight-alpha RGBA8 rows and copy
only active pixels into caller-owned compact storage. The standalone helper has
no codec, allocator or renderer dependencies and exports as `RgbaView`.
