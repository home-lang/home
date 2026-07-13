// Copied verbatim from bun/src/sourcemap/VLQ.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten:
//   `@import("bun")`  → `@import("home")`
//   `bun.assert`      → `home_rt.assert`

//! Variable-length quantity encoding, limited to i32 as per source map spec.
//! https://en.wikipedia.org/wiki/Variable-length_quantity
//! https://sourcemaps.info/spec.html

const VLQ = @This();

/// Encoding min and max ints are "//////D" and "+/////D", respectively.
/// These are 7 bytes long. This makes the `VLQ` struct 8 bytes.
bytes: [vlq_max_in_bytes]u8,
/// This is a u8 and not a u4 because non^2 integers are really slow in Zig.
len: u8 = 0,

pub inline fn slice(self: *const VLQ) []const u8 {
    return self.bytes[0..self.len];
}

pub fn writeTo(self: VLQ, writer: anytype) !void {
    try writer.writeAll(self.bytes[0..self.len]);
}

pub const zero = vlq_lookup_table[0];

const vlq_lookup_table: [256]VLQ = brk: {
    var entries: [256]VLQ = undefined;
    var i: usize = 0;
    var j: i32 = 0;
    while (i < 256) : (i += 1) {
        entries[i] = encodeSlowPath(j);
        j += 1;
    }
    break :brk entries;
};

const vlq_max_in_bytes = 7;

pub fn encode(value: i32) VLQ {
    return if (value >= 0 and value <= 255)
        vlq_lookup_table[@as(usize, @intCast(value))]
    else
        encodeSlowPath(value);
}

// A single base 64 digit can contain 6 bits of data. For the base 64 variable
// length quantities we use in the source map spec, the first bit is the sign,
// the next four bits are the actual value, and the 6th bit is the continuation
// bit. The continuation bit tells us whether there are more digits in this
// value following this digit.
//
//   Continuation
//   |    Sign
//   |    |
//   V    V
//   101011
//
fn encodeSlowPath(value: i32) VLQ {
    var len: u8 = 0;
    var bytes: [vlq_max_in_bytes]u8 = undefined;

    var vlq: u32 = if (value >= 0)
        @as(u32, @bitCast(value << 1))
    else
        @as(u32, @bitCast((-value << 1) | 1));

    // source mappings are limited to i32
    inline for (0..vlq_max_in_bytes) |_| {
        var digit = vlq & 31;
        vlq >>= 5;

        // If there are still more digits in this value, we must make sure the
        // continuation bit is marked
        if (vlq != 0) {
            digit |= 32;
        }

        bytes[len] = base64[digit];
        len += 1;

        if (vlq == 0) {
            return .{ .bytes = bytes, .len = len };
        }
    }

    return .{ .bytes = bytes, .len = 0 };
}

pub const VLQResult = struct {
    value: i32 = 0,
    start: usize = 0,
};

const base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// base64 stores values up to 7 bits
// Indexed by a full u7 (0..=127), so the table needs 128 entries; sizing it to
// maxInt(u7)==127 left index 127 (e.g. byte 0x7F/0xFF) an out-of-bounds read.
const base64_lut: [std.math.maxInt(u7) + 1]u8 = brk: {
    @setEvalBranchQuota(9999);
    var bytes: [std.math.maxInt(u7) + 1]u8 = @splat(std.math.maxInt(u7));

    for (base64, 0..) |c, i| {
        bytes[c] = i;
    }

    break :brk bytes;
};

pub fn decode(encoded: []const u8, start: usize) VLQResult {
    var shift: u8 = 0;
    var vlq: u32 = 0;

    // hint to the compiler what the maximum value is
    const encoded_ = encoded[start..][0..@min(encoded.len - start, comptime (vlq_max_in_bytes + 1))];

    // inlining helps for the 1 or 2 byte case, hurts a little for larger
    inline for (0..vlq_max_in_bytes + 1) |i| {
        const index = @as(u32, base64_lut[@as(u7, @truncate(encoded_[i]))]);

        // decode a byte
        vlq |= (index & 31) << @as(u5, @truncate(shift));
        shift += 5;

        // Stop if there's no continuation bit
        if ((index & 32) == 0) {
            return VLQResult{
                .start = start + comptime (i + 1),
                .value = if ((vlq & 1) == 0)
                    @as(i32, @intCast(vlq >> 1))
                else
                    -@as(i32, @intCast((vlq >> 1))),
            };
        }
    }

    return VLQResult{ .start = start + encoded_.len, .value = 0 };
}

pub fn decodeAssumeValid(encoded: []const u8, start: usize) VLQResult {
    var shift: u8 = 0;
    var vlq: u32 = 0;

    // hint to the compiler what the maximum value is
    const encoded_ = encoded[start..][0..@min(encoded.len - start, comptime (vlq_max_in_bytes + 1))];

    // inlining helps for the 1 or 2 byte case, hurts a little for larger
    inline for (0..vlq_max_in_bytes + 1) |i| {
        home_rt.assert(encoded_[i] < std.math.maxInt(u7)); // invalid base64 character
        const index = @as(u32, base64_lut[@as(u7, @truncate(encoded_[i]))]);
        home_rt.assert(index != std.math.maxInt(u7)); // invalid base64 character

        // decode a byte
        vlq |= (index & 31) << @as(u5, @truncate(shift));
        shift += 5;

        // Stop if there's no continuation bit
        if ((index & 32) == 0) {
            return VLQResult{
                .start = start + comptime (i + 1),
                .value = if ((vlq & 1) == 0)
                    @as(i32, @intCast(vlq >> 1))
                else
                    -@as(i32, @intCast((vlq >> 1))),
            };
        }
    }

    return .{ .start = start + encoded_.len, .value = 0 };
}

const home_rt = @import("home");
const std = @import("std");

test "VLQ.encode + decode round-trip across the lookup-table boundary" {
    const cases = [_]i32{ 0, 1, -1, 7, -7, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, -256, 1024, -1024, 65535, -65535, 1_000_000, -1_000_000 };
    for (cases) |v| {
        const enc = VLQ.encode(v);
        const dec = VLQ.decode(enc.slice(), 0);
        try std.testing.expectEqual(v, dec.value);
        try std.testing.expectEqual(enc.len, dec.start);
    }
}

test "VLQ.encode matches source-map zero encoding and re-encodes deterministically" {
    // A leading 'A' in source-maps is the canonical zero encoding.
    const zero_enc = VLQ.encode(0);
    try std.testing.expectEqualStrings("A", zero_enc.slice());

    // The fast path returns the lookup-table entry for 0..=255; calling
    // encode twice on the same value must produce identical bytes.
    const a = VLQ.encode(42);
    const b = VLQ.encode(42);
    try std.testing.expectEqualSlices(u8, a.slice(), b.slice());
}

test "VLQ.decode advances `start` past the consumed bytes" {
    // Concatenated VLQs decode sequentially from a single buffer.
    var buf: [16]u8 = undefined;
    const a = VLQ.encode(123);
    const b = VLQ.encode(-456);
    @memcpy(buf[0..a.len], a.slice());
    @memcpy(buf[a.len..][0..b.len], b.slice());

    const r1 = VLQ.decode(buf[0 .. a.len + b.len], 0);
    try std.testing.expectEqual(@as(i32, 123), r1.value);
    try std.testing.expectEqual(@as(usize, a.len), r1.start);

    const r2 = VLQ.decode(buf[0 .. a.len + b.len], r1.start);
    try std.testing.expectEqual(@as(i32, -456), r2.value);
    try std.testing.expectEqual(@as(usize, a.len + b.len), r2.start);
}

test "VLQ.decodeAssumeValid agrees with decode on well-formed input" {
    const enc = VLQ.encode(98765);
    const safe = VLQ.decode(enc.slice(), 0);
    const fast = VLQ.decodeAssumeValid(enc.slice(), 0);
    try std.testing.expectEqual(safe.value, fast.value);
    try std.testing.expectEqual(safe.start, fast.start);
}
