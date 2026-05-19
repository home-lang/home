// Wave-18 stub (2026-05-18) — minimal forward-decl for the mysql-wire
// reader wrapper. Upstream `bun/src/sql/mysql/protocol/NewReader.zig`
// is a 129-line generic-method-table factory that depends on
// `AnyMySQLError` + `Data` + `decodeLengthInt`. Only the factory shape
// is needed for packet decoder leaves (EOFPacket, StmtPrepareOKPacket,
// LocalInfileRequest, OKPacket) to compile, so this stub keeps the
// return-type surface (`.wrapped: Context`) and the comptime
// `decoderWrap` glue. Method bodies (`reader.int(...)`, `reader.peek()`,
// `reader.read(N)`, etc.) are intentionally absent — calling them
// triggers a normal Zig "no method named X" compile error, which is
// the trigger to port the real `NewReader` and drop this stub.
//
// TODO(phase-12-N): replace with the verbatim upstream copy once
// `bun.ByteList` + the full `Data` runtime are ported.

const std = @import("std");
const AnyMySQLError = @import("./AnyMySQLError.zig");

pub fn NewReader(comptime Context: type) type {
    return struct {
        wrapped: Context,
        pub const Ctx = Context;
        pub const is_wrapped = true;
    };
}

pub fn decoderWrap(comptime Container: type, comptime decodeFn: anytype) type {
    return struct {
        pub fn decode(this: *Container, context: anytype) AnyMySQLError.Error!void {
            const Context = @TypeOf(context);
            if (@hasDecl(Context, "is_wrapped")) {
                try decodeFn(this, Context, context);
            } else {
                try decodeFn(this, Context, .{ .wrapped = context });
            }
        }

        pub fn decodeAllocator(this: *Container, allocator: std.mem.Allocator, context: anytype) AnyMySQLError.Error!void {
            const Context = @TypeOf(context);
            if (@hasDecl(Context, "is_wrapped")) {
                try decodeFn(this, allocator, Context, context);
            } else {
                try decodeFn(this, allocator, Context, .{ .wrapped = context });
            }
        }
    };
}

test "MySQL NewReader stub exposes a {wrapped} struct" {
    const Ctx = struct { id: u32 };
    const R = NewReader(Ctx);
    const r: R = .{ .wrapped = .{ .id = 7 } };
    try std.testing.expectEqual(@as(u32, 7), r.wrapped.id);
}

test "MySQL decoderWrap forwards through to decodeFn" {
    const Fake = struct {
        seen: u32 = 0,
        fn decodeInternal(this: *@This(), comptime _Ctx: type, _reader: NewReader(_Ctx)) AnyMySQLError.Error!void {
            _ = _reader;
            this.seen += 1;
        }
    };
    var fake: Fake = .{};
    const Wrap = decoderWrap(Fake, Fake.decodeInternal);
    try Wrap.decode(&fake, @as(u32, 0));
    try std.testing.expectEqual(@as(u32, 1), fake.seen);
}
