// Copied from bun/src/install_types/SemverString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Imports rewritten:
//   `@import("bun")`        → `@import("home")`
//   `bun.Environment`        → `home_rt.Environment`
//   `bun.assert`             → `home_rt.assert`
//   `bun.strings`            → inlined `std.mem.order`
//   `bun.IdentityContext`    → `home_rt.IdentityContext`
//   `bun.Wyhash11`           → `home_rt.wyhash.Wyhash11`
//   `bun.isSliceInBuffer`    → inlined `isSliceInBufferShim`
//   `bun.copy`               → inlined `bunCompatCopy`
//   `bun.hash`               → inlined `bunCompatHash` (Wyhash11)
//   `bun.assertWithLocation` → `home_rt.assert` (drops `@src()` arg)
//   `bun.callmod_inline`     → direct call (no inline-attr indirection)
//
// Trimming versus upstream — these surfaces are dropped because they pull
// `Lockfile` / `ExternalString` / `JSPrinter` / `JSC` that are not yet
// available in `home_rt` (re-land alongside Phase 12.9 install-port):
//   • `String.Buf` (depends on `Lockfile` + `Builder.StringPool`)
//   • `String.Builder` (depends on `Lockfile` + `Builder.StringPool` +
//     `ExternalString`)
//   • `String.JsonFormatter` (depends on `bun.fmt.formatJSONStringUTF8`)
//   • `String.hashContext` / `String.arrayHashContext` constructors that
//     take `*Lockfile`. The `HashContext` / `ArrayHashContext` _types_
//     remain — callers supply the byte slices directly.
//   • `String.toJS` (JSC bridge)
// The core extern struct (layout + inline encoding + slice/init/eql) is
// preserved verbatim so it round-trips with the on-disk lockfile format.

//! `Semver.String`: 8-byte extern struct that stores either an inline ASCII
//! string (≤8 bytes, top bit clear) or an offset/length pointer (top bit
//! set) into an external bytes buffer. Sized to match the on-disk lockfile
//! layout.

/// String type that stores either an offset/length into an external buffer or a string inline directly
// Zig 0.17 forbids `@bitCast` on extern structs; reinterpret raw bytes instead.
inline fn reinterpret(comptime To: type, value: anytype) To {
    return std.mem.bytesToValue(To, std.mem.asBytes(&value));
}

pub const String = extern struct {
    pub const max_inline_len: usize = 8;
    /// This is three different types of string.
    /// 1. Empty string. If it's all zeroes, then it's an empty string.
    /// 2. If the final bit is not set, then it's a string that is stored inline.
    /// 3. If the final bit is set, then it's a string that is stored in an external buffer.
    bytes: [max_inline_len]u8 = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },

    pub const empty: String = .{};

    /// Create an inline string
    pub fn from(comptime inlinable_buffer: []const u8) String {
        comptime {
            if (inlinable_buffer.len > max_inline_len or
                inlinable_buffer.len == max_inline_len and
                    inlinable_buffer[max_inline_len - 1] >= 0x80)
            {
                @compileError("string constant too long to be inlined");
            }
        }
        return String.init(inlinable_buffer, inlinable_buffer);
    }

    pub const Tag = enum {
        small,
        big,
    };

    pub inline fn fmt(self: *const String, buf: []const u8) Formatter {
        return Formatter{
            .buf = buf,
            .str = self,
        };
    }

    pub const Formatter = struct {
        str: *const String,
        buf: string,

        pub fn format(formatter: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const str = formatter.str;
            try writer.writeAll(str.slice(formatter.buf));
        }
    };

    pub inline fn fmtStorePath(self: *const String, buf: []const u8) StorePathFormatter {
        return .{
            .buf = buf,
            .str = self,
        };
    }

    pub const StorePathFormatter = struct {
        str: *const String,
        buf: string,

        pub fn format(this: StorePathFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (this.str.slice(this.buf)) |c| {
                const n = switch (c) {
                    '/' => '+',
                    '\\' => '+',
                    ':' => '+',
                    '#' => '+',
                    else => c,
                };
                try writer.writeByte(n);
            }
        }
    };

    pub fn Sorter(comptime direction: enum { asc, desc }) type {
        return struct {
            lhs_buf: []const u8,
            rhs_buf: []const u8,
            pub fn lessThan(this: @This(), lhs: String, rhs: String) bool {
                return lhs.order(&rhs, this.lhs_buf, this.rhs_buf) == if (comptime direction == .asc) .lt else .gt;
            }
        };
    }

    pub inline fn order(
        lhs: *const String,
        rhs: *const String,
        lhs_buf: []const u8,
        rhs_buf: []const u8,
    ) std.math.Order {
        return std.mem.order(u8, lhs.slice(lhs_buf), rhs.slice(rhs_buf));
    }

    pub inline fn canInline(buf: []const u8) bool {
        return switch (buf.len) {
            0...max_inline_len - 1 => true,
            max_inline_len => buf[max_inline_len - 1] & 0x80 == 0,
            else => false,
        };
    }

    pub inline fn isInline(this: String) bool {
        return this.bytes[max_inline_len - 1] & 0x80 == 0;
    }

    // https://en.wikipedia.org/wiki/Intel_5-level_paging
    // https://developer.arm.com/documentation/101811/0101/Address-spaces-in-AArch64#:~:text=0%2DA%2C%20the%20maximum%20size,2%2DA.
    // X64 seems to need some of the pointer bits
    const max_addressable_space = u63;

    comptime {
        if (@sizeOf(usize) != 8) {
            @compileError("This code needs to be updated for non-64-bit architectures");
        }
    }

    pub const HashContext = struct {
        arg_buf: []const u8,
        existing_buf: []const u8,

        pub fn eql(ctx: HashContext, arg: String, existing: String) bool {
            return arg.eql(existing, ctx.arg_buf, ctx.existing_buf);
        }

        pub fn hash(ctx: HashContext, arg: String) u64 {
            const str = arg.slice(ctx.arg_buf);
            return bunCompatHash(str);
        }
    };

    pub const ArrayHashContext = struct {
        arg_buf: []const u8,
        existing_buf: []const u8,

        pub fn eql(ctx: ArrayHashContext, arg: String, existing: String, _: usize) bool {
            return arg.eql(existing, ctx.arg_buf, ctx.existing_buf);
        }

        pub fn hash(ctx: ArrayHashContext, arg: String) u32 {
            const str = arg.slice(ctx.arg_buf);
            return @as(u32, @truncate(bunCompatHash(str)));
        }
    };

    pub fn init(
        buf: string,
        in: string,
    ) String {
        return switch (in.len) {
            0 => String{},
            1 => String{ .bytes = .{ in[0], 0, 0, 0, 0, 0, 0, 0 } },
            2 => String{ .bytes = .{ in[0], in[1], 0, 0, 0, 0, 0, 0 } },
            3 => String{ .bytes = .{ in[0], in[1], in[2], 0, 0, 0, 0, 0 } },
            4 => String{ .bytes = .{ in[0], in[1], in[2], in[3], 0, 0, 0, 0 } },
            5 => String{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], 0, 0, 0 } },
            6 => String{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], 0, 0 } },
            7 => String{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], in[6], 0 } },
            max_inline_len =>
            // If they use the final bit, then it's a big string.
            // This should only happen for non-ascii strings that are exactly 8 bytes.
            // so that's an edge-case
            if ((in[max_inline_len - 1]) >= 128)
                reinterpret(String, ((@as(
                    u64,
                    0,
                ) | @as(
                    u64,
                    @as(
                        max_addressable_space,
                        @truncate(reinterpret(u64, Pointer.init(buf, in))),
                    ),
                )) | 1 << 63))
            else
                String{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], in[6], in[7] } },

            else => reinterpret(
                String,
                (@as(
                    u64,
                    0,
                ) | @as(
                    u64,
                    @as(
                        max_addressable_space,
                        @truncate(reinterpret(u64, Pointer.init(buf, in))),
                    ),
                )) | 1 << 63,
            ),
        };
    }

    pub fn initInline(
        in: string,
    ) String {
        home_rt.assert(canInline(in));
        return switch (in.len) {
            0 => .{},
            1 => .{ .bytes = .{ in[0], 0, 0, 0, 0, 0, 0, 0 } },
            2 => .{ .bytes = .{ in[0], in[1], 0, 0, 0, 0, 0, 0 } },
            3 => .{ .bytes = .{ in[0], in[1], in[2], 0, 0, 0, 0, 0 } },
            4 => .{ .bytes = .{ in[0], in[1], in[2], in[3], 0, 0, 0, 0 } },
            5 => .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], 0, 0, 0 } },
            6 => .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], 0, 0 } },
            7 => .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], in[6], 0 } },
            8 => .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], in[6], in[7] } },
            else => unreachable,
        };
    }

    pub fn initAppendIfNeeded(
        allocator: std.mem.Allocator,
        buf: *std.ArrayListUnmanaged(u8),
        in: string,
    ) OOM!String {
        return switch (in.len) {
            0 => .{},
            1 => .{ .bytes = .{ in[0], 0, 0, 0, 0, 0, 0, 0 } },
            2 => .{ .bytes = .{ in[0], in[1], 0, 0, 0, 0, 0, 0 } },
            3 => .{ .bytes = .{ in[0], in[1], in[2], 0, 0, 0, 0, 0 } },
            4 => .{ .bytes = .{ in[0], in[1], in[2], in[3], 0, 0, 0, 0 } },
            5 => .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], 0, 0, 0 } },
            6 => .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], 0, 0 } },
            7 => .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], in[6], 0 } },

            max_inline_len =>
            // If they use the final bit, then it's a big string.
            // This should only happen for non-ascii strings that are exactly 8 bytes.
            // so that's an edge-case
            if ((in[max_inline_len - 1]) >= 128)
                try initAppend(allocator, buf, in)
            else
                .{ .bytes = .{ in[0], in[1], in[2], in[3], in[4], in[5], in[6], in[7] } },

            else => try initAppend(allocator, buf, in),
        };
    }

    pub fn initAppend(
        allocator: std.mem.Allocator,
        buf: *std.ArrayListUnmanaged(u8),
        in: string,
    ) OOM!String {
        try buf.appendSlice(allocator, in);
        const in_buf = buf.items[buf.items.len - in.len ..];
        return reinterpret(String, ((@as(u64, 0) | @as(u64, @as(max_addressable_space, @truncate(reinterpret(u64, Pointer.init(buf.items, in_buf)))))) | 1 << 63));
    }

    pub fn eql(this: String, that: String, this_buf: []const u8, that_buf: []const u8) bool {
        if (this.isInline() and that.isInline()) {
            return @as(u64, @bitCast(this.bytes)) == @as(u64, @bitCast(that.bytes));
        } else if (this.isInline() != that.isInline()) {
            return false;
        } else {
            const a = this.ptr();
            const b = that.ptr();
            return std.mem.eql(u8, this_buf[a.off..][0..a.len], that_buf[b.off..][0..b.len]);
        }
    }

    pub inline fn isEmpty(this: String) bool {
        return @as(u64, @bitCast(this.bytes)) == @as(u64, 0);
    }

    pub fn len(this: String) usize {
        switch (this.bytes[max_inline_len - 1] & 128) {
            0 => {
                // Edgecase: string that starts with a 0 byte will be considered empty.
                switch (this.bytes[0]) {
                    0 => {
                        return 0;
                    },
                    else => {
                        comptime var i: usize = 0;

                        inline while (i < this.bytes.len) : (i += 1) {
                            if (this.bytes[i] == 0) return i;
                        }

                        return 8;
                    },
                }
            },
            else => {
                const ptr_ = this.ptr();
                return ptr_.len;
            },
        }
    }

    pub const Pointer = extern struct {
        off: u32 = 0,
        len: u32 = 0,

        pub inline fn init(
            buf: string,
            in: string,
        ) Pointer {
            if (Environment.allow_assert) {
                home_rt.assert(isSliceInBufferShim(in, buf));
            }

            return Pointer{
                .off = @as(u32, @truncate(@intFromPtr(in.ptr) - @intFromPtr(buf.ptr))),
                .len = @as(u32, @truncate(in.len)),
            };
        }
    };

    pub inline fn ptr(this: String) Pointer {
        return reinterpret(Pointer, (@as(u64, @as(u63, @truncate(reinterpret(u64, this))))));
    }

    // String must be a pointer because we reference it as a slice. It will become a dead pointer if it is copied.
    pub fn slice(this: *const String, buf: string) string {
        switch (this.bytes[max_inline_len - 1] & 128) {
            0 => {
                // Edgecase: string that starts with a 0 byte will be considered empty.
                switch (this.bytes[0]) {
                    0 => {
                        return "";
                    },
                    else => {
                        comptime var i: usize = 0;

                        inline while (i < this.bytes.len) : (i += 1) {
                            if (this.bytes[i] == 0) return this.bytes[0..i];
                        }

                        return &this.bytes;
                    },
                }
            },
            else => {
                const ptr_ = this.*.ptr();
                return buf[ptr_.off..][0..ptr_.len];
            },
        }
    }

    /// Hash for use by `Builder.stringHash`. Upstream lives on `Builder`;
    /// surfaced here as a free function so the trimmed port still exposes
    /// the canonical hash function callers (e.g. lockfile resolver) need.
    pub inline fn stringHash(buf: []const u8) u64 {
        return home_rt.wyhash.Wyhash11.hash(0, buf);
    }

    comptime {
        if (@sizeOf(String) != @sizeOf(Pointer)) {
            @compileError("String types must be the same size");
        }
    }
};

// ----------------------------------------------------------------------
// Home-rt compat shims. Upstream pulls these from `bun.*`; replicate them
// inline so this leaf only depends on `home_rt.Environment`, `home_rt.assert`,
// and `home_rt.wyhash.Wyhash11`.
// ----------------------------------------------------------------------

inline fn isSliceInBufferShim(slice: []const u8, buf: []const u8) bool {
    // Mirrors `bun.isSliceInBuffer`: true iff `slice` lies entirely within
    // `buf` (pointer-wise). Empty slices match any buffer (including empty).
    if (slice.len == 0) return true;
    const buf_start = @intFromPtr(buf.ptr);
    const buf_end = buf_start + buf.len;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    return slice_start >= buf_start and slice_end <= buf_end;
}

inline fn bunCompatHash(content: []const u8) u64 {
    return home_rt.wyhash.Wyhash11.hash(0, content);
}

const string = []const u8;

const std = @import("std");
const home_rt = @import("home");
const Environment = home_rt.Environment;
const OOM = home_rt.OOM;

test "String.empty is the zero value" {
    const s = String.empty;
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), s.len());
    try std.testing.expectEqualStrings("", s.slice(""));
}

test "String inline encoding round-trips ≤8-byte ASCII" {
    const cases = [_][]const u8{ "", "a", "abc", "ab cd ef", "12345678" };
    for (cases) |raw| {
        const s = String.init(raw, raw);
        try std.testing.expect(s.isInline());
        try std.testing.expectEqual(raw.len, s.len());
        try std.testing.expectEqualStrings(raw, s.slice(""));
    }
}

test "String.from comptime inline literal" {
    const s = String.from("abc");
    try std.testing.expect(s.isInline());
    try std.testing.expectEqualStrings("abc", s.slice(""));
}

test "String.init >8 bytes encodes as external pointer + slice round-trips" {
    const buf = "hello, world!";
    const s = String.init(buf, buf);
    try std.testing.expect(!s.isInline());
    try std.testing.expectEqual(buf.len, s.len());
    try std.testing.expectEqualStrings(buf, s.slice(buf));
}

test "String.canInline boundary at max_inline_len" {
    try std.testing.expect(String.canInline(""));
    try std.testing.expect(String.canInline("12345678")); // 8 ASCII bytes
    try std.testing.expect(!String.canInline("123456789")); // 9 bytes
    // 8 bytes with top bit set on last byte → must be external
    const high = [_]u8{ 'a', 'a', 'a', 'a', 'a', 'a', 'a', 0xFF };
    try std.testing.expect(!String.canInline(&high));
}

test "String.eql compares inline vs inline and external vs external" {
    const a = String.init("abc", "abc");
    const b = String.init("abc", "abc");
    try std.testing.expect(a.eql(b, "", ""));

    const buf1 = "hello, world!";
    const buf2 = "hello, world!";
    const x = String.init(buf1, buf1);
    const y = String.init(buf2, buf2);
    try std.testing.expect(x.eql(y, buf1, buf2));

    // inline vs external of same content: NOT equal — they use different storage.
    try std.testing.expect(!a.eql(x, "", buf1));
}

test "String.order computes lexical order via slice" {
    const a = String.init("abc", "abc");
    const b = String.init("abd", "abd");
    try std.testing.expectEqual(std.math.Order.lt, a.order(&b, "", ""));
    try std.testing.expectEqual(std.math.Order.gt, b.order(&a, "", ""));
    try std.testing.expectEqual(std.math.Order.eq, a.order(&a, "", ""));
}

test "String.Sorter sorts ascending and descending" {
    const ctx_asc = String.Sorter(.asc){ .lhs_buf = "", .rhs_buf = "" };
    try std.testing.expect(ctx_asc.lessThan(String.from("a"), String.from("b")));
    try std.testing.expect(!ctx_asc.lessThan(String.from("b"), String.from("a")));

    const ctx_desc = String.Sorter(.desc){ .lhs_buf = "", .rhs_buf = "" };
    try std.testing.expect(ctx_desc.lessThan(String.from("b"), String.from("a")));
    try std.testing.expect(!ctx_desc.lessThan(String.from("a"), String.from("b")));
}

test "String.HashContext + ArrayHashContext hash + eql" {
    const buf = "hello, world!";
    const s = String.init(buf, buf);
    const ctx = String.HashContext{ .arg_buf = buf, .existing_buf = buf };
    try std.testing.expectEqual(ctx.hash(s), ctx.hash(s));
    try std.testing.expect(ctx.eql(s, s));

    const ctx_array = String.ArrayHashContext{ .arg_buf = buf, .existing_buf = buf };
    try std.testing.expectEqual(ctx_array.hash(s), ctx_array.hash(s));
    try std.testing.expect(ctx_array.eql(s, s, 0));
}

test "String.initAppend + initAppendIfNeeded encode large strings via allocator" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const long = "this is a long string that does not fit inline";
    const s = try String.initAppend(std.testing.allocator, &buf, long);
    try std.testing.expect(!s.isInline());
    try std.testing.expectEqualStrings(long, s.slice(buf.items));
}

test "String layout is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(String));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(String.Pointer));
}

test "String.stringHash matches Wyhash11 with seed 0" {
    const want = home_rt.wyhash.Wyhash11.hash(0, "hello");
    try std.testing.expectEqual(want, String.stringHash("hello"));
}

test "String.Formatter writes the slice payload" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const s = String.init("abc", "abc");
    try (&s).fmt("").format(&w);
    try std.testing.expectEqualStrings("abc", w.buffered());
}

test "String.StorePathFormatter replaces /,\\,:,# with +" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const raw = "a/b\\c:d#e";
    const s = String.init(raw, raw);
    try (&s).fmtStorePath(raw).format(&w);
    try std.testing.expectEqualStrings("a+b+c+d+e", w.buffered());
}
