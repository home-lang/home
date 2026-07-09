/// Zig 0.17 forbids `@bitCast` on extern structs; this reinterprets the raw
/// bytes of `value` as `To` (same size), matching the old `@bitCast` semantics.
inline fn reinterpret(comptime To: type, value: anytype) To {
    return std.mem.bytesToValue(To, std.mem.asBytes(&value));
}

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

    pub inline fn fmtJson(self: *const String, buf: string, opts: anytype) @TypeOf(shim.fmt.formatJSONStringUTF8("", opts)) {
        return shim.fmt.formatJSONStringUTF8(self.slice(buf), opts);
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

        return reinterpret(String, (reinterpret(u64, Pointer.init(buf, in)) & std.math.maxInt(u63)) | (@as(u64, 1) << 63));
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
        return reinterpret(Pointer, reinterpret(u64, this) & std.math.maxInt(u63));
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

    pub inline fn sliced(this: *const String, buf: string) SlicedString {
        return if (this.isInline())
            SlicedString.init(this.slice(""), this.slice(""))
        else
            SlicedString.init(buf, this.slice(buf));
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

    pub fn arrayHashContext(lockfile: anytype, existing: ?string) ArrayHashContext {
        const buf = lockfile.buffers.string_bytes.items;
        return .{ .arg_buf = buf, .existing_buf = existing orelse buf };
    }

    /// Faithful port of upstream `bun.Semver.String.Builder`
    /// (`src/install_types/SemverString.zig`). Counts then bump-allocates a
    /// single backing buffer, interning long (> `max_inline_len`) strings
    /// through a `u64`-hash-keyed pool so identical slices share storage.
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

            if (Environment.allow_assert) {
                assert(this.len <= this.cap); // didn't count everything
                assert(this.ptr != null); // must call allocate first
            }

            copy(u8, this.ptr.?[this.len..this.cap], slice_);
            const final_slice = this.ptr.?[this.len..this.cap][0..slice_.len];
            this.len += slice_.len;

            if (Environment.allow_assert) assert(this.len <= this.cap);

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
            if (Environment.allow_assert) {
                assert(this.len <= this.cap); // didn't count everything
                assert(this.ptr != null); // must call allocate first
            }

            copy(u8, this.ptr.?[this.len..this.cap], slice_);
            const final_slice = this.ptr.?[this.len..this.cap][0..slice_.len];
            this.len += slice_.len;

            if (Environment.allow_assert) assert(this.len <= this.cap);

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

            if (Environment.allow_assert) {
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

            if (Environment.allow_assert) assert(this.len <= this.cap);

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

    pub const Buf = struct {
        bytes: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        pool: *Builder.StringPool,

        pub fn append(this: *Buf, input: string) OOM!String {
            return this.appendWithHash(input, Builder.stringHash(input));
        }

        pub fn appendExternal(this: *Buf, input: string) OOM!ExternalString {
            const hash = Builder.stringHash(input);
            return this.appendExternalWithHash(input, hash);
        }

        pub fn appendExternalWithHash(this: *Buf, input: string, hash: u64) OOM!ExternalString {
            return .{
                .value = try this.appendWithHash(input, hash),
                .hash = hash,
            };
        }

        pub fn appendWithHash(this: *Buf, input: string, hash: u64) OOM!String {
            if (input.len <= max_inline_len and strings.isAllASCII(input)) {
                return String.init(this.bytes.items, input);
            }

            const entry = try this.pool.getOrPut(hash);
            if (!entry.found_existing) {
                try this.bytes.appendSlice(this.allocator, input);
                const final = this.bytes.items[this.bytes.items.len - input.len ..];
                entry.value_ptr.* = String.init(this.bytes.items, final);
            }
            return entry.value_ptr.*;
        }
    };

    pub fn initAppendIfNeeded(
        allocator: std.mem.Allocator,
        buf: *std.ArrayListUnmanaged(u8),
        input: string,
    ) OOM!String {
        if (input.len <= max_inline_len and strings.isAllASCII(input)) {
            return String.init(buf.items, input);
        }
        return initAppend(allocator, buf, input);
    }

    pub fn initAppend(
        allocator: std.mem.Allocator,
        buf: *std.ArrayListUnmanaged(u8),
        input: string,
    ) OOM!String {
        try buf.appendSlice(allocator, input);
        const final = buf.items[buf.items.len - input.len ..];
        return String.init(buf.items, final);
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
const OOM = error{OutOfMemory};
const Wyhash11 = std.hash.Wyhash;
const shim = @import("shim.zig");
const Environment = shim.Environment;
const assert = shim.assert;
const copy = shim.copy;
const IdentityContext = shim.IdentityContext;
const strings = shim.strings;
const ExternalString = @import("ExternalString.zig").ExternalString;
const SlicedString = @import("SlicedString.zig");

test "Semver String.Builder.stringHash matches Wyhash11 seed 0" {
    try std.testing.expectEqual(
        Wyhash11.hash(0, "left-pad"),
        String.Builder.stringHash("left-pad"),
    );
}

test "Semver String.Builder counts, allocates, and interns long strings" {
    const long_a = "a-fairly-long-package-name-over-eight-bytes";
    const long_b = "another-distinct-long-package-name-here";

    var builder = String.Builder{
        .string_pool = String.Builder.StringPool.init(std.testing.allocator),
    };
    defer builder.string_pool.deinit();

    // Count the two distinct long strings; the buffer must reserve exactly
    // their combined length (long strings are not inlined).
    builder.count(long_a);
    builder.count(long_b);
    try std.testing.expectEqual(@as(usize, long_a.len + long_b.len), builder.cap);

    try builder.allocate(std.testing.allocator);
    defer std.testing.allocator.free(builder.ptr.?[0..builder.cap]);

    const sa = builder.append(String, long_a);
    const sb = builder.append(String, long_b);
    // Appending a duplicate of long_a reuses the interned pool entry rather
    // than copying again — the returned String points at the same storage.
    const sa_again = builder.append(String, long_a);

    const buf = builder.allocatedSlice();
    try std.testing.expectEqualStrings(long_a, (&sa).slice(buf));
    try std.testing.expectEqualStrings(long_b, (&sb).slice(buf));
    try std.testing.expectEqual(@as(u64, @bitCast(sa.bytes)), @as(u64, @bitCast(sa_again.bytes)));
}

test "Semver String.Builder inlines short strings without buffer growth" {
    var builder = String.Builder{};
    builder.count("npm"); // <= max_inline_len, no allocation needed
    try std.testing.expectEqual(@as(usize, 0), builder.cap);

    const s = builder.appendWithoutPool(String, "npm", String.Builder.stringHash("npm"));
    try std.testing.expect(s.isInline());
    try std.testing.expectEqualStrings("npm", (&s).slice(""));
}
