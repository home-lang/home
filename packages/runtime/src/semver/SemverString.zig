pub const String = extern struct {
    pub const max_inline_len: usize = 8;

    bytes: [max_inline_len]u8 = @splat(0),

    pub const empty: String = .{};

    pub fn from(comptime inlinable_buffer: []const u8) String {
        comptime {
            if (!canInline(inlinable_buffer)) {
                @compileError("string constant too long to be inlined");
            }
        }
        return init(inlinable_buffer, inlinable_buffer);
    }

    pub const Formatter = struct {
        str: *const String,
        buf: string,

        pub fn format(formatter: Formatter, writer: *std.Io.Writer) !void {
            try writer.writeAll(formatter.str.slice(formatter.buf));
        }
    };

    pub inline fn fmt(self: *const String, buf: string) Formatter {
        return .{ .str = self, .buf = buf };
    }

    pub inline fn order(
        lhs: *const String,
        rhs: *const String,
        lhs_buf: string,
        rhs_buf: string,
    ) std.math.Order {
        return std.mem.order(u8, lhs.slice(lhs_buf), rhs.slice(rhs_buf));
    }

    pub inline fn canInline(buf: string) bool {
        return switch (buf.len) {
            0...max_inline_len - 1 => true,
            max_inline_len => buf[max_inline_len - 1] & 0x80 == 0,
            else => false,
        };
    }

    pub inline fn isInline(this: String) bool {
        return this.bytes[max_inline_len - 1] & 0x80 == 0;
    }

    pub fn init(buf: string, in: string) String {
        if (canInline(in)) {
            var out = String{};
            @memcpy(out.bytes[0..in.len], in);
            return out;
        }

        return @bitCast((@as(u64, @bitCast(Pointer.init(buf, in))) & std.math.maxInt(u63)) | (@as(u64, 1) << 63));
    }

    pub fn eql(this: String, that: String, this_buf: string, that_buf: string) bool {
        if (this.isInline() and that.isInline()) {
            return @as(u64, @bitCast(this.bytes)) == @as(u64, @bitCast(that.bytes));
        }

        return std.mem.eql(u8, (&this).slice(this_buf), (&that).slice(that_buf));
    }

    pub inline fn isEmpty(this: String) bool {
        return @as(u64, @bitCast(this.bytes)) == 0;
    }

    pub fn len(this: String) usize {
        if (!this.isInline()) return this.ptr().len;

        if (this.bytes[0] == 0) return 0;
        inline for (0..max_inline_len) |i| {
            if (this.bytes[i] == 0) return i;
        }
        return max_inline_len;
    }

    pub const Pointer = extern struct {
        off: u32 = 0,
        len: u32 = 0,

        pub inline fn init(buf: string, in: string) Pointer {
            if (Environment.allow_assert) {
                std.debug.assert(isSliceInBuffer(in, buf));
            }
            return .{
                .off = @truncate(@intFromPtr(in.ptr) - @intFromPtr(buf.ptr)),
                .len = @truncate(in.len),
            };
        }
    };

    pub inline fn ptr(this: String) Pointer {
        return @bitCast(@as(u64, @bitCast(this)) & std.math.maxInt(u63));
    }

    pub fn slice(this: *const String, buf: string) string {
        if (!this.*.isInline()) {
            const ptr_ = this.*.ptr();
            return buf[ptr_.off..][0..ptr_.len];
        }

        if (this.bytes[0] == 0) return "";
        inline for (0..max_inline_len) |i| {
            if (this.bytes[i] == 0) return this.bytes[0..i];
        }
        return &this.bytes;
    }

    pub inline fn stringHash(buf: string) u64 {
        return std.hash.Wyhash.hash(0, buf);
    }

    comptime {
        if (@sizeOf(String) != @sizeOf(Pointer)) {
            @compileError("String types must be the same size");
        }
    }
};

inline fn isSliceInBuffer(slice: string, buf: string) bool {
    if (slice.len == 0) return true;
    const buf_start = @intFromPtr(buf.ptr);
    const buf_end = buf_start + buf.len;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    return slice_start >= buf_start and slice_end <= buf_end;
}

const string = []const u8;

const std = @import("std");
const Environment = @import("shim.zig").Environment;
