// Copied from bun/src/sql/mysql/protocol/NewReader.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../../../cli/LICENSE.bun.md.
//
// Generic MySQL packet reader wrapper. Import rewrites:
// `@import("bun")` -> `@import("home")`. The upstream file has no direct
// Bun namespace references; the rewrite is recorded here for provenance.

pub fn NewReaderWrap(
    comptime Context: type,
    comptime markMessageStartFn_: (fn (ctx: Context) void),
    comptime peekFn_: (fn (ctx: Context) []const u8),
    comptime skipFn_: (fn (ctx: Context, count: isize) void),
    comptime ensureCapacityFn_: (fn (ctx: Context, count: usize) bool),
    comptime readFunction_: (fn (ctx: Context, count: usize) AnyMySQLError.Error!Data),
    comptime readZ_: (fn (ctx: Context) AnyMySQLError.Error!Data),
    comptime setOffsetFromStart_: (fn (ctx: Context, offset: usize) void),
) type {
    return struct {
        wrapped: Context,
        const readFn = readFunction_;
        const readZFn = readZ_;
        const ensureCapacityFn = ensureCapacityFn_;
        const skipFn = skipFn_;
        const peekFn = peekFn_;
        const markMessageStartFn = markMessageStartFn_;
        const setOffsetFromStartFn = setOffsetFromStart_;
        pub const Ctx = Context;

        pub const is_wrapped = true;

        pub fn markMessageStart(this: @This()) void {
            markMessageStartFn(this.wrapped);
        }

        pub fn setOffsetFromStart(this: @This(), offset: usize) void {
            return setOffsetFromStartFn(this.wrapped, offset);
        }

        pub fn read(this: @This(), count: usize) AnyMySQLError.Error!Data {
            return readFn(this.wrapped, count);
        }

        pub fn skip(this: @This(), count: anytype) void {
            skipFn(this.wrapped, @as(isize, @intCast(count)));
        }

        pub fn peek(this: @This()) []const u8 {
            return peekFn(this.wrapped);
        }

        pub fn readZ(this: @This()) AnyMySQLError.Error!Data {
            return readZFn(this.wrapped);
        }

        pub fn byte(this: @This()) AnyMySQLError.Error!u8 {
            const data = try this.read(1);
            return data.slice()[0];
        }

        pub fn ensureCapacity(this: @This(), count: usize) AnyMySQLError.Error!void {
            if (!ensureCapacityFn(this.wrapped, count)) {
                return AnyMySQLError.Error.ShortRead;
            }
        }

        pub fn int(this: @This(), comptime Int: type) AnyMySQLError.Error!Int {
            var data = try this.read(@sizeOf(Int));
            defer data.deinit();
            if (comptime Int == u8) {
                return @as(Int, data.slice()[0]);
            }
            const size = @divExact(@typeInfo(Int).int.bits, 8);
            return @as(Int, @bitCast(data.slice()[0..size].*));
        }

        pub fn encodeLenString(this: @This()) AnyMySQLError.Error!Data {
            if (decodeLengthInt(this.peek())) |result| {
                this.skip(result.bytes_read);
                return try this.read(@intCast(result.value));
            }
            return AnyMySQLError.Error.InvalidEncodedLength;
        }

        pub fn encodedLenInt(this: @This()) AnyMySQLError.Error!u64 {
            if (decodeLengthInt(this.peek())) |result| {
                this.skip(result.bytes_read);
                return result.value;
            }
            return AnyMySQLError.Error.InvalidEncodedInteger;
        }

        pub fn encodedLenIntWithSize(this: @This(), size: *usize) !u64 {
            if (decodeLengthInt(this.peek())) |result| {
                this.skip(result.bytes_read);
                size.* += result.bytes_read;
                return result.value;
            }
            return error.InvalidEncodedInteger;
        }
    };
}

pub fn NewReader(comptime Context: type) type {
    if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) {
        return Context;
    }
    if (comptime canWrapContext(Context)) {
        return NewReaderWrap(Context, Context.markMessageStart, Context.peek, Context.skip, Context.ensureCapacity, Context.read, Context.readZ, Context.setOffsetFromStart);
    }

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
        @hasDecl(Context, "ensureCapacity") and
        @hasDecl(Context, "read") and
        @hasDecl(Context, "readZ") and
        @hasDecl(Context, "setOffsetFromStart");
}

pub fn decoderWrap(comptime Container: type, comptime decodeFn: anytype) type {
    return struct {
        pub fn decode(this: *Container, context: anytype) AnyMySQLError.Error!void {
            const Context = @TypeOf(context);
            if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) {
                try decodeFn(this, Context, context);
            } else {
                try decodeFn(this, Context, .{ .wrapped = context });
            }
        }

        pub fn decodeAllocator(this: *Container, allocator: std.mem.Allocator, context: anytype) AnyMySQLError.Error!void {
            const Context = @TypeOf(context);
            if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) {
                try decodeFn(this, allocator, Context, context);
            } else {
                try decodeFn(this, allocator, Context, .{ .wrapped = context });
            }
        }
    };
}

test "MySQL NewReader reads primitives and advances StackReader cursors" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0x34, 0x12, 0x78, 0x56, 0x00, 'o', 'k' }, &offset, &message_start);

    try std.testing.expectEqual(@as(u16, 0x1234), try reader.int(u16));
    reader.markMessageStart();
    try std.testing.expectEqual(@as(usize, 2), message_start);
    try std.testing.expectEqual(@as(u16, 0x5678), try reader.int(u16));
    try std.testing.expectEqual(@as(u8, 0), try reader.byte());
    try std.testing.expectEqualStrings("ok", reader.peek());
    reader.setOffsetFromStart(1);
    try std.testing.expectEqual(@as(usize, 3), offset);
}

test "MySQL NewReader reads NUL and length-encoded data" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init("name\x00\x03abc\xfc\x34\x12", &offset, &message_start);

    const z = try reader.readZ();
    try std.testing.expectEqualStrings("name", z.slice());

    const encoded_string = try reader.encodeLenString();
    try std.testing.expectEqualStrings("abc", encoded_string.slice());

    var size: usize = 0;
    try std.testing.expectEqual(@as(u64, 0x1234), try reader.encodedLenIntWithSize(&size));
    try std.testing.expectEqual(@as(usize, 3), size);
    try std.testing.expectEqual(@as(usize, "name\x00\x03abc\xfc\x34\x12".len), offset);
}

test "MySQL NewReader reports short reads and invalid length encodings" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{0xfc}, &offset, &message_start);

    try std.testing.expectError(AnyMySQLError.Error.ShortRead, reader.ensureCapacity(2));
    try std.testing.expectError(AnyMySQLError.Error.InvalidEncodedInteger, reader.encodedLenInt());
    try std.testing.expectError(AnyMySQLError.Error.InvalidEncodedLength, reader.encodeLenString());
}

test "MySQL NewReader keeps scalar generic signatures compilable" {
    const R = NewReader(u32);
    const reader: R = .{ .wrapped = 7 };
    try std.testing.expectEqual(@as(u32, 7), reader.wrapped);
}

test "MySQL decoderWrap forwards through to decodeFn" {
    const Fake = struct {
        seen: u32 = 0,
        fn decodeInternal(this: *@This(), comptime _Ctx: type, _reader: NewReader(_Ctx)) AnyMySQLError.Error!void {
            _ = _reader;
            this.seen += 1;
        }
    };

    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init("", &offset, &message_start);
    var fake: Fake = .{};
    const Wrap = decoderWrap(Fake, Fake.decodeInternal);
    try Wrap.decode(&fake, reader);
    try std.testing.expectEqual(@as(u32, 1), fake.seen);
}

const AnyMySQLError = @import("./AnyMySQLError.zig");
const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const StackReader = @import("./StackReader.zig");
const decodeLengthInt = @import("./EncodeInt.zig").decodeLengthInt;
