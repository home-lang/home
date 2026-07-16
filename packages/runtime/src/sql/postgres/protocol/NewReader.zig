// Copied from bun/src/sql/postgres/protocol/NewReader.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../../../cli/LICENSE.bun.md.
//
// Import rewrite: `@import("bun")` -> `@import("home")`.

pub fn NewReaderWrap(
    comptime Context: type,
    comptime markMessageStartFn_: (fn (ctx: Context) void),
    comptime peekFn_: (fn (ctx: Context) []const u8),
    comptime skipFn_: (fn (ctx: Context, count: usize) void),
    comptime ensureCapacityFn_: (fn (ctx: Context, count: usize) bool),
    comptime readFunction_: (fn (ctx: Context, count: usize) AnyPostgresError!Data),
    comptime readZ_: (fn (ctx: Context) AnyPostgresError!Data),
) type {
    return struct {
        wrapped: Context,
        const readFn = readFunction_;
        const readZFn = readZ_;
        const ensureCapacityFn = ensureCapacityFn_;
        const skipFn = skipFn_;
        const peekFn = peekFn_;
        const markMessageStartFn = markMessageStartFn_;

        pub const Ctx = Context;
        pub const is_wrapped = true;

        pub inline fn markMessageStart(this: @This()) void {
            markMessageStartFn(this.wrapped);
        }

        pub inline fn read(this: @This(), count: usize) AnyPostgresError!Data {
            return try readFn(this.wrapped, count);
        }

        pub inline fn eatMessage(this: @This(), comptime msg_: anytype) AnyPostgresError!void {
            const msg = msg_[1..];
            try this.ensureCapacity(msg.len);

            var input = try readFn(this.wrapped, msg.len);
            defer input.deinit();
            if (bun.strings.eqlComptime(input.slice(), msg)) return;
            return error.InvalidMessage;
        }

        pub fn skip(this: @This(), count: usize) AnyPostgresError!void {
            skipFn(this.wrapped, count);
        }

        /// Consume a whole message body the caller doesn't decode. The length
        /// field counts itself (4 bytes) but not the already-read type byte, so
        /// the remaining body is `length - 4`. A handler that returns without
        /// doing this leaves the body in the stream and desyncs every following
        /// message.
        pub fn skipMessage(this: @This()) AnyPostgresError!void {
            const len = try this.length();
            if (len < 4) return error.InvalidMessageLength;
            try this.skip(@intCast(len -| 4));
        }

        pub fn peek(this: @This()) []const u8 {
            return peekFn(this.wrapped);
        }

        pub inline fn readZ(this: @This()) AnyPostgresError!Data {
            return try readZFn(this.wrapped);
        }

        pub inline fn ensureCapacity(this: @This(), count: usize) AnyPostgresError!void {
            if (!ensureCapacityFn(this.wrapped, count)) {
                return error.ShortRead;
            }
        }

        pub fn int(this: @This(), comptime Int: type) !Int {
            var data = try this.read(@sizeOf((Int)));
            defer data.deinit();
            const slice = data.slice();
            if (slice.len < @sizeOf(Int)) {
                return error.ShortRead;
            }
            if (comptime Int == u8) {
                return @as(Int, slice[0]);
            }
            return @byteSwap(@as(Int, @bitCast(slice[0..@sizeOf(Int)].*)));
        }

        pub fn peekInt(this: @This(), comptime Int: type) ?Int {
            const remain = this.peek();
            if (remain.len < @sizeOf(Int)) {
                return null;
            }
            return @byteSwap(@as(Int, @bitCast(remain[0..@sizeOf(Int)].*)));
        }

        pub fn expectInt(this: @This(), comptime Int: type, comptime value: comptime_int) !bool {
            const actual = try this.int(Int);
            return actual == value;
        }

        pub fn int4(this: @This()) !PostgresInt32 {
            return this.int(PostgresInt32);
        }

        pub fn short(this: @This()) !PostgresShort {
            return this.int(PostgresShort);
        }

        pub fn length(this: @This()) !PostgresInt32 {
            const expected = try this.int(PostgresInt32);
            if (expected > -1) {
                try this.ensureCapacity(@intCast(expected -| 4));
            }

            return expected;
        }

        pub const bytes = read;

        pub fn String(this: @This()) !bun.String {
            var result = try this.readZ();
            defer result.deinit();
            return bun.String.borrowUTF8(result.slice());
        }
    };
}

pub fn NewReader(comptime Context: type) type {
    if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) return Context;
    if (comptime canWrapContext(Context)) return NewReaderWrap(Context, Context.markMessageStart, Context.peek, Context.skip, Context.ensureLength, Context.read, Context.readZ);

    return struct {
        wrapped: Context,
        pub const Ctx = Context;
        pub const is_wrapped = true;
    };
}

fn canHaveDecls(comptime Type: type) bool {
    return switch (@typeInfo(Type)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

fn canWrapContext(comptime Context: type) bool {
    return canHaveDecls(Context) and
        @hasDecl(Context, "markMessageStart") and
        @hasDecl(Context, "peek") and
        @hasDecl(Context, "skip") and
        @hasDecl(Context, "ensureLength") and
        @hasDecl(Context, "read") and
        @hasDecl(Context, "readZ");
}

const bun = @import("home");
const std = @import("std");
const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;
const Data = @import("../../shared/Data.zig").Data;

const int_types = @import("../types/int_types.zig");
const PostgresInt32 = int_types.PostgresInt32;
const PostgresShort = int_types.PostgresShort;

test "Postgres NewReader reads big-endian integers" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 }, &offset, &message_start);

    try std.testing.expectEqual(@as(PostgresInt32, 0x01020304), try reader.int4());
    try std.testing.expectEqual(@as(PostgresShort, 0x0506), try reader.short());
    try std.testing.expectEqual(@as(usize, 6), offset);
}

test "Postgres NewReader length validates remaining bytes" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0, 0, 0, 6, 'o', 'k' }, &offset, &message_start);

    try std.testing.expectEqual(@as(PostgresInt32, 6), try reader.length());
    try std.testing.expectEqual(@as(usize, 4), offset);
    try std.testing.expectError(error.ShortRead, reader.ensureCapacity(3));
}

test "Postgres NewReader reads NUL-terminated strings and message tags" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init("Rhello\x00tail", &offset, &message_start);

    try reader.eatMessage("xR");
    var z = try reader.readZ();
    defer z.deinit();

    try std.testing.expectEqualStrings("hello", z.slice());
    try std.testing.expectEqualStrings("tail", reader.peek());
}

const StackReader = @import("./StackReader.zig");
