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

    pub const ArrayHashContext = struct {
        arg_buf: string,
        existing_buf: string,

        pub fn hash(this: ArrayHashContext, value: String) u32 {
            return @truncate(String.stringHash(value.slice(this.arg_buf)));
        }

        pub fn eql(this: ArrayHashContext, a: String, b: String, _: usize) bool {
            return a.eql(b, this.arg_buf, this.existing_buf);
        }
    };

    // Faithful port of upstream `Semver.String.Builder`
    // (bun/src/install_types/SemverString.zig). Two-pass string interner:
    // `count`/`countWithHash` size the backing buffer, `allocate` reserves
    // it, then the `append*` family copies non-inline strings in and hands
    // back `String`/`ExternalString` handles into that buffer.
    pub const Builder = struct {
        len: usize = 0,
        cap: usize = 0,
        ptr: ?[*]u8 = null,
        string_pool: StringPool = undefined,

        pub const StringPool = std.HashMap(u64, String, IdentityContext(u64), 80);

        pub inline fn stringHash(buf: []const u8) u64 {
            return Wyhash11.hash(0, buf);
        }

        pub inline fn count(this: *Builder, slice_: string) void {
            return countWithHash(this, slice_, if (slice_.len >= String.max_inline_len) Builder.stringHash(slice_) else std.math.maxInt(u64));
        }

        pub inline fn countWithHash(this: *Builder, slice_: string, hash: u64) void {
            if (slice_.len <= String.max_inline_len) return;

            if (!this.string_pool.contains(hash)) {
                this.cap += slice_.len;
            }
        }

        pub inline fn allocatedSlice(this: *Builder) []u8 {
            return if (this.cap > 0)
                this.ptr.?[0..this.cap]
            else
                &[_]u8{};
        }

        pub fn allocate(this: *Builder, allocator: Allocator) !void {
            const ptr_ = try allocator.alloc(u8, this.cap);
            this.ptr = ptr_.ptr;
        }

        pub fn append(this: *Builder, comptime Type: type, slice_: string) Type {
            return appendWithHash(this, Type, slice_, Builder.stringHash(slice_));
        }

        pub fn appendUTF8WithoutPool(this: *Builder, comptime Type: type, slice_: string, hash: u64) Type {
            if (slice_.len <= String.max_inline_len) {
                if (strings.isAllASCII(slice_)) {
                    switch (Type) {
                        String => {
                            return String.init(this.allocatedSlice(), slice_);
                        },
                        ExternalString => {
                            return ExternalString.init(this.allocatedSlice(), slice_, hash);
                        },
                        else => @compileError("Invalid type passed to StringBuilder"),
                    }
                }
            }

            if (comptime Environment.allow_assert) {
                assert(this.len <= this.cap); // didn't count everything
                assert(this.ptr != null); // must call allocate first
            }

            copy(u8, this.ptr.?[this.len..this.cap], slice_);
            const final_slice = this.ptr.?[this.len..this.cap][0..slice_.len];
            this.len += slice_.len;

            if (comptime Environment.allow_assert) assert(this.len <= this.cap);

            switch (Type) {
                String => {
                    return String.init(this.allocatedSlice(), final_slice);
                },
                ExternalString => {
                    return ExternalString.init(this.allocatedSlice(), final_slice, hash);
                },
                else => @compileError("Invalid type passed to StringBuilder"),
            }
        }

        // SlicedString is not supported due to inline strings.
        pub fn appendWithoutPool(this: *Builder, comptime Type: type, slice_: string, hash: u64) Type {
            if (slice_.len <= String.max_inline_len) {
                switch (Type) {
                    String => {
                        return String.init(this.allocatedSlice(), slice_);
                    },
                    ExternalString => {
                        return ExternalString.init(this.allocatedSlice(), slice_, hash);
                    },
                    else => @compileError("Invalid type passed to StringBuilder"),
                }
            }
            if (comptime Environment.allow_assert) {
                assert(this.len <= this.cap); // didn't count everything
                assert(this.ptr != null); // must call allocate first
            }

            copy(u8, this.ptr.?[this.len..this.cap], slice_);
            const final_slice = this.ptr.?[this.len..this.cap][0..slice_.len];
            this.len += slice_.len;

            if (comptime Environment.allow_assert) assert(this.len <= this.cap);

            switch (Type) {
                String => {
                    return String.init(this.allocatedSlice(), final_slice);
                },
                ExternalString => {
                    return ExternalString.init(this.allocatedSlice(), final_slice, hash);
                },
                else => @compileError("Invalid type passed to StringBuilder"),
            }
        }

        pub fn appendWithHash(this: *Builder, comptime Type: type, slice_: string, hash: u64) Type {
            if (slice_.len <= String.max_inline_len) {
                switch (Type) {
                    String => {
                        return String.init(this.allocatedSlice(), slice_);
                    },
                    ExternalString => {
                        return ExternalString.init(this.allocatedSlice(), slice_, hash);
                    },
                    else => @compileError("Invalid type passed to StringBuilder"),
                }
            }

            if (comptime Environment.allow_assert) {
                assert(this.len <= this.cap); // didn't count everything
                assert(this.ptr != null); // must call allocate first
            }

            const string_entry = this.string_pool.getOrPut(hash) catch unreachable;
            if (!string_entry.found_existing) {
                copy(u8, this.ptr.?[this.len..this.cap], slice_);
                const final_slice = this.ptr.?[this.len..this.cap][0..slice_.len];
                this.len += slice_.len;

                string_entry.value_ptr.* = String.init(this.allocatedSlice(), final_slice);
            }

            if (comptime Environment.allow_assert) assert(this.len <= this.cap);

            switch (Type) {
                String => {
                    return string_entry.value_ptr.*;
                },
                ExternalString => {
                    return ExternalString{
                        .value = string_entry.value_ptr.*,
                        .hash = hash,
                    };
                },
                else => @compileError("Invalid type passed to StringBuilder"),
            }
        }
    };

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

test "Semver String.Builder interns non-inline strings into one buffer" {
    const testing = std.testing;

    var builder = String.Builder{};
    builder.string_pool = String.Builder.StringPool.init(testing.allocator);
    defer builder.string_pool.deinit();

    // Inline (<= max_inline_len) strings never touch the backing buffer.
    const short = "short"; // 5 bytes
    const long = "this-is-a-very-long-package-name";

    // Matching upstream: `count` does not populate the pool, so it reserves
    // capacity for every non-inline occurrence; the dedupe happens only at
    // append time via the string pool.
    builder.count(short);
    builder.count(long);
    builder.count(long);

    try testing.expectEqual(@as(usize, long.len * 2), builder.cap);

    try builder.allocate(testing.allocator);
    defer testing.allocator.free(builder.allocatedSlice());

    const a = builder.append(String, short);
    try testing.expect(a.isInline());
    try testing.expectEqualStrings(short, a.slice(builder.allocatedSlice()));

    const b = builder.append(String, long);
    try testing.expect(!b.isInline());
    try testing.expectEqualStrings(long, b.slice(builder.allocatedSlice()));
    try testing.expectEqual(@as(usize, long.len), builder.len);

    // Re-appending the same long string returns the pooled handle and does
    // NOT copy the bytes again, so used length stays at a single copy.
    const c = builder.append(String, long);
    try testing.expectEqualStrings(long, c.slice(builder.allocatedSlice()));
    try testing.expectEqual(@as(usize, long.len), builder.len);
}

test "Semver String.Builder.stringHash matches Wyhash11" {
    try std.testing.expectEqual(
        Wyhash11.hash(0, "package"),
        String.Builder.stringHash("package"),
    );
}

const string = []const u8;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environment = @import("shim.zig").Environment;
const assert = @import("shim.zig").assert;
const copy = @import("shim.zig").copy;
const ExternalString = @import("ExternalString.zig").ExternalString;
const IdentityContext = @import("../collections/identity_context.zig").IdentityContext;
const Wyhash11 = @import("../wyhash/wyhash.zig").Wyhash11;
const strings = struct {
    pub const isAllASCII = @import("../strings.zig").isAllASCII;
};
