// Copied from bun/src/sql/postgres/protocol/NewWriter.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../../../cli/LICENSE.bun.md.
//
// Import rewrite: `@import("bun")` -> `@import("home")`.

pub fn NewWriterWrap(
    comptime Context: type,
    comptime offsetFn_: (fn (ctx: Context) usize),
    comptime writeFunction_: (fn (ctx: Context, bytes: []const u8) AnyPostgresError!void),
    comptime pwriteFunction_: (fn (ctx: Context, bytes: []const u8, offset: usize) AnyPostgresError!void),
) type {
    return struct {
        wrapped: Context,

        const writeFn = writeFunction_;
        const pwriteFn = pwriteFunction_;
        const offsetFn = offsetFn_;
        pub const Ctx = Context;

        pub const WrappedWriter = @This();

        pub inline fn write(this: @This(), data: []const u8) AnyPostgresError!void {
            try writeFn(this.wrapped, data);
        }

        pub const LengthWriter = struct {
            index: usize,
            context: WrappedWriter,

            pub fn write(this: LengthWriter) AnyPostgresError!void {
                try this.context.pwrite(&Int32(this.context.offset() - this.index), this.index);
            }

            pub fn writeExcludingSelf(this: LengthWriter) AnyPostgresError!void {
                try this.context.pwrite(&Int32(this.context.offset() -| (this.index + 4)), this.index);
            }
        };

        pub inline fn length(this: @This()) AnyPostgresError!LengthWriter {
            const i = this.offset();
            try this.int4(0);
            return LengthWriter{
                .index = i,
                .context = this,
            };
        }

        pub inline fn offset(this: @This()) usize {
            return offsetFn(this.wrapped);
        }

        pub inline fn pwrite(this: @This(), data: []const u8, i: usize) AnyPostgresError!void {
            try pwriteFn(this.wrapped, data, i);
        }

        pub fn int4(this: @This(), value: PostgresInt32) !void {
            try this.write(std.mem.asBytes(&@byteSwap(value)));
        }

        pub fn int8(this: @This(), value: PostgresInt64) !void {
            try this.write(std.mem.asBytes(&@byteSwap(value)));
        }

        pub fn sint4(this: @This(), value: i32) !void {
            try this.write(std.mem.asBytes(&@byteSwap(value)));
        }

        pub fn @"f64"(this: @This(), value: f64) !void {
            try this.write(std.mem.asBytes(&@byteSwap(@as(u64, @bitCast(value)))));
        }

        pub fn @"f32"(this: @This(), value: f32) !void {
            try this.write(std.mem.asBytes(&@byteSwap(@as(u32, @bitCast(value)))));
        }

        pub fn short(this: @This(), value: anytype) !void {
            const T = @TypeOf(value);
            const int_value = switch (@typeInfo(T)) {
                .int, .comptime_int => value,
                else => @compileError("short() requires an integer type"),
            };
            try this.write(std.mem.asBytes(&@byteSwap(std.math.cast(u16, int_value) orelse return error.TooManyParameters)));
        }

        pub fn string(this: @This(), value: []const u8) !void {
            try this.write(value);
            if (value.len == 0 or value[value.len - 1] != 0)
                try this.write(&[_]u8{0});
        }

        pub fn bytes(this: @This(), value: []const u8) !void {
            try this.write(value);
            if (value.len == 0 or value[value.len - 1] != 0)
                try this.write(&[_]u8{0});
        }

        pub fn @"bool"(this: @This(), value: bool) !void {
            try this.write(if (value) "t" else "f");
        }

        pub fn @"null"(this: @This()) !void {
            try this.int4(std.math.maxInt(PostgresInt32));
        }

        pub fn String(this: @This(), value: bun.String) !void {
            if (value.isEmpty()) {
                try this.write(&[_]u8{0});
                return;
            }

            var sliced = value.toUTF8(bun.default_allocator);
            defer sliced.deinit();
            const slice = sliced.slice();

            try this.write(slice);
            if (slice.len == 0 or slice[slice.len - 1] != 0)
                try this.write(&[_]u8{0});
        }
    };
}

pub fn NewWriter(comptime Context: type) type {
    if (comptime canHaveDecls(Context) and @hasDecl(Context, "is_wrapped")) return Context;
    if (comptime canWrapContext(Context)) return NewWriterWrap(Context, Context.offset, Context.write, Context.pwrite);

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

const bun = @import("home");
const std = @import("std");
const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;

const int_types = @import("../types/int_types.zig");
const Int32 = int_types.Int32;
const PostgresInt32 = int_types.PostgresInt32;
const PostgresInt64 = int_types.PostgresInt64;

const TestWriter = struct {
    buffer: *std.ArrayList(u8),

    pub fn offset(this: TestWriter) usize {
        return this.buffer.items.len;
    }

    pub fn write(this: TestWriter, bytes: []const u8) AnyPostgresError!void {
        try this.buffer.appendSlice(std.testing.allocator, bytes);
    }

    pub fn pwrite(this: TestWriter, bytes: []const u8, offset_: usize) AnyPostgresError!void {
        @memcpy(this.buffer.items[offset_..][0..bytes.len], bytes);
    }
};

test "Postgres NewWriter writes big-endian primitives and z strings" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 32);
    defer buffer.deinit(std.testing.allocator);

    const writer = NewWriter(TestWriter){ .wrapped = .{ .buffer = &buffer } };
    try writer.int4(0x01020304);
    try writer.short(0x0506);
    try writer.string("home");
    try writer.bytes("lang\x00");
    try writer.bool(true);
    try writer.bool(false);

    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 'h',  'o',
        'm',  'e',  0,    'l',
        'a',  'n',  'g',  0,
        't',  'f',
    }, buffer.items);
}

test "Postgres NewWriter length helper patches message size" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buffer.deinit(std.testing.allocator);

    const writer = NewWriter(TestWriter){ .wrapped = .{ .buffer = &buffer } };
    const length = try writer.length();
    try writer.write("abcd");
    try length.write();

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 8, 'a', 'b', 'c', 'd' }, buffer.items);
}

test "Postgres NewWriter writes Home String values" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 8);
    defer buffer.deinit(std.testing.allocator);

    const writer = NewWriter(TestWriter){ .wrapped = .{ .buffer = &buffer } };
    try writer.String(bun.String.borrowUTF8("ok"));

    try std.testing.expectEqualSlices(u8, &.{ 'o', 'k', 0 }, buffer.items);
}
