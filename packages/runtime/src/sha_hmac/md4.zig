//! Pure-Zig MD4 (RFC 1320). `std.crypto` does not ship MD4 (it's broken for
//! security), but `Bun.CryptoHasher`/`crypto.createHash("md4")` still expose it,
//! and the EVP shim previously `@panic`ed via `UnsupportedEVPHasher` — crashing
//! the process. This matches the `std.crypto.hash` interface so it drops into
//! `NewStdEVP`. MD4 is only ever used for non-security digests (e.g. ETags).

const std = @import("std");

pub const Md4 = struct {
    pub const block_length = 64;
    pub const digest_length = 16;
    pub const Options = struct {};

    s: [4]u32,
    // Streaming buffer.
    buf: [64]u8 = undefined,
    buf_len: u8 = 0,
    total_len: u64 = 0,

    pub fn init(options: Options) Md4 {
        _ = options;
        return .{
            .s = .{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 },
        };
    }

    pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void {
        var d = Md4.init(options);
        d.update(b);
        d.final(out);
    }

    pub fn update(self: *Md4, b: []const u8) void {
        self.total_len +%= b.len;
        var off: usize = 0;

        // Fill the partial buffer, then process it.
        if (self.buf_len != 0 and self.buf_len + b.len >= 64) {
            off += 64 - self.buf_len;
            @memcpy(self.buf[self.buf_len..][0..off], b[0..off]);
            self.round(&self.buf);
            self.buf_len = 0;
        }

        // Process full blocks straight from `b`.
        while (off + 64 <= b.len) : (off += 64) {
            self.round(b[off..][0..64]);
        }

        // Stash the remainder.
        const rem = b[off..];
        @memcpy(self.buf[self.buf_len..][0..rem.len], rem);
        self.buf_len += @intCast(rem.len);
    }

    pub fn final(self: *Md4, out: *[digest_length]u8) void {
        const bits = self.total_len *% 8;

        // Append the 0x80 padding byte.
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;

        // If there's no room for the 8-byte length, flush a block.
        if (self.buf_len > 56) {
            @memset(self.buf[self.buf_len..64], 0);
            self.round(&self.buf);
            self.buf_len = 0;
        }

        // Zero-pad up to the length field and write the bit count (LE).
        @memset(self.buf[self.buf_len..56], 0);
        std.mem.writeInt(u64, self.buf[56..64], bits, .little);
        self.round(&self.buf);

        for (0..4) |i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], self.s[i], .little);
        }
    }

    fn ff(a: u32, b: u32, c: u32, d: u32, xk: u32, comptime s: u5) u32 {
        return std.math.rotl(u32, a +% ((b & c) | (~b & d)) +% xk, s);
    }
    fn gg(a: u32, b: u32, c: u32, d: u32, xk: u32, comptime s: u5) u32 {
        return std.math.rotl(u32, a +% ((b & c) | (b & d) | (c & d)) +% xk +% 0x5a827999, s);
    }
    fn hh(a: u32, b: u32, c: u32, d: u32, xk: u32, comptime s: u5) u32 {
        return std.math.rotl(u32, a +% (b ^ c ^ d) +% xk +% 0x6ed9eba1, s);
    }

    fn round(self: *Md4, block: *const [64]u8) void {
        var x: [16]u32 = undefined;
        for (0..16) |i| x[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);

        var a = self.s[0];
        var b = self.s[1];
        var c = self.s[2];
        var d = self.s[3];

        // Round 1: shifts 3, 7, 11, 19; k in 0..15 order.
        inline for (0..4) |i| {
            a = ff(a, b, c, d, x[i * 4 + 0], 3);
            d = ff(d, a, b, c, x[i * 4 + 1], 7);
            c = ff(c, d, a, b, x[i * 4 + 2], 11);
            b = ff(b, c, d, a, x[i * 4 + 3], 19);
        }

        // Round 2: shifts 3, 5, 9, 13; k = column-major (i, i+4, i+8, i+12).
        inline for (0..4) |i| {
            a = gg(a, b, c, d, x[i + 0], 3);
            d = gg(d, a, b, c, x[i + 4], 5);
            c = gg(c, d, a, b, x[i + 8], 9);
            b = gg(b, c, d, a, x[i + 12], 13);
        }

        // Round 3: shifts 3, 9, 11, 15; k in the MD4 round-3 permutation.
        const order3 = [_]usize{ 0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15 };
        inline for (0..4) |i| {
            a = hh(a, b, c, d, x[order3[i * 4 + 0]], 3);
            d = hh(d, a, b, c, x[order3[i * 4 + 1]], 9);
            c = hh(c, d, a, b, x[order3[i * 4 + 2]], 11);
            b = hh(b, c, d, a, x[order3[i * 4 + 3]], 15);
        }

        self.s[0] +%= a;
        self.s[1] +%= b;
        self.s[2] +%= c;
        self.s[3] +%= d;
    }
};

fn hexDigest(input: []const u8) [32]u8 {
    var out: [16]u8 = undefined;
    Md4.hash(input, &out, .{});
    const hexchars = "0123456789abcdef";
    var hex: [32]u8 = undefined;
    for (out, 0..) |byte, i| {
        hex[i * 2] = hexchars[byte >> 4];
        hex[i * 2 + 1] = hexchars[byte & 0xf];
    }
    return hex;
}

test "MD4 RFC 1320 test vectors" {
    try std.testing.expectEqualStrings("31d6cfe0d16ae931b73c59d7e0c089c0", &hexDigest(""));
    try std.testing.expectEqualStrings("bde52cb31de33e46245e05fbdbd6fb24", &hexDigest("a"));
    try std.testing.expectEqualStrings("a448017aaf21d8525fc10ae87aa6729d", &hexDigest("abc"));
    try std.testing.expectEqualStrings("d9130a8164549fe818874806e1c7014b", &hexDigest("message digest"));
    try std.testing.expectEqualStrings("d79e1c308aa5bbcdeea8ed63df412da9", &hexDigest("abcdefghijklmnopqrstuvwxyz"));
}

test "MD4 streaming matches one-shot across block boundary" {
    const input = "a" ** 200;
    var one: [16]u8 = undefined;
    Md4.hash(input, &one, .{});

    var d = Md4.init(.{});
    d.update(input[0..50]);
    d.update(input[50..63]);
    d.update(input[63..130]);
    d.update(input[130..]);
    var stream: [16]u8 = undefined;
    d.final(&stream);

    try std.testing.expectEqualSlices(u8, &one, &stream);
}
