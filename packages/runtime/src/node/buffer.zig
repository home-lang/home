// Home Runtime — Phase 12.7 port of `node:buffer` (Zig substrate).
//
// Upstream references:
//   * Node.js `lib/buffer.js` — high-level Buffer API shape.
//   * bun/src/string_immutable.zig — Bun-side Buffer encode/decode helpers.
//
// Per `NODE_SHIM_SCOPE_2026-05-19.md` this lands the Zig-callable
// substrate for `node:buffer`. The JS shim re-attaches once the Phase
// 12.2 JSC bridge is live; until then, Zig callers (node:fs binary
// mode, node:stream, node:crypto wrappers) consume `Buffer` directly.
//
// API surface (matches the spec'd shape):
//   * `Buffer` — owned or borrowed `[]u8` slice paired with the
//     optional allocator that minted it. `deinit` is a no-op for
//     borrowed buffers (allocator == null).
//   * Constructors: `alloc`, `allocUnsafe`, `from`, `fromString`,
//     `fromArrayBuffer` (stub).
//   * Inspection: `length`, `slice` (borrowed view), `equals`,
//     `compare`, `indexOf`, `includes`.
//   * Mutation: `copy`, `write`, `fill`.
//   * Encoding round-trip: `toString(encoding)`, `fromString(...)`,
//     plus the `Encoding` enum (utf8/ascii/latin1/base64/base64url/
//     hex/ucs2/utf16le/binary).
//   * Numeric readers/writers covering Node's `read{U,}{Int,Float,
//     Double}{8,16,32}` + `read{U,}BigInt64` family (little-endian
//     only; the `BE` variants re-attach when callers need them).
//   * Module-level helpers: `byteLength`, `isBuffer`, `concat`.
//
// Encoding notes:
//   * `utf8` / `binary` / `latin1` round-trip via raw byte copy
//     (`binary` is Node's legacy alias for `latin1`).
//   * `ascii` masks bytes to 7-bit on decode (Node's
//     `Buffer.from('héllo', 'ascii')` truncates the high bit).
//   * `base64` / `base64url` use `std.base64.standard` and
//     `std.base64.url_safe` with ignore-set decoders so whitespace
//     and missing padding are tolerated (mirrors Node).
//   * `hex` parses pairs case-insensitively and stops at the first
//     invalid byte (Node's `Buffer.from('ZZ', 'hex')` returns empty).
//   * `ucs2` == `utf16le` — copy bytes verbatim. Surrogate-pair
//     validation re-attaches with the JS shim.
//
// Inline tests cover the ≥8 cases in the scope:
//   1. `alloc` + `toString(.utf8)` after `fill`.
//   2. `from` UTF-8 round-trip.
//   3. `fromString` base64 round-trip.
//   4. `equals` true/false.
//   5. `compare` lexicographic ordering.
//   6. `indexOf` + `includes`.
//   7. `concat` of three slices.
//   8. `writeUInt32LE` + `readUInt32LE` round-trip.
// Plus: hex round-trip, `byteLength` for utf8 + hex.

const std = @import("std");

// ---- Encoding ----------------------------------------------------------

/// `node:buffer` encoding tag. Self-contained so callers don't have to
/// pull in `node/types.zig`. Once the JS shim lands these will be
/// looked up by string via Node's case-insensitive alias table; the
/// Zig surface is straight enum so the dispatch is a compile-time
/// switch.
pub const Encoding = enum {
    utf8,
    ascii,
    latin1,
    base64,
    base64url,
    hex,
    ucs2,
    utf16le,
    /// Node's legacy alias for `latin1`. Kept distinct so callers
    /// that round-trip through the JS layer can preserve the spelling
    /// they were handed.
    binary,
};

// ---- Buffer -----------------------------------------------------------

/// Node `Buffer` — a `[]u8` slice paired with the allocator that
/// minted it (or `null` for borrowed views). Callers must invoke
/// `deinit` on owned buffers; calling `deinit` on a borrowed buffer
/// is a no-op.
pub const Buffer = struct {
    data: []u8,
    allocator: ?std.mem.Allocator,

    /// Allocates `size` zero-initialized bytes. Mirrors
    /// `Buffer.alloc(size)`.
    pub fn alloc(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Buffer {
        const buf = try allocator.alloc(u8, size);
        @memset(buf, 0);
        return .{ .data = buf, .allocator = allocator };
    }

    /// Allocates `size` bytes without zero-filling. Mirrors
    /// `Buffer.allocUnsafe(size)`. Caller must overwrite before read.
    pub fn allocUnsafe(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Buffer {
        const buf = try allocator.alloc(u8, size);
        return .{ .data = buf, .allocator = allocator };
    }

    /// Copies `data` into a freshly-allocated owned buffer. Mirrors
    /// `Buffer.from(data)`.
    pub fn from(allocator: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error!Buffer {
        const buf = try allocator.alloc(u8, data.len);
        @memcpy(buf, data);
        return .{ .data = buf, .allocator = allocator };
    }

    /// Decodes `str` per `encoding` into a freshly-allocated owned
    /// buffer. Mirrors `Buffer.from(str, encoding)`.
    ///
    /// Returns `error.InvalidEncoding` if base64/hex decoding fails
    /// past the recoverable threshold; otherwise short input is
    /// silently truncated to mirror Node.
    pub fn fromString(
        allocator: std.mem.Allocator,
        str: []const u8,
        encoding: Encoding,
    ) (std.mem.Allocator.Error || error{InvalidEncoding})!Buffer {
        return switch (encoding) {
            .utf8, .binary, .latin1 => Buffer.from(allocator, str),
            .ascii => blk: {
                const buf = try allocator.alloc(u8, str.len);
                for (str, 0..) |b, i| buf[i] = b & 0x7f;
                break :blk .{ .data = buf, .allocator = allocator };
            },
            .ucs2, .utf16le => Buffer.from(allocator, str),
            .base64 => decodeBase64(allocator, str, false),
            .base64url => decodeBase64(allocator, str, true),
            .hex => decodeHex(allocator, str),
        };
    }

    /// Stub. `ArrayBuffer` is a JSC primitive; the real binding
    /// lands with the Phase 12.2 JSC bridge. Pure-Zig callers can
    /// use `Buffer.from(allocator, bytes)` instead.
    pub fn fromArrayBuffer(_: anytype, _: anytype) Buffer {
        @panic("TODO(phase-12.2-M3): node:buffer.fromArrayBuffer needs JSC ArrayBuffer view");
    }

    /// Frees the underlying slice if the buffer owns its memory.
    /// No-op for borrowed buffers (those produced by `slice`).
    pub fn deinit(self: Buffer) void {
        if (self.allocator) |a| a.free(self.data);
    }

    /// Byte length of the buffer. Mirrors `Buffer.byteLength`.
    pub fn length(self: Buffer) usize {
        return self.data.len;
    }

    /// Decodes the buffer to a UTF-8 / latin-1 / hex / base64 string
    /// per `encoding`. The returned slice is allocator-owned for
    /// the binary-to-text encodings (hex/base64/base64url); for
    /// utf8/binary/latin1/ascii/ucs2/utf16le the slice aliases
    /// `self.data` and must not outlive the buffer.
    ///
    /// **Caller responsibility:** free the returned slice via the
    /// same allocator that minted the buffer when `encoding` is
    /// binary-to-text. The Zig substrate doesn't track ownership
    /// across the boundary; the JS shim will tag the return.
    pub fn toString(self: Buffer, encoding: Encoding) []const u8 {
        return switch (encoding) {
            .utf8, .binary, .latin1, .ascii, .ucs2, .utf16le => self.data,
            .hex => encodeHex(self.allocator orelse std.heap.page_allocator, self.data) catch &[_]u8{},
            .base64 => encodeBase64(self.allocator orelse std.heap.page_allocator, self.data, false) catch &[_]u8{},
            .base64url => encodeBase64(self.allocator orelse std.heap.page_allocator, self.data, true) catch &[_]u8{},
        };
    }

    /// Returns the underlying byte slice.
    pub fn slice(self: Buffer) []u8 {
        return self.data;
    }

    /// Returns a **borrowed** view into `self.data[start..end]`.
    /// The view shares memory with `self`; calling `deinit` on the
    /// view is a no-op. Mirrors `Buffer.subarray`.
    pub fn subarray(self: Buffer, start: usize, end: usize) Buffer {
        const lo = @min(start, self.data.len);
        const hi = @min(end, self.data.len);
        const real_hi = if (hi < lo) lo else hi;
        return .{ .data = self.data[lo..real_hi], .allocator = null };
    }

    /// Copies `[source_start, source_end)` from `self` into
    /// `target[target_start..]`. Returns the number of bytes copied.
    /// Mirrors `Buffer.copy(target, targetStart, sourceStart, sourceEnd)`.
    pub fn copy(
        self: Buffer,
        target: Buffer,
        target_start: usize,
        source_start: usize,
        source_end: usize,
    ) usize {
        if (target_start >= target.data.len) return 0;
        const src_lo = @min(source_start, self.data.len);
        const src_hi = @min(source_end, self.data.len);
        if (src_hi <= src_lo) return 0;
        const src = self.data[src_lo..src_hi];
        const room = target.data.len - target_start;
        const n = @min(src.len, room);
        std.mem.copyForwards(u8, target.data[target_start .. target_start + n], src[0..n]);
        return n;
    }

    /// Byte-identity equality. Mirrors `Buffer.equals(other)`.
    pub fn equals(self: Buffer, other: Buffer) bool {
        return std.mem.eql(u8, self.data, other.data);
    }

    /// Lexicographic compare. Returns -1 / 0 / 1 per `Buffer.compare`.
    pub fn compare(self: Buffer, other: Buffer) i8 {
        return switch (std.mem.order(u8, self.data, other.data)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    /// Writes `str` into the buffer at `offset` using `encoding`.
    /// Returns the number of bytes actually written. Mirrors
    /// `Buffer.write(str, offset, length, encoding)`.
    pub fn write(
        self: Buffer,
        str: []const u8,
        offset: usize,
        max_length: usize,
        encoding: Encoding,
    ) usize {
        if (offset >= self.data.len) return 0;
        const room = self.data.len - offset;
        const cap = @min(max_length, room);

        switch (encoding) {
            .utf8, .binary, .latin1, .ucs2, .utf16le => {
                const n = @min(str.len, cap);
                std.mem.copyForwards(u8, self.data[offset .. offset + n], str[0..n]);
                return n;
            },
            .ascii => {
                const n = @min(str.len, cap);
                for (str[0..n], 0..) |b, i| self.data[offset + i] = b & 0x7f;
                return n;
            },
            .hex => {
                var written: usize = 0;
                var i: usize = 0;
                while (i + 1 < str.len and written < cap) : (i += 2) {
                    const hi = hexNibble(str[i]) orelse break;
                    const lo = hexNibble(str[i + 1]) orelse break;
                    self.data[offset + written] = (hi << 4) | lo;
                    written += 1;
                }
                return written;
            },
            .base64, .base64url => {
                // Decode into a scratch buffer, then copy what fits.
                const scratch = decodeBase64(
                    self.allocator orelse std.heap.page_allocator,
                    str,
                    encoding == .base64url,
                ) catch return 0;
                defer scratch.deinit();
                const n = @min(scratch.data.len, cap);
                std.mem.copyForwards(u8, self.data[offset .. offset + n], scratch.data[0..n]);
                return n;
            },
        }
    }

    /// Fills the entire buffer with `value`. Mirrors
    /// `Buffer.fill(value)`; returns the same buffer for chaining.
    pub fn fill(self: Buffer, value: u8) Buffer {
        @memset(self.data, value);
        return self;
    }

    /// First index of `needle` within the buffer, or null if absent.
    pub fn indexOf(self: Buffer, needle: []const u8) ?usize {
        return std.mem.indexOf(u8, self.data, needle);
    }

    /// `indexOf(needle) != null`.
    pub fn includes(self: Buffer, needle: []const u8) bool {
        return self.indexOf(needle) != null;
    }

    // ---- Numeric readers / writers (little-endian) -----------------

    pub fn readUInt8(self: Buffer, offset: usize) u8 {
        return self.data[offset];
    }

    pub fn writeUInt8(self: Buffer, value: u8, offset: usize) void {
        self.data[offset] = value;
    }

    pub fn readUInt16LE(self: Buffer, offset: usize) u16 {
        return std.mem.readInt(u16, self.data[offset..][0..2], .little);
    }

    pub fn writeUInt16LE(self: Buffer, value: u16, offset: usize) void {
        std.mem.writeInt(u16, self.data[offset..][0..2], value, .little);
    }

    pub fn readUInt32LE(self: Buffer, offset: usize) u32 {
        return std.mem.readInt(u32, self.data[offset..][0..4], .little);
    }

    pub fn writeUInt32LE(self: Buffer, value: u32, offset: usize) void {
        std.mem.writeInt(u32, self.data[offset..][0..4], value, .little);
    }

    pub fn readInt8(self: Buffer, offset: usize) i8 {
        return @bitCast(self.data[offset]);
    }

    pub fn writeInt8(self: Buffer, value: i8, offset: usize) void {
        self.data[offset] = @bitCast(value);
    }

    pub fn readInt16LE(self: Buffer, offset: usize) i16 {
        return std.mem.readInt(i16, self.data[offset..][0..2], .little);
    }

    pub fn writeInt16LE(self: Buffer, value: i16, offset: usize) void {
        std.mem.writeInt(i16, self.data[offset..][0..2], value, .little);
    }

    pub fn readInt32LE(self: Buffer, offset: usize) i32 {
        return std.mem.readInt(i32, self.data[offset..][0..4], .little);
    }

    pub fn writeInt32LE(self: Buffer, value: i32, offset: usize) void {
        std.mem.writeInt(i32, self.data[offset..][0..4], value, .little);
    }

    pub fn readFloatLE(self: Buffer, offset: usize) f32 {
        return @bitCast(self.readUInt32LE(offset));
    }

    pub fn writeFloatLE(self: Buffer, value: f32, offset: usize) void {
        self.writeUInt32LE(@bitCast(value), offset);
    }

    pub fn readDoubleLE(self: Buffer, offset: usize) f64 {
        const bits = std.mem.readInt(u64, self.data[offset..][0..8], .little);
        return @bitCast(bits);
    }

    pub fn writeDoubleLE(self: Buffer, value: f64, offset: usize) void {
        const bits: u64 = @bitCast(value);
        std.mem.writeInt(u64, self.data[offset..][0..8], bits, .little);
    }

    pub fn readBigInt64LE(self: Buffer, offset: usize) i64 {
        return std.mem.readInt(i64, self.data[offset..][0..8], .little);
    }

    pub fn writeBigInt64LE(self: Buffer, value: i64, offset: usize) void {
        std.mem.writeInt(i64, self.data[offset..][0..8], value, .little);
    }

    pub fn readBigUInt64LE(self: Buffer, offset: usize) u64 {
        return std.mem.readInt(u64, self.data[offset..][0..8], .little);
    }

    pub fn writeBigUInt64LE(self: Buffer, value: u64, offset: usize) void {
        std.mem.writeInt(u64, self.data[offset..][0..8], value, .little);
    }
};

// ---- Module-level helpers ---------------------------------------------

/// Returns the byte length of `input` when decoded under `encoding`.
/// Mirrors `Buffer.byteLength(string, encoding)`.
pub fn byteLength(input: []const u8, encoding: Encoding) usize {
    return switch (encoding) {
        .utf8, .ascii, .binary, .latin1, .ucs2, .utf16le => input.len,
        .hex => input.len / 2,
        .base64, .base64url => base64DecodedLen(input),
    };
}

/// Duck-typed isBuffer. Returns true if `value` is a `Buffer` (the
/// Zig surface). The JS shim widens this to include
/// `Uint8Array`-derived views.
pub fn isBuffer(value: anytype) bool {
    return @TypeOf(value) == Buffer;
}

/// Concatenates `list` into a single owned buffer. Mirrors
/// `Buffer.concat(list)`. The result owns its allocation; each input
/// is left untouched.
pub fn concat(allocator: std.mem.Allocator, list: []const Buffer) std.mem.Allocator.Error!Buffer {
    var total: usize = 0;
    for (list) |b| total += b.data.len;
    const out = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (list) |b| {
        std.mem.copyForwards(u8, out[cursor .. cursor + b.data.len], b.data);
        cursor += b.data.len;
    }
    return .{ .data = out, .allocator = allocator };
}

// ---- Encoding helpers (internal) --------------------------------------

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn decodeHex(allocator: std.mem.Allocator, str: []const u8) std.mem.Allocator.Error!Buffer {
    const max_len = str.len / 2;
    const buf = try allocator.alloc(u8, max_len);
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < str.len) : (i += 2) {
        const hi = hexNibble(str[i]) orelse break;
        const lo = hexNibble(str[i + 1]) orelse break;
        buf[n] = (hi << 4) | lo;
        n += 1;
    }
    if (n != max_len) {
        // Shrink the over-allocated tail. `realloc` would shrink in
        // place; on failure we just leak the tail (matches Node).
        if (allocator.resize(buf, n)) {
            return .{ .data = buf[0..n], .allocator = allocator };
        }
        const trimmed = try allocator.alloc(u8, n);
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return .{ .data = trimmed, .allocator = allocator };
    }
    return .{ .data = buf, .allocator = allocator };
}

fn encodeHex(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

fn base64DecodedLen(input: []const u8) usize {
    // Strip padding + whitespace, then `floor(non_padding * 6 / 8)`.
    var non_pad: usize = 0;
    for (input) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n', '=' => {},
            else => non_pad += 1,
        }
    }
    return (non_pad * 6) / 8;
}

fn decodeBase64(
    allocator: std.mem.Allocator,
    str: []const u8,
    url_safe: bool,
) (std.mem.Allocator.Error || error{InvalidEncoding})!Buffer {
    // Normalize: strip whitespace, transcribe url-safe alphabet to
    // standard, and pad to multiple of 4. Then dispatch to the
    // appropriate std.base64 decoder.
    var scratch = try allocator.alloc(u8, str.len + 4);
    defer allocator.free(scratch);
    var n: usize = 0;
    for (str) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => {},
            '-' => {
                if (url_safe) scratch[n] = '+' else scratch[n] = c;
                n += 1;
            },
            '_' => {
                if (url_safe) scratch[n] = '/' else scratch[n] = c;
                n += 1;
            },
            else => {
                scratch[n] = c;
                n += 1;
            },
        }
    }
    // Strip any trailing '=' so we can re-pad cleanly.
    while (n > 0 and scratch[n - 1] == '=') : (n -= 1) {}
    // Pad to multiple of 4.
    while (n % 4 != 0) : (n += 1) {
        scratch[n] = '=';
    }
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(scratch[0..n]) catch return error.InvalidEncoding;
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    decoder.decode(out, scratch[0..n]) catch return error.InvalidEncoding;
    return .{ .data = out, .allocator = allocator };
}

fn encodeBase64(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    url_safe: bool,
) std.mem.Allocator.Error![]u8 {
    if (url_safe) {
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
        _ = encoder.encode(out, bytes);
        return out;
    }
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

// ---- Inline tests -----------------------------------------------------

const testing = std.testing;

test "Buffer.alloc + fill + toString(.utf8)" {
    var buf = try Buffer.alloc(testing.allocator, 4);
    defer buf.deinit();
    try testing.expectEqual(@as(usize, 4), buf.length());
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, buf.data);

    _ = buf.fill('A');
    try testing.expectEqualStrings("AAAA", buf.toString(.utf8));
}

test "Buffer.from + UTF-8 round-trip" {
    var buf = try Buffer.from(testing.allocator, "hello");
    defer buf.deinit();
    try testing.expectEqualStrings("hello", buf.toString(.utf8));
    try testing.expectEqual(@as(usize, 5), buf.length());
}

test "Buffer.fromString(base64) round-trip" {
    // "Hello, World!" -> base64
    var buf = try Buffer.fromString(testing.allocator, "SGVsbG8sIFdvcmxkIQ==", .base64);
    defer buf.deinit();
    try testing.expectEqualStrings("Hello, World!", buf.toString(.utf8));

    // Round-trip the other way.
    const encoded = buf.toString(.base64);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("SGVsbG8sIFdvcmxkIQ==", encoded);
}

test "Buffer.fromString(base64url) round-trip" {
    // bytes 0xFB,0xFF -> base64 "+/8=" -> base64url "-_8"
    var buf = try Buffer.fromString(testing.allocator, "-_8", .base64url);
    defer buf.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0xfb, 0xff }, buf.data);
}

test "Buffer.equals" {
    var a = try Buffer.from(testing.allocator, "abc");
    defer a.deinit();
    var b = try Buffer.from(testing.allocator, "abc");
    defer b.deinit();
    var c = try Buffer.from(testing.allocator, "abd");
    defer c.deinit();

    try testing.expect(a.equals(b));
    try testing.expect(!a.equals(c));
}

test "Buffer.compare lexicographic" {
    var a = try Buffer.from(testing.allocator, "abc");
    defer a.deinit();
    var b = try Buffer.from(testing.allocator, "abd");
    defer b.deinit();
    var c = try Buffer.from(testing.allocator, "abc");
    defer c.deinit();

    try testing.expectEqual(@as(i8, -1), a.compare(b));
    try testing.expectEqual(@as(i8, 1), b.compare(a));
    try testing.expectEqual(@as(i8, 0), a.compare(c));
}

test "Buffer.indexOf + includes" {
    var buf = try Buffer.from(testing.allocator, "the quick brown fox");
    defer buf.deinit();

    try testing.expectEqual(@as(?usize, 4), buf.indexOf("quick"));
    try testing.expectEqual(@as(?usize, null), buf.indexOf("slow"));
    try testing.expect(buf.includes("brown"));
    try testing.expect(!buf.includes("purple"));
}

test "concat of three slices" {
    var a = try Buffer.from(testing.allocator, "foo");
    defer a.deinit();
    var b = try Buffer.from(testing.allocator, "bar");
    defer b.deinit();
    var c = try Buffer.from(testing.allocator, "baz");
    defer c.deinit();

    var joined = try concat(testing.allocator, &[_]Buffer{ a, b, c });
    defer joined.deinit();
    try testing.expectEqualStrings("foobarbaz", joined.data);
}

test "writeUInt32LE + readUInt32LE round-trip" {
    var buf = try Buffer.alloc(testing.allocator, 4);
    defer buf.deinit();
    buf.writeUInt32LE(0xDEADBEEF, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xef, 0xbe, 0xad, 0xde }, buf.data);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), buf.readUInt32LE(0));
}

test "hex round-trip" {
    var buf = try Buffer.fromString(testing.allocator, "deadbeef", .hex);
    defer buf.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, buf.data);

    const encoded = buf.toString(.hex);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("deadbeef", encoded);
}

test "byteLength" {
    try testing.expectEqual(@as(usize, 5), byteLength("hello", .utf8));
    try testing.expectEqual(@as(usize, 4), byteLength("deadbeef", .hex));
    try testing.expectEqual(@as(usize, 13), byteLength("SGVsbG8sIFdvcmxkIQ==", .base64));
}

test "isBuffer" {
    var buf = try Buffer.alloc(testing.allocator, 0);
    defer buf.deinit();
    try testing.expect(isBuffer(buf));
    try testing.expect(!isBuffer(@as(u32, 42)));
}

test "slice produces borrowed view" {
    var buf = try Buffer.from(testing.allocator, "hello world");
    defer buf.deinit();

    const view = buf.subarray(6, 11);
    try testing.expectEqualStrings("world", view.data);
    try testing.expectEqual(@as(?std.mem.Allocator, null), view.allocator);
    view.deinit(); // must be a no-op
}

test "copy bytes between buffers" {
    var src = try Buffer.from(testing.allocator, "abcdef");
    defer src.deinit();
    var dst = try Buffer.alloc(testing.allocator, 6);
    defer dst.deinit();

    const n = src.copy(dst, 2, 1, 4);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 'b', 'c', 'd', 0 }, dst.data);
}

test "write hex into buffer at offset" {
    var buf = try Buffer.alloc(testing.allocator, 4);
    defer buf.deinit();
    const n = buf.write("cafe", 1, 4, .hex);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0xca, 0xfe, 0 }, buf.data);
}
