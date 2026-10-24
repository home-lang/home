# Owned JPEG decoding

`jpeg_decoder.decode(allocator, bytes, options)` decodes 8-bit Huffman sequential
and progressive JPEG to owned gray8 or RGB8 samples. It handles per-component
sampling, interleaved/separate sequential scans, progressive spectral selection
and successive approximation, byte stuffing, restarts and 8/16-bit quantization
tables. The existing Home DCT inverse is reused. `formats/jpeg.zig::decode`
adopts its pixels into the legacy Image without a second pixel copy.

Defaults use centered bilinear chroma upsampling; nearest sampling is explicit.
Named Adobe RGB/YCbCr/CMYK/YCCK interpretation and conventional CMYK ink
conversion are supported. ICC and Exif TIFF bytes are copied as source metadata;
no color-management/profile transform or Exif orientation is applied. Metadata
is available from the standalone result; legacy Image has no metadata owner.

Bounds separately cover encoded bytes, pixels, live working allocations,
metadata, scans, markers and work units. Cancellation checkpoints run through
parsing, scan reconstruction and inverse transforms. Coefficients use i16 with
checked arithmetic. Reconstruction caches two block rows per component instead
of allocating full component planes. Partial allocations clean up on every error.
The caller owns the allocator and deinitializes the returned result.

Unsupported precision, arithmetic/lossless/hierarchical coding and unsupported
color transforms fail explicitly. Strict complete-input parsing requires an EOI
and rejects trailing data, malformed tables, progression/restart violations and
truncation. This is defined support, not a claim of all JPEG family conformance.

The independent libjpeg C corpus generates/decodes 1,212 gray, YCbCr, RGB, CMYK
and YCCK cases, including coarse quantization, multiple sampling layouts,
separate scans, custom progressive bands/refinements, restarts, odd dimensions,
out-of-order ICC fragments and truncations. Corrupt restart sequences reject.
Reference IDCT uses JDCT_FLOAT; measured corpus maximum sample difference is 2
out of 255. This is codec evidence, not camera optics/quality/performance evidence.
