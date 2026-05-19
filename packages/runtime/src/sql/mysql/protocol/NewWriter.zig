// Wave-21 stub (2026-05-19) — minimal forward-decl for the mysql-wire
// writer wrapper, mirroring the wave-18 `NewReader.zig` shape. Upstream
// `bun/src/sql/mysql/protocol/NewWriter.zig` is a 132-line generic
// method-table factory depending on `AnyMySQLError` + `Capabilities` +
// `encodeLengthInt` + writer-position helpers. The packet writer
// leaves we want to port today (SSLRequest, MySQLRequest) only need
// the factory shape (`.wrapped: Context`) + the comptime `writeWrap`
// glue, so this stub keeps the return-type surface and the wrap
// helper. Method bodies (`writer.start(...)`, `writer.int1(...)`,
// `writer.write(...)`, `writer.writeLengthEncodedString(...)`) are
// intentionally absent — calling them triggers a normal Zig "no method
// named X" compile error which is the trigger to port the real
// `NewWriter` and drop this stub.
//
// TODO(phase-12-N): replace with the verbatim upstream copy once
// `bun.ByteList` + the full `Data` runtime are ported.

const std = @import("std");
const AnyMySQLError = @import("./AnyMySQLError.zig");

pub fn NewWriter(comptime Context: type) type {
    return struct {
        wrapped: Context,
        pub const Ctx = Context;
        pub const is_wrapped = true;
    };
}

pub fn writeWrap(comptime Container: type, comptime writeFn: anytype) type {
    return struct {
        pub fn write(this: *Container, context: anytype) AnyMySQLError.Error!void {
            const Context = @TypeOf(context);
            if (@hasDecl(Context, "is_wrapped")) {
                try writeFn(this, Context, context);
            } else {
                try writeFn(this, Context, .{ .wrapped = context });
            }
        }
    };
}

test "MySQL NewWriter stub exposes a {wrapped} struct" {
    const Ctx = struct { id: u32 };
    const W = NewWriter(Ctx);
    const w: W = .{ .wrapped = .{ .id = 11 } };
    try std.testing.expectEqual(@as(u32, 11), w.wrapped.id);
}

test "MySQL writeWrap forwards through to writeFn" {
    const Fake = struct {
        seen: u32 = 0,
        fn writeInternal(this: *@This(), comptime _Ctx: type, _writer: NewWriter(_Ctx)) AnyMySQLError.Error!void {
            _ = _writer;
            this.seen += 1;
        }
    };
    const Ctx = struct { id: u32 };
    var fake: Fake = .{};
    const Wrap = writeWrap(Fake, Fake.writeInternal);
    try Wrap.write(&fake, Ctx{ .id = 0 });
    try std.testing.expectEqual(@as(u32, 1), fake.seen);
}
