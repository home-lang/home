// Copied verbatim from bun/src/sql/postgres/protocol/DecoderWrap.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Generic factory used by every postgres protocol packet decoder to wire
// a free `decodeInternal(this, Context, NewReader(Context))` function
// into an instance method `decode(this, ctx)`.

pub fn DecoderWrap(comptime Container: type, comptime decodeFn: anytype) type {
    return struct {
        pub fn decode(this: *Container, context: anytype) AnyPostgresError!void {
            const Context = @TypeOf(context);
            if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) {
                try decodeFn(this, Context, context);
            } else {
                try decodeFn(this, Context, .{ .wrapped = context });
            }
        }
    };
}

fn canHaveDecls(comptime Type: type) bool {
    return switch (@typeInfo(Type)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
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

test "DecoderWrap accepts an already wrapped reader" {
    const std = @import("std");
    const Fake = struct {
        seen: u32 = 0,
        fn decodeInternal(this: *@This(), comptime _Ctx: type, _reader: NewReader(_Ctx)) AnyPostgresError!void {
            _ = _reader;
            this.seen += 1;
        }
    };
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init("", &offset, &message_start);
    var fake: Fake = .{};
    const Wrap = DecoderWrap(Fake, Fake.decodeInternal);
    try Wrap.decode(&fake, reader);
    try std.testing.expectEqual(@as(u32, 1), fake.seen);
}

const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;

const NewReader = @import("./NewReader.zig").NewReader;
const StackReader = @import("./StackReader.zig");
