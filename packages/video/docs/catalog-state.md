# Transactional typed catalog state

core/catalog_state.zig builds bounded owned replacements for a typed capability or
metadata journal. It reuses typed_catalog.Reader/Writer to preserve exact values,
arrays, byte order, geometry, labels and opaque payloads without converting through
floating-point numbers. Only group-zero nonzero u32 IDs are state keys.

updated(allocator, sourceReaderOrNull, updatesReader, removedIDs, outputKind,
maximumRecords, maximumBytes) returns a new Writer. Removals precede updates;
explicit updates can reinsert a removed key. Updates replace complete records by
ID. Duplicate source/update IDs, invalid keys, record bounds and byte bounds reject.
The output is sorted by ID and owns every name, vendor, label and value payload.
Source bytes remain unchanged on every success/failure path and may be released
once the replacement has been built. The caller deinitializes the new writer.

Prepare this replacement before committing external resources. Publish it only
when that operation succeeds, then deinitialize the previous writer; on failure,
deinitialize the candidate and retain the original state. The helper owns no
external handle, synchronization, revision counter or device validation policy.
Its readers borrow source memory while the replacement is prepared, so the caller
must keep both inputs alive and unchanged for the operation.

Tests cover sorted replacement and removal, independent owned output,
source preservation, duplicate/invalid keys, record/byte bounds and every allocation
failure on pinned Zig 0.15.2 and development Zig. zig-camera uses this helper to
stage typed native/vendor control replay before backend publication and to remove
typed settings superseded by its compatibility control API.
