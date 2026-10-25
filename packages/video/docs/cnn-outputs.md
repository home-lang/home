# CNN output metadata

`video.cnn_outputs` validates Raspberry Pi exported CNN output metadata and
borrows exact float32 payload bytes. `Info.parse` accepts the current 712-byte
16-tensor/rank-16 structure and the older documented 264-byte 8-by-8 structure.
Other lengths fail explicitly. It checks UTF-8 names, rank, checked dimension
products, tensor offsets, per-tensor element counts and the entire float span.
Rank-zero scalars and empty dimensions have explicit TensorLayout semantics.
Padding and unused descriptors are not interpreted.

The current producer definition is [Raspberry Pi controller.h at c682979](https://github.com/raspberrypi/libcamera/blob/c682979b50695b93526adb1e66db33743484b63b/src/ipa/rpi/controller/controller.h).
Its 16-by-16 limits differ from the 8-by-8 example still in that revision's
control documentation. Shape/data-count consistency follows the producer parser.
[Picamera2's pinned output interpretation](https://github.com/raspberrypi/picamera2/blob/5e2a35d3bb230825c98c56d98e01b41ddeb43e86/picamera2/devices/imx500/imx500.py)
uses first-dimension-contiguous (column-major) output arrays.

`Outputs.fromRaw` supplies explicit payload byte order. `fromCatalog` selects
only exact metadata roles, kinds, array flags and accepted vendor provenance;
it rejects partial output pairs and duplicate identities. Both methods borrow
their payload owner. `copy` emits column-major data or explicitly reorders to
row-major while preserving IEEE bits, including NaNs and signed zero. Short or
overlapping output is rejected before writes. `copyTensorRowMajor` provides the
same checked conversion for already-decoded dense tensors.

The code owns no camera, model firmware, network file, tensor allocation or
inference engine. Consumers keep source snapshots alive until copying completes.
Tests validate both profiles, malformed products/ranks/spans, scalar/empty cases,
explicit byte order, NaN payloads, guarded output, provenance and duplicate/partial
catalogs. All 22 standalone/dependency tests pass on Zig 0.15.2 and
0.18.0-dev.567+7f0281900 in Debug, ReleaseSafe and ReleaseFast. These are software
layout/metadata checks; they do not establish physical IMX500 operation.
