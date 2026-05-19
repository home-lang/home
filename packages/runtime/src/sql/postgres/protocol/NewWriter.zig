// Wave-16 stub (2026-05-18) — minimal forward-decl for the postgres-wire
// writer wrapper. Upstream `bun/src/sql/postgres/protocol/NewWriter.zig`
// is a 128-line generic-method-table factory that depends on `Data`
// (sql/shared/Data.zig pulls in `bun.ByteList` + `bun.default_allocator`)
// and `int_types`. The int_types module is already ported but Data isn't,
// so this stub exposes just enough surface for the generic factories in
// `WriteWrap.zig` to compile:
//
//   - `pub fn NewWriterWrap(Context, …) type` (forward-decl)
//   - `pub fn NewWriter(Context) type` returns a struct with `.wrapped: Context`
//
// Calls into the returned struct's methods aren't supported yet.
//
// TODO(phase-12-N): replace with the verbatim upstream copy once Data.zig
// is ported.

pub fn NewWriterWrap(
    comptime Context: type,
    comptime _writeFn: anytype,
    comptime _pwriteFn: anytype,
    comptime _offsetFn: anytype,
) type {
    _ = _writeFn;
    _ = _pwriteFn;
    _ = _offsetFn;
    return struct {
        wrapped: Context,
        pub const Ctx = Context;
    };
}

pub fn NewWriter(comptime Context: type) type {
    return struct {
        wrapped: Context,
        pub const Ctx = Context;
    };
}

test "NewWriter stub exposes a {wrapped} struct" {
    const std = @import("std");
    const Ctx = struct { tag: u8 };
    const W = NewWriter(Ctx);
    const w: W = .{ .wrapped = .{ .tag = 'P' } };
    try std.testing.expectEqual(@as(u8, 'P'), w.wrapped.tag);
}
