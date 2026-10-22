# Owned tuning documents

`Tuning` exports `metadata/tuning.zig`, a standalone JSON data editor. It does
not apply sensor or ISP settings and owns no camera, kernel or process state.

`Document.init(allocator, bytes, limits)` copies input, rejects trailing input
and duplicate object keys, and owns the complete parsed tree. Defaults bound
input and published edits to 16 MiB, 262144 scanner tokens and 64 container
levels. Caller limits must be positive; depth cannot exceed 256. Token accounting
includes scanner string chunks. Unknown fields and exact JSON numeric lexemes
are preserved, including integers and decimals beyond floating-point precision.

Missing `version` means version 1: algorithm names are root keys. Version 2 has
an `algorithms` array of objects. Numeric version spellings must equal exactly
1 or 2, including decimal/exponent spellings. Algorithm names are nonempty UTF-8,
at most 256 bytes, without NUL. A missing algorithm reports AlgorithmNotFound;
multiple version-2 entries defining the same requested name report
AmbiguousAlgorithm rather than silently editing the wrong entry.

`algorithm` returns a borrowed JSON Value, valid only until edit/deinit; do not
mutate its storage. `algorithmJSON` returns an owned serialization to free with
its supplied allocator. `bytes` retains original input spelling until an edit;
edits serialize compact JSON while retaining number lexemes and unknown fields.

`replaceAlgorithm` replaces one existing algorithm with arbitrary strict JSON.
It parses, clones, serializes and revalidates a candidate before retiring the
old owner. Parse/schema/limit/allocation failure leaves the original unchanged.
Call `deinit` once; callers serialize access and coordinate borrowed lifetimes.
No file I/O or second general JSON parser is introduced.

Five standalone tests cover both layouts, exact numbers/version comparisons,
ambiguous/missing names, budgets and exhaustive allocation-failure cleanup:

```sh
zig test packages/image/src/metadata/tuning.zig
zig test -O ReleaseSafe packages/image/src/metadata/tuning.zig
```
