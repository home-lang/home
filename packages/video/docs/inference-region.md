# Sensor inference geometry and frame KPI

`video.inference_region.Plan` projects full-sensor rectangles through raw stream
scaling, the applied scaler crop, translation and ISP output scaling. It clips
against the caller's inference ROI before raw scaling. Every stage rounds as
libcamera's integer `Rectangle` operations do; combining the scales changes
small rectangles. Normalized coordinates use `(y0,x0,y1,x1)`, clamp each derived
origin/extent to zero and truncate to signed pixels before the integer stages.
Reversed boxes can be empty. An empty result retains its intersection anchor,
which can lie outside the output canvas. Draw only nonempty rectangles.

Sizes must be positive and no larger than `INT32_MAX`. The applied scaler crop
must be nonempty and inside the full sensor, and must remain nonempty after raw
scaling. Unknown geometry and nonfinite/overflowing normalized coordinates fail
explicitly. Intersection endpoints use widened arithmetic. A zero ROI tuple
disables the extra inference crop. `centeredAspect` uses the integer center and
half-size convention, rejects subpixel crops and does not apply a device control.
The plan owns values, with no camera, pixel allocation or renderer dependency.

The sequence follows pinned Picamera2
[`IMX500.__get_obj_scaled`](https://github.com/raspberrypi/picamera2/blob/5e2a35d3bb230825c98c56d98e01b41ddeb43e86/picamera2/devices/imx500/imx500.py)
and the primary
[`libcamera` geometry implementation](https://github.com/raspberrypi/libcamera/blob/c682979b50695b93526adb1e66db33743484b63b/src/libcamera/geometry.cpp).
It does not infer sensor binning/crop origins from output dimensions or perform
an additional display rotation; callers supply actual frame geometry.

`video.cnn_kpi.Info` preserves the exact signed `int32[2]` values exported by
`CnnKpiInfo`. `fromRaw` reads exactly eight bytes with explicit byte order;
`fromCatalog` requires accepted metadata provenance, role, kind, count and array
flags, and rejects duplicate identities. Absence is `null`. The values are owned
integers after decoding. `picameraMilliseconds` divides the signed counters by
1000, exactly following the pinned Picamera2 helper. Raw counters remain available
because the upstream control YAML calls them milliseconds while that helper
applies `/1000`; the view is not an independent timing calibration. The IPA's
[uint32-to-int32 export](https://github.com/raspberrypi/libcamera/blob/c682979b50695b93526adb1e66db33743484b63b/src/ipa/rpi/common/ipa_base.cpp)
also means signed extremes must remain observable rather than silently clamped.

Pure helper tests cover staged rounding, clipping, empty/negative/reversed boxes,
aspect centers, geometry/coordinate bounds and KPI endian/count/provenance rules.
Public Video export tests exercise both APIs. The freestanding link probe keeps
the real normalized projection, aspect crop and KPI conversion reachable without
libc or a heap. These checks do not establish IMX500 operation or Home OS camera
hardware support.
