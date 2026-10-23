# Typed catalog scalar reads

`typed_catalog.Value.scalar(T)` decodes one exact supported primitive: `bool`,
`u8`, `u16`, `u32`, `i32`, `i64` or `f32`. Payload byte order comes from the
value's `little_endian` flag; headers remain little endian. Signed/unsigned
ranges and f32 bits (including signed zero, infinities and NaNs) are preserved.
Finite/range policy belongs to the consumer. There is no integer-to-float,
boolean-to-integer, opaque-byte or array-of-one conversion. Unknown flags,
wrong kinds, malformed lengths/counts and invalid booleans reject.

`Reader.findScalar(T, query)` selects an explicit group/name/vendor set and value
role, with optional required/forbidden record flags. At least one accepted vendor
must be specified. An empty vendor string can be explicitly allowed when an older
source has no vendor provenance; it is not implicitly trusted. A missing identity
returns null. A matching record with no matching role, incompatible kind/shape,
or multiple matching values/records returns an error. Accepted-vendor duplicates
cannot silently replace one another. Unrelated vendor names and groups remain
unrelated records. The scan does not return the first value before validating the
remaining records, so later malformed data or duplicates cannot be hidden.

```zig
const stamp = try reader.findScalar(i64, .{
    .group = 0,
    .name = "Timestamp",
    .vendors = &.{"standard"},
    .role = 0,
    .required_flags = 2,
    .forbidden_flags = 1,
});
```

This extends the existing pointer-free HCAT reader without changing its wire
format or adding allocation, I/O, processes, camera policy or numeric guesses.
Reader/value storage is borrowed and must stay immutable/live for the entire
call. Applications interpret identity, role and record flags and decide whether
missing or invalid values prevent their operation. Scalar reading cannot validate
an upstream sensor, timestamp clock domain or claimed vendor's authenticity.

Eight focused tests include the existing structural/ownership/allocator checks
plus every supported primitive boundary/order, exact float bits, rejection cases,
selection and missing values, and late duplicates within/across records and malformed unrelated tails. Pinned
Zig 0.15.2 and the development compiler pass Debug/ReleaseSafe tests on the hosted
macOS target and cross-link ARM64/x86-64 Linux tests. The dedicated CI matrix runs
both compilers/modes natively on Linux ARM64/x86-64 and macOS. This is not a claim
about the full Home compiler suite or physical camera acceptance.
