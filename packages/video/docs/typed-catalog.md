# Typed capability and metadata snapshots

core/typed_catalog.zig supplies a bounded owned Writer and validating borrowed
Reader for device properties, control ranges and per-frame metadata. Numeric
payloads retain their original width and bits, including exact signed 64-bit
integers, NaNs, arrays and unknown vendor payloads. No JSON double conversion or
backend-specific enum numbering is assumed. The caller owns locking and lifetime.

Writer.init(allocator, kind, maximumBytes) allocates a header. begin(RecordInfo),
append(Value), end() build records; finish() borrows immutable completed bytes.
The writer is mutable until its caller publishes it. Rejected appends preserve
all existing bytes and the open record. Bounds and allocation failures are
explicit errors, never silent truncation. deinit releases owned storage.

Reader.init(bytes) validates every record/value boundary, count, known portable
kind, fixed payload size, boolean byte and UTF-8 record/vendor/label. It rejects
trailing bytes and truncated input. records()/values() yield borrowed records and
values. Keep the source alive and unchanged during iteration. Opaque payloads and
string bytes are intentionally not interpreted as UTF-8; string decoding policy
belongs to the consumer. The writer limits total size to at most u32 maximum.

HCAT v1 uses little-endian u32 headers, with no padding:

- Catalog header (16 bytes): magic HCAT, version 1, application catalog kind,
  record count.
- Record header (44 bytes): total byte length, group, native ID, application ID,
  native type, application flags, extent, portable kind, name length, vendor
  length, value count; then UTF-8 name/vendor and values.
- Value header (28 bytes): total byte length, application role, portable kind,
  native type, flags, element count, label length; then UTF-8 label and raw payload.
  Flag 1 means array; flag 2 means little-endian payload. Header order is always
  little endian independently of the payload.

Portable kinds: none 0, bool 1, byte 2, i32 3, i64 4, f32 5, string 6,
rectangle 7 (i32 x/y, u32 width/height), size 8 (u32 width/height), u16 9,
u32 10, point 11 (i32 x/y), unknown 255. None has zero count/bytes; scalar
numeric/geometry values have one element; arrays may be empty. String count is
its byte length. Unknown native types use kind 255 with untouched bytes/count.
Native type IDs remain opaque because backend/library versions may renumber them.

Application groups/roles/flags are caller-defined. Applications must document
those meanings, maximum snapshot size, publication rules and unsupported fields.
Do not infer writable controls from the existence of a catalog record.

Tests cover allocation failures, exact integers, arrays, labels, opaque payloads,
capacity rejection without mutation, every truncation, corrupted fields and
trailing bytes on pinned Zig 0.15.2 and development Zig. zig-camera reuses the
helper for owned libcamera/synthetic catalogs and Bun decoding.
