# Selected Exif metadata

`src/metadata/exif.zig` supplies owned parsing and typed serialization of
classic TIFF Exif data. `parse` accepts bare TIFF bytes or the six-byte
`Exif\0\0` prefix. `encode` returns the prefixed form; `encodeTiff` returns bare
TIFF. These functions operate on metadata, not complete JPEG/PNG/TIFF images.
They do not implement MakerNote relocation, full Exif conformance, pixel decoding,
or camera capture policy.

The allocation-free `layout.validate` checks the entire reachable directory
graph before the parser reads fields. It supports both TIFF byte orders,
image/Exif/GPS/interoperability directories and next-IFD links. Limits are 16 MiB
of input TIFF, 32 directories, 4,096 total entries and 64 MiB of projected value
ownership (shared payloads are charged for each reference). Invalid pointers,
cycles/shared directory aliases, duplicate tags, table overlaps, out-of-range
values, unsupported TIFF types, malformed known field shapes, missing ASCII
terminators and zero rational denominators fail. Unaligned legacy values are
accepted using byte reads. This is structural validation of selected metadata;
it does not certify every unknown tag or the containing image.

The parser owns all retained strings, raw values and JPEG thumbnail bytes.
Repeated typed fields across directories safely replace previous allocations;
thumbnail dimensions do not overwrite primary geometry. GPS references are read
independently of field ordering, including south/west signs and negative altitude.
Coordinates and timestamps are bounded. Extended ISO values take precedence over
legacy PhotographicSensitivity regardless of tag order.

`Builder` copies each supplied field and enforces aggregate ownership and entry
limits. Its `ascii`, `short`, `long`, `rational`, `srational` and generic `bytes`
methods use the `image`, `exif`, `gps`, `interoperability` or `thumbnail` group.
Generic field bytes are little-endian. `serialization.encode` accepts borrowed
`Field` arrays for one call. Output directories are sorted, values are aligned,
and structural pointers are generated; caller-supplied pointer/thumbnail-offset
tags are rejected. An optional thumbnail supplies JPEG SOI/EOI-delimited bytes,
not an independently decoded or quality-validated thumbnail. Its offsets and
length are generated. Callers own the returned allocation.

The legacy `ExifData` adapter now writes its representable camera/date/lens,
geometry, exposure, ISO and GPS fields. Zero-valued legacy scalars are omitted
because that structure has no presence bits; use `Builder` for explicit zero
values. Floating GPS fields are quantized to bounded rationals with up to six
decimal places; values which round beyond coordinate/time limits fail. ISO values
use SHORT PhotographicSensitivity, SensitivityType 3 and LONG ISOSpeed, preserving
values above 65,535. The `raw_tags` map is a read-only byte projection without
original type or IFD identity and is not implicitly serialized. Use typed builder
fields for custom metadata. Raw MakerNote bytes are opaque; callers remain
responsible for proprietary internal offsets.

Tests cover truncation, malicious geometry/counts, cycles, duplicate tags, alias
allocation amplification, text/type/rational validation, GPS signs and bounds,
thumbnail ownership, extended ISO order, both byte orders, deterministic mutations
and every allocation failure across build/parse/re-encode. A test-only libexif C
reader checks actual serialized values and thumbnail bytes, then independently
writes both endian variants for the Home parser. Production has no libexif
runtime dependency. `.github/workflows/image-exif.yml` covers pinned 0.15.2 and
master on Linux x86/ARM; repository Actions availability is separate from local
validation. No Python or FFmpeg is used by these tests.

Tag definitions follow the selected layouts in
[CIPA DC-008 Exif 2.32](https://www.cipa.jp/std/documents/e/DC-X008-Translation-2019-E.pdf)
and [CIPA sensitivity tag mapping](https://cipa.jp/std/documents/e/DC-X010-2017.pdf).
