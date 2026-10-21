# Color descriptions and negotiation

`core/color_description.zig` provides allocation-free descriptions of primaries,
transfer, YCbCr matrix and range. It is separate from pixel storage and conversion.
Preset values describe sRGB, sYCC, SMPTE 170M, Rec.709, Rec.2020 and raw. Portable
numeric IDs are descriptive enums, not codec/ISO color signaling values.

`Description.signal()` maps processed YCbCr descriptions to ISO primaries,
transfer and matrix codes plus a boolean full-range flag, for AVC/HEVC VUI and
MP4 `nclx`. It rejects RGB (matrix none) and raw descriptions rather than guessing
an encoder matrix. The result describes existing samples; it never transforms
them. See [the native media adapter](native-video.md) for explicit encoder and
container constructors and their caller-owned consistency contract.

`Description.fromCodes` rejects unknown values. `processed(yuv)` rejects raw
primaries for processed streams and requires an explicit matrix for YUV. RGB
preserves requested primaries/transfer while normalizing matrix to none and range
to full. The caller's description is never changed.

`negotiate(requested, actual, yuv, strict)` keeps requested/effective/actual values
separate. `normalized` identifies the RGB normalization; `adjusted` identifies a
backend mismatch against the effective request. Missing/unknown actual metadata
must be supplied as null and counts as an adjustment. Strict mode rejects backend
adjustments, including absent actual metadata, after format normalization.

The caller must query authoritative backend metadata. These helpers do not open a
device, select a renderer/codec, transform pixels/gamma/gamut, set ICC profiles, or
claim a backend can produce a requested color space. Raw metadata can use raw
descriptions; processed configuration must pass the separate processed check.
Tests cover presets, immutability, RGB/YUV admission, individual component changes,
absent actual values, strict behavior and unknown code rejection.
