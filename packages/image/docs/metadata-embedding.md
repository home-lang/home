# ICC and Exif image embedding

`MetadataEmbedding` (`src/metadata_embed.zig`) embeds optional `icc` and `exif`
byte slices into encoded JPEG, PNG or classic TIFF images. `embedMetadata`
returns one caller-owned output allocation; input image and metadata stay
borrowed and immutable for the call. `check` validates metadata without image
I/O and normalizes a prefixed Exif input to bare TIFF bytes. The old
`IccEmbedding.embed` API retains its ICC-only behavior. No pixels are color
transformed, decoded or re-encoded by the embedding layer.

```zig
const output = try MetadataEmbedding.embedMetadata(allocator, .jpeg, encoded, .{
    .icc = profile_bytes,
    .exif = exif_tiff_bytes,
});
defer allocator.free(output);
```

Exif accepts bare classic TIFF or the `Exif\0\0` prefix and uses the shared
bounded directory validator. JPEG's bare TIFF limit is 65,527 bytes; larger
metadata fails before output allocation. ICC uses the existing bounded RGB
profile validator and JPEG's 255-part APP2 limit. No supplied metadata means an
owned identity copy without container validation. Structural validation does not
certify every tag or an entire image's conformance. Opaque MakerNote-internal
positions are not relocated; callers own proprietary offset semantics.

JPEG writes one APP1 Exif segment and numbered APP2 ICC parts after APP0 records,
replacing only selected pre-scan Exif/ICC markers. Other APP1 records and existing
unselected metadata remain. Entropy, byte stuffing, restarts and subsequent scans
are copied unchanged. An RGB ICC requires a three-component frame; Exif itself
can annotate other frame component layouts. This helper does not parse all JPEG
scans or repair malformed compressed pixels.

PNG writes bare TIFF in one CRC-checked eXIf chunk after IHDR, alongside iCCP when
selected. A supplied Exif replaces old eXIf chunks; an omitted Exif preserves
them. ICC embedding retains its existing conflicting color-chunk replacement
policy. Exif-only grayscale images are supported without inventing an RGB ICC.
All input chunk CRCs are checked and IDAT bytes are unchanged. JPEG APP1 marker,
length and Exif prefix are not part of PNG eXIf data.

TIFF appends sorted replacement primary metadata directories and repoints the
header. Existing sample bytes, strip/tile offsets and original page directories
stay in place. Supplied primary tags replace matching tags; other existing tags
and unselected Exif/GPS pointers remain. Pixel/layout fields and ICC cannot be
injected through an Exif primary IFD; use the dedicated ICC argument. New Exif,
GPS and interoperability directories, next links, numeric values and JPEG
thumbnail offsets are relocated into the output's byte order, independently of
the input Exif byte order. Shared/overlapping metadata value bodies are copied
per entry, avoiding conflicting endian conversions.

JPEG thumbnail IFDs are marked as reduced images (NewSubfileType bit 0). New
thumbnail chains precede original TIFF pages. Replacing a thumbnail skips old
reduced JPEG-thumbnail IFDs with valid compression/offset/length fields, preserving
original page links. Unmarked pages are retained. The selected Exif parser reads
the first JPEG thumbnail, rather than letting later JPEG pages overwrite it.
TIFF thumbnail relocation rejects strip/tile/SubIFD and legacy JPEG table-pointer
forms it cannot safely relocate; it never silently copies those pointers into a
new metadata address space. BigTIFF and full proprietary pointer semantics are
not implemented. These remain explicit format-extension work.

JPEG/PNG output capacity is reserved up front. ICC and Exif are written together,
avoiding a second complete image output just to add another metadata family.
PNG CRCs use segmented profile data, avoiding a temporary concatenated profile
chunk. TIFF copies the original image once and initializes only the appended
region. Growth/offset arithmetic is checked against each format's limits. The
TIFF input's existing root must be sorted/unique; this is not a full TIFF raster
or page-chain validator. Appended old bytes remain in the file, so embedding is
not a metadata-redaction or privacy-erasure API.

Standalone tests cover simultaneous/replacement metadata, unchanged compressed
payloads and strips, CRCs, truncation, both TIFF byte orders, relocated directories,
original page links, changed thumbnail bytes, grayscale policy and every
allocation failure. A test-only C oracle uses independent libexif to write both
Exif byte orders; libjpeg/libpng/libtiff extract metadata and decode before/after
images. Little CMS opens embedded RGB profiles. It includes a two-page big-endian
TIFF and verifies the original second page still decodes at its preserved offset.
The 16 container/endian/profile cases also replace metadata with a different byte
order and thumbnail payload. Thumbnail bytes are SOI/EOI-delimited fixtures, not
independently decoded thumbnail images. These are software checks, not capture,
sensor/optical quality, CMM pixel conversion or complete Exif acceptance claims.

References: [PNG eXIf](https://www.w3.org/TR/png-3/),
[TIFF byte order](https://libtiff.gitlab.io/libtiff/functions/TIFFOpen.html),
[ICC embedding](https://archive.color.org/files/technotes/ICC-Technote-ProfileEmbedding.pdf).

## Metadata during JPEG encoding

`jpeg_metadata.zig` independently checks and emits complete APP1/APP2 records
without raster or compressor dependencies. `Encoder.encodeMetadata` writes
these markers after JFIF while encoding, preserving scan bytes relative to the
legacy encoder. `encodeOwned` transfers the encoder's output allocation to the
caller; later encoder use cannot invalidate it. Invalid metadata is checked
before resetting reusable encoder state. Existing `encode` remains borrowed
output without metadata. The embedding layer shares the same marker generator.
Tests compare scan bytes, reuse after ownership transfer, all allocation failures,
and independent libjpeg/libexif/LCMS reads with both Exif byte orders and ICC.

`tests/exif_inspect.c` is a test-only JSON inspector for actual capture outputs.
It uses libexif and independent JPEG/PNG readers; it is never a production
dependency. TIFF inspection reads bounded classic TIFF metadata rather than
claiming full image validation.
