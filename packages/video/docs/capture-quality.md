# Named software capture quality

`src/core/capture_quality.zig` is an allocation-free policy for five named capture
quality tiers, distinct from the broader library's CRF/search presets. It reuses
`session_config` validation and the Zig standard library's integer square root.

| Tier | Software JPEG quality | Software AVC reference bits/sec |
| --- | ---: | ---: |
| very-low | 25 | 3000000 |
| low | 35 | 4000000 |
| medium | 50 | 7000000 |
| high | 65 | 10000000 |
| very-high | 80 | 14000000 |

The table and software AVC square-root complexity scaling follow the inspected
Picamera2 reference 5e2a35d3bb230825c98c56d98e01b41ddeb43e86, specifically
JpegEncoder._setup and LibavH264Encoder._setup. Source text is inspected without
executing Python or linking Libav. Home deliberately extends the same bitrate
heuristic to HEVC; upstream does not supply an equivalent HEVC table. Hardware
H.264/MJPEG use different upstream linear policies, which are not hosted hardware
encoder implementations here. These heuristics are not optical-quality or FPS
measurements and do not guarantee an actual compressed bitrate.

At width W, height H and rational nominal frame rate N/D, the unrounded estimate is
`floor(reference * sqrt(W * H * N / (1920 * 1080 * 30 * D)))`.
The implementation computes the exact integer result through a u128 squared
ratio and integer square root; no architecture-dependent floating-point rounding
is involved. The returned bitrate floors to multiples of 1000 bits/sec, with a
minimum 1000, matching the native bridge's vendor kbit units. Results exceeding
u32 reject, rather than silently saturating or wrapping.

`bitrate(tier, W, H, N, D)` validates its own admitted codec geometry/rate bounds.
`apply(cfg, tier)` returns a copied scalar video recipe with the caller's other
fields retained and complete session shape/rate validation. AVC/HEVC named tiers
override target bitrate and use inactive numeric quality 90 under ABR. MJPEG
selects the JPEG table; nonzero MJPEG bitrate/GOP remain invalid. Caller policy
must still validate codec options, fixed-QP conflicts, levels and VBV together.
No camera, encoder, allocator, worker, file or output hook is opened.

Use the final negotiated stream dimensions before applying a tier, then validate
combined codec/rate limits before publishing a recording session. Preserve the
requested tier separately if future geometry/fps changes should recompute the
policy. A failed application leaves the original config unchanged. Existing
numeric/default behavior belongs to the caller and is unaffected by this helper.

Focused Debug/ReleaseSafe tests on pinned and development Zig check all reference
values, rational rates, exact scaling, vendor units, monotonicity, tiny rates,
overflow rejection, unchanged recipes and unsupported JPEG rate control.
