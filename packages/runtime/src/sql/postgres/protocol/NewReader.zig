// Wave-16 stub (2026-05-18) — minimal forward-decl for the postgres-wire
// reader wrapper. Upstream `bun/src/sql/postgres/protocol/NewReader.zig`
// is a 121-line generic-method-table factory that depends on
// `bun.strings.eqlComptime` + `Data` (sql/shared/Data.zig pulls in
// `bun.ByteList` / `bun.BoundedArray` / `bun.default_allocator`). Those
// substrates aren't ported yet, so this stub exposes just enough surface
// for the generic factories in `DecoderWrap.zig` to compile:
//
//   - `pub fn NewReaderWrap(Context, …) type` (forward-decl)
//   - `pub fn NewReader(Context) type` returns a struct with `.wrapped: Context`
//
// Calls into the returned struct's methods aren't supported yet — they
// fire `@compileError` so anyone actually exercising the wire-protocol
// path gets a loud message pointing at this stub.
//
// TODO(phase-12-N): replace with the verbatim upstream copy once Data.zig
// + `bun.strings` are ported.

pub fn NewReaderWrap(
    comptime Context: type,
    comptime _markMessageStartFn: anytype,
    comptime _peekFn: anytype,
    comptime _skipFn: anytype,
    comptime _ensureCapacityFn: anytype,
    comptime _readFn: anytype,
    comptime _readZFn: anytype,
) type {
    _ = _markMessageStartFn;
    _ = _peekFn;
    _ = _skipFn;
    _ = _ensureCapacityFn;
    _ = _readFn;
    _ = _readZFn;
    return struct {
        wrapped: Context,
        pub const Ctx = Context;
    };
}

pub fn NewReader(comptime Context: type) type {
    return struct {
        wrapped: Context,
        pub const Ctx = Context;
    };
}

test "NewReader stub exposes a {wrapped} struct" {
    const std = @import("std");
    const Ctx = struct { id: u32 };
    const R = NewReader(Ctx);
    const r: R = .{ .wrapped = .{ .id = 7 } };
    try std.testing.expectEqual(@as(u32, 7), r.wrapped.id);
}
