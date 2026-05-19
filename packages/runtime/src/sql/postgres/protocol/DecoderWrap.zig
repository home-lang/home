// Copied verbatim from bun/src/sql/postgres/protocol/DecoderWrap.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Generic factory used by every postgres protocol packet decoder to wire
// a free `decodeInternal(this, Context, NewReader(Context))` function
// into an instance method `decode(this, ctx)`. The wave-16 NewReader
// stub keeps the import resolution loud (`.wrapped` field only); real
// reader semantics return once Data.zig ports.

pub fn DecoderWrap(comptime Container: type, comptime decodeFn: anytype) type {
    return struct {
        pub fn decode(this: *Container, context: anytype) AnyPostgresError!void {
            const Context = @TypeOf(context);
            try decodeFn(this, Context, NewReader(Context){ .wrapped = context });
        }
    };
}

test "DecoderWrap forwards through to decodeFn" {
    const std = @import("std");
    const Fake = struct {
        seen: u32 = 0,
        fn decodeInternal(this: *@This(), comptime _Ctx: type, _reader: NewReader(_Ctx)) AnyPostgresError!void {
            _ = _reader;
            this.seen += 1;
        }
    };
    var fake: Fake = .{};
    const Wrap = DecoderWrap(Fake, Fake.decodeInternal);
    try Wrap.decode(&fake, @as(u32, 0));
    try std.testing.expectEqual(@as(u32, 1), fake.seen);
}

const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;

const NewReader = @import("./NewReader.zig").NewReader;
