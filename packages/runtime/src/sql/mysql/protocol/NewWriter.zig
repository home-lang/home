// Copied from bun/src/sql/mysql/protocol/NewWriter.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../../../cli/LICENSE.bun.md.
//
// Import rewrites:
// `@import("bun")` -> `@import("home")`.

pub fn NewWriterWrap(
    comptime Context: type,
    comptime offsetFn_: (fn (ctx: Context) usize),
    comptime writeFunction_: (fn (ctx: Context, bytes: []const u8) AnyMySQLError.Error!void),
    comptime pwriteFunction_: (fn (ctx: Context, bytes: []const u8, offset: usize) AnyMySQLError.Error!void),
) type {
    return struct {
        wrapped: Context,

        const writeFn = writeFunction_;
        const pwriteFn = pwriteFunction_;
        const offsetFn = offsetFn_;
        pub const Ctx = Context;

        pub const is_wrapped = true;

        pub const WrappedWriter = @This();

        pub inline fn writeLengthEncodedInt(this: @This(), data: u64) AnyMySQLError.Error!void {
            try writeFn(this.wrapped, encodeLengthInt(data).slice());
        }

        pub inline fn writeLengthEncodedString(this: @This(), data: []const u8) AnyMySQLError.Error!void {
            try this.writeLengthEncodedInt(data.len);
            try writeFn(this.wrapped, data);
        }

        pub fn write(this: @This(), data: []const u8) AnyMySQLError.Error!void {
            try writeFn(this.wrapped, data);
        }

        const Packet = struct {
            header: PacketHeader,
            offset: usize,
            ctx: WrappedWriter,

            pub fn end(this: *@This()) AnyMySQLError.Error!void {
                const new_offset = offsetFn(this.ctx.wrapped);
                const length = new_offset - this.offset - PacketHeader.size;
                // The length field is only 24 bits and we don't split across
                // multiple packets on the write path. Reject rather than letting
                // @intCast panic (or a wider field truncate) frame a malformed
                // packet the server could reparse.
                if (length >= std.math.maxInt(u24)) {
                    return error.Overflow;
                }
                this.header.length = @intCast(length);
                debug("writing packet header: {d}", .{this.header.length});
                try this.ctx.pwrite(&this.header.encode(), this.offset);
            }
        };

        pub fn start(this: @This(), sequence_id: u8) AnyMySQLError.Error!Packet {
            const o = offsetFn(this.wrapped);
            debug("starting packet: {d}", .{o});
            const padding: [PacketHeader.size]u8 = @splat(0);
            try this.write(&padding);
            return .{
                .header = .{ .sequence_id = sequence_id, .length = 0 },
                .offset = o,
                .ctx = this,
            };
        }

        pub fn offset(this: @This()) usize {
            return offsetFn(this.wrapped);
        }

        pub fn pwrite(this: @This(), data: []const u8, i: usize) AnyMySQLError.Error!void {
            try pwriteFn(this.wrapped, data, i);
        }

        pub fn int4(this: @This(), value: MySQLInt32) AnyMySQLError.Error!void {
            try this.write(&std.mem.toBytes(value));
        }

        pub fn int8(this: @This(), value: MySQLInt64) AnyMySQLError.Error!void {
            try this.write(&std.mem.toBytes(value));
        }

        pub fn int1(this: @This(), value: u8) AnyMySQLError.Error!void {
            try this.write(&[_]u8{value});
        }

        pub fn writeZ(this: @This(), value: []const u8) AnyMySQLError.Error!void {
            try this.write(value);
            if (value.len == 0 or value[value.len - 1] != 0)
                try this.write(&[_]u8{0});
        }

        pub fn String(this: @This(), value: home_rt.String) AnyMySQLError.Error!void {
            if (value.isEmpty()) {
                try this.write(&[_]u8{0});
                return;
            }

            var sliced = value.toUTF8(home_rt.default_allocator);
            defer sliced.deinit();
            const slice = sliced.slice();

            try this.write(slice);
            if (slice.len == 0 or slice[slice.len - 1] != 0)
                try this.write(&[_]u8{0});
        }
    };
}

pub fn NewWriter(comptime Context: type) type {
    if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) {
        return Context;
    }

    if (comptime canWrapContext(Context)) {
        return NewWriterWrap(Context, Context.offset, Context.write, Context.pwrite);
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
        @hasDecl(Context, "offset") and
        @hasDecl(Context, "write") and
        @hasDecl(Context, "pwrite");
}

pub fn writeWrap(comptime Container: type, comptime writeFn: anytype) type {
    return struct {
        pub fn write(this: *Container, context: anytype) AnyMySQLError.Error!void {
            const Context = @TypeOf(context);
            if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) {
                try writeFn(this, Context, context);
            } else {
                try writeFn(this, Context, .{ .wrapped = context });
            }
        }
    };
}

test "MySQL writeWrap forwards through to writeFn" {
    const Fake = struct {
        seen: u32 = 0,
        fn writeInternal(this: *@This(), comptime _Ctx: type, _writer: NewWriter(_Ctx)) AnyMySQLError.Error!void {
            _ = _writer;
            this.seen += 1;
        }
    };
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    var fake: Fake = .{};
    const Wrap = writeWrap(Fake, Fake.writeInternal);
    try Wrap.write(&fake, ctx);
    try std.testing.expectEqual(@as(u32, 1), fake.seen);
}

test "MySQL NewWriter writes packet header and primitive fields" {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    const writer = NewWriter(TestWriter){ .wrapped = ctx };

    var packet = try writer.start(7);
    try writer.int1(0x03);
    try writer.int4(0x01020304);
    try writer.writeZ("hi");
    try packet.end();

    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 0, 7 }, ctx.slice()[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x04, 0x03, 0x02, 0x01, 'h', 'i', 0 }, ctx.slice()[4..12]);
}

test "MySQL NewWriter length-encodes strings" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    const writer = NewWriter(TestWriter){ .wrapped = ctx };

    try writer.writeLengthEncodedString("abc");

    try std.testing.expectEqualSlices(u8, &.{ 3, 'a', 'b', 'c' }, ctx.slice());
}

test "MySQL NewWriter writes Home String values" {
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);
    const writer = NewWriter(TestWriter){ .wrapped = ctx };

    try writer.String(home_rt.String.borrowUTF8("ok"));

    try std.testing.expectEqualSlices(u8, &.{ 'o', 'k', 0 }, ctx.slice());
}

const TestWriter = struct {
    bytes: []u8,
    len: *usize,

    fn init(bytes: []u8, len: *usize) TestWriter {
        len.* = 0;
        return .{ .bytes = bytes, .len = len };
    }

    fn slice(this: TestWriter) []const u8 {
        return this.bytes[0..this.len.*];
    }

    pub fn offset(this: TestWriter) usize {
        return this.len.*;
    }

    pub fn write(this: TestWriter, bytes: []const u8) AnyMySQLError.Error!void {
        if (this.len.* + bytes.len > this.bytes.len) return error.ShortRead;
        @memcpy(this.bytes[this.len.*..][0..bytes.len], bytes);
        this.len.* += bytes.len;
    }

    pub fn pwrite(this: TestWriter, bytes: []const u8, offset_value: usize) AnyMySQLError.Error!void {
        if (offset_value + bytes.len > this.len.*) return error.ShortRead;
        @memcpy(this.bytes[offset_value..][0..bytes.len], bytes);
    }
};

const debug = home_rt.Output.scoped(.NewWriter, .hidden);

const AnyMySQLError = @import("./AnyMySQLError.zig");
const PacketHeader = @import("./PacketHeader.zig");
const home_rt = @import("home");
const std = @import("std");
const encodeLengthInt = @import("./EncodeInt.zig").encodeLengthInt;

const types = @import("../MySQLTypes.zig");
const MySQLInt32 = types.MySQLInt32;
const MySQLInt64 = types.MySQLInt64;
