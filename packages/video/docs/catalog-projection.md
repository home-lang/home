# Bounded catalog projection

`catalog_projection` extracts an inclusive group range and optional exact vendor
from a borrowed HCAT `Reader`. `plan(reader, selection)` returns the required byte
count and record count without allocating. `copy(reader, selection, output_kind,
output)` writes an independent HCAT catalog with the selected records in their
original order and exact original bytes. Only the catalog header changes.
Unknown records, opaque value data, payload byte order, flags, names and labels
are preserved without decoding or reserializing their values.

```zig
const selection: catalog_projection.Selection = .{
    .first_group = 100,
    .last_group = 112,
    .vendor = "application",
};
const size = try catalog_projection.plan(reader, selection);
const output = try allocator.alloc(u8, size.bytes);
errdefer allocator.free(output);
_ = try catalog_projection.copy(reader, selection, 7, output);
```

Readers must be initialized from valid HCAT bytes, and input/selection storage
must remain immutable and live during calls. Every record and value is checked,
including unselected tails, before output mutation. Invalid ranges, short output,
source/output overlap and selection-string/output overlap reject without writing
a prefix. Empty selections produce a valid 16-byte empty catalog. Extra output
suffix bytes remain unchanged. Output kind and the meaning of names/groups/vendor
are caller policy, not an authenticated provenance claim or a camera schema.

The algorithm allocates no storage and performs no I/O. It allows bounded
subsystems to expose selected snapshots without copying an entire unrelated
metadata catalog or losing opaque fields through a model conversion. Applications
still impose their own input/output byte and record budgets and keep borrowed
readers live. Concurrent mutation is not supported.

Twelve focused tests (including the imported typed-catalog suite) cover exact
opaque bytes/order, all/empty projections, vendor/group filtering, late malformed
unselected records, invalid ranges, short output, overlap, aliased selections and
preserved source/suffix bytes. Pinned Zig 0.15.2 and the development compiler pass
Debug/ReleaseSafe on the hosted macOS target and cross-link Linux ARM64/x86-64
test executables. The dedicated hosted CI matrix is configured for both compiler
lines/modes on Linux ARM64/x86-64 and macOS. This does not claim acceptance of the
entire Home compiler/media suite or any physical camera.
