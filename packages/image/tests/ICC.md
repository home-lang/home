# ICC profile primitives

`metadata/icc.zig` reads selected ICC v2/v4 metadata and creates a deterministic
v2.4 sRGB matrix/TRC profile. It does not perform general ICC pixel conversion,
execute LUT profiles, or certify profile conformance. Embedding a profile does
not transform pixel samples. The profile date describes the profile definition,
not a photograph's capture time.

The generated profile contains D50-adapted colorants, the chromatic-adaptation
matrix, complete v2 description/copyright types and one 4096-entry sampled sRGB
curve shared by the three channels. The curve retains the linear toe; a gamma
2.2 approximation is not the sRGB transfer function. Legacy scalar gamma fields
remain summaries. Use `profile.curve(channel).evaluate()` or `.inverse()` for
the actual curve. Those views borrow the parsed profile's owned tag bytes; keep
the profile alive and do not mutate its public tag map while using a view.

`icc_layout.validate()` provides allocation-free checked tag views. It rejects
truncated sizes/tables/bodies, ambiguous overlaps, duplicate signatures and
malformed supported curves/text layouts. Exactly shared tag bodies are legal.
Unknown tag types are retained without interpretation. Inputs are bounded to
16 MiB / 1024 tags; owned parsing additionally enforces a conservative 64 MiB
copy/text-expansion budget. `validateRgb()` checks RGB and XYZ/Lab PCS; it does
not establish that a profile matches a particular image or execute calibration.

The standalone profile tests cover ownership after input mutation, every
truncated prefix, allocation failures, shared-body amplification, Unicode,
sampled curves, parametric curves and malformed geometry. Run from the repo root:

```sh
zig test packages/image/src/metadata/icc.zig
zig test --dep icc -Mroot=packages/image/tests/icc_profile_test.zig -Micc=packages/image/src/metadata/icc.zig
zig build-obj -O ReleaseSafe -fcompiler-rt -lc --dep icc -Mroot=packages/image/tests/icc_fixture.zig -Micc=packages/image/src/metadata/icc.zig -femit-bin=/tmp/home-icc.o
cc -std=c11 -Wall -Wextra -Werror packages/image/tests/icc_lcms.c /tmp/home-icc.o $(pkg-config --cflags --libs lcms2) -lm -o /tmp/home-icc-test
/tmp/home-icc-test
```

Little CMS is an independent **test-only** dependency. The C fixture reads all
three generated tone curves at 65,536 input values and transforms 4,913 RGB
patches to XYZ against the published D50 reference matrix. It tests the actual
serialized profile through another CMM rather than round-tripping our parser.
No camera, physical chart, sensor, display calibration or Pi timing is tested.
The object explicitly includes Zig compiler-runtime helpers so the system C
linker can resolve stack probes on x86; runtime safety remains enabled.

References: [ICC sRGB interpretation](https://registry.color.org/rgb-registry/files/sRGB.pdf),
[ICC specification](https://www.color.org/specification/ICC.1-2022-05.pdf).

`IccEmbedding` (or standalone `src/metadata_embed.zig`) embeds a validated RGB
profile into JPEG APP2 segments, PNG iCCP, or the primary classic-TIFF IFD.
JPEG preserves APP0 placement and scan bytes, splits profiles into ordered
65519-byte parts and replaces previous ICC APP2 markers before the first scan.
PNG checks chunk CRCs, inserts compressed iCCP after IHDR, and removes older
profile/color/HDR-signaling chunks to prevent competing interpretations.
TIFF preserves original strips and next-IFD links, appends a sorted replacement
primary directory and tag 34675, and repoints the header. Old unreachable TIFF
metadata bytes remain in the file; this API does not erase them. It accepts
both TIFF byte orders, rejects BigTIFF and requires RGB photometric data.

The caller must ensure the profile describes the pixels. Embedding neither
transforms samples nor proves full container/profile conformance. JPEG parsing
checks pre-scan markers and retains subsequent entropy/scans verbatim; it does
not decode those scans. TIFF checks primary-entry geometry, not complete page
chains or compressed strip contents. All returned bytes are owned; inputs are
borrowed for the synchronous call only. Add `-lc -lz` when testing this module.
