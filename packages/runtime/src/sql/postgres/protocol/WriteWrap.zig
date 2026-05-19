// Copied verbatim from bun/src/sql/postgres/protocol/WriteWrap.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Generic factory mirroring `DecoderWrap` on the write side: every
// postgres protocol packet writer (StartupMessage, Parse, Bind,
// Describe, Execute, …) carries a `writeInternal(this, Context,
// NewWriter(Context))` free function; this wrapper turns it into an
// instance method `write(this, ctx)`. The wave-16 NewWriter stub keeps
// the import shape; real writer semantics return once Data.zig ports.

pub fn WriteWrap(comptime Container: type, comptime writeFn: anytype) type {
    return struct {
        pub fn write(this: *Container, context: anytype) AnyPostgresError!void {
            const Context = @TypeOf(context);
            try writeFn(this, Context, NewWriter(Context){ .wrapped = context });
        }
    };
}

test "WriteWrap forwards through to writeFn" {
    const std = @import("std");
    const Fake = struct {
        seen: u32 = 0,
        fn writeInternal(this: *@This(), comptime _Ctx: type, _writer: NewWriter(_Ctx)) AnyPostgresError!void {
            _ = _writer;
            this.seen += 1;
        }
    };
    var fake: Fake = .{};
    const Wrap = WriteWrap(Fake, Fake.writeInternal);
    try Wrap.write(&fake, @as(u32, 0));
    try std.testing.expectEqual(@as(u32, 1), fake.seen);
}

const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;

const NewWriter = @import("./NewWriter.zig").NewWriter;
