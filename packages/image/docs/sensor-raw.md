# Checked sensor rows

SensorRaw in image.zig reexports ops/sensor_raw.zig. Its standalone std-only
Format/Pattern/View supports all pinned Picamera2 Bayer and mono format names,
including unpacked 8/10/12/14/16, CSI-2 packed 10/12/14, mono R8_CSI2P, and
Bayer/MONO_PISP_COMP1. COMP2 and noncanonical aliases reject. Format.writeName
round-trips canonical names; Pattern.mono must not be asked for a Bayer CFA.

View.init borrows positive geometry, checked pitch/active spans and optional
absent final-row padding. COMP1 needs a complete eight-byte/eight-pixel block
at the right edge, even for a partial group; CSI-2 likewise retains its complete
final packing group. Unaligned data and odd pitches are accepted. row and copy16
write canonical little-endian u16 samples with no scaling/demosaicing. Samples in
unpacked sub-16-bit words are validated before writes. Full copy preflight checks
all rows before mutation, capacity and overlap; exact unpacked16 identity is a
no-op. Output padding and suffixes remain unchanged. Callers own all output and
retain source lifetime during the synchronous call; no allocator or thread is
hidden. COMP1 decodes each pair of channel words once per eight output pixels.

The decoder follows raspberrypi/picamera2 request.py Helpers.decompress at
5e2a35d3bb230825c98c56d98e01b41ddeb43e86, with its BSD-2-Clause copyright/license
retained in the source. It uses the standard Raspberry Pi driver's offset 2048,
all four per-word quantizer cases and saturating u16 reconstruction. This is a
lossy stored sensor representation: reconstruction cannot recover original ADC
precision. Nonstandard compression offsets or COMP2 are not inferred.

packRow supplies exact unpacked/CSI-2 sample packing with atomic preflight.
compandedWord packs only four legal mode-3 quantizer codes (0..175) for fixtures;
it is not a general lossless sensor compressor. The generator in
packages/image/tests/generate-sensor-vectors.ts creates deterministic scalar
reference vectors from upstream equations using Bun, never Python. Regenerate
with bun, then check Zig formatting. Tests cover all canonical formats/depths,
partial groups, 455 fixed/reference words, every legal companding pair, channel
interleaving, clipping, unaligned padded rows, overflow/truncation/overlap and
late invalid samples without partial writes. Run Debug/ReleaseSafe on pinned
0.15.2 and development Zig; the full image API uses development Zig.

Home OS camera/VideoCore declarations do not supply a checked COMP1/CSI-2 sensor
view. These media algorithms remain hosted stdlib code per its ADR-MC3. Camera
consumers provide leases/DMA synchronization and DNG calibration/metadata;
software fixtures do not establish physical Pi or sensor acceptance.

The retained upstream license is reproduced in sensor-raw-license.txt for source
and binary redistributions using the COMP1 implementation/reference fixtures.
