// Home Runtime — Phase 12.7 port of `node:crypto` (Zig substrate, minimal).
//
// Upstream reference: Node.js `lib/crypto.js` + bun/src/js/node/crypto.ts.
// The full `node:crypto` surface depends on OpenSSL (BoringSSL upstream):
// X509, KeyObject, public/private encrypt/decrypt, ECDH, ECDSA, DH, PBKDF2,
// scrypt, sign/verify, cipher/decipher, etc. — every one of those re-attaches
// to the BoringSSL bindings layer (Phase 12.x).
//
// Per `NODE_SHIM_SCOPE_2026-05-19.md` this lands the **subset that can be
// implemented with `std.crypto` alone** so callers that only need hashing,
// HMAC, and CSPRNG bytes get a working substrate today. The OpenSSL-bound
// surfaces are panic-stubbed with `TODO(phase-12.x): BoringSSL bindings` so
// reaching for them yields a single clear diagnostic.
//
// What's implemented (pure `std.crypto`):
//   * `randomBytes(allocator, size)` / `randomFillSync(buf)` — fills bytes
//     via the platform CSPRNG (`arc4random_buf` on Darwin/BSD,
//     `getrandom(2)` on Linux). `link_libc=true` is required at build time
//     (matches the home_rt test config).
//   * `randomInt(min, max)` — uniform integer in `[min, max)` using
//     rejection sampling on top of `randomFillSync`.
//   * `randomUUID(buf)` — writes a version-4, variant-1 UUID into a fixed
//     36-byte buffer (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`).
//   * `Hash` — tagged union over `std.crypto.hash.{Md5,Sha1,sha2.Sha256,
//     sha2.Sha512,sha3.Sha3_256,sha3.Sha3_512}`. Construct via
//     `createHash("sha256")` (case-insensitive). `update` may be called
//     repeatedly; `digest` consumes the hash and returns owned bytes;
//     `digestHex`/`digestBase64` wrap the raw digest in the requested
//     encoding.
//   * `Hmac` — tagged union over `std.crypto.auth.hmac.{HmacMd5,HmacSha1,
//     sha2.HmacSha256,sha2.HmacSha512}`. Same lifecycle as `Hash`.
//   * `constants` — placeholder struct exposing the handful of integer
//     constants we can spell without OpenSSL headers (RSA padding flags,
//     SSL OP_* are 0-stubs because the cipher surface itself isn't ported).
//
// What's deferred (panics with `TODO(phase-12.x): BoringSSL bindings`):
//   pbkdf2, pbkdf2Sync, scrypt, scryptSync, createCipheriv, createDecipheriv,
//   createSign, createVerify, generateKeyPair, generateKeyPairSync, createECDH,
//   createDiffieHellman, KeyObject, X509Certificate, publicEncrypt,
//   publicDecrypt, privateEncrypt, privateDecrypt, hkdf, hkdfSync, sign, verify.
//
// Inline tests cover ≥6 cases:
//   1. `randomBytes` length matches request.
//   2. `randomFillSync` writes into caller buffer (not all-zero by hash).
//   3. `createHash("sha256")` + update + digestHex round-trip against
//      RFC-6234 vector for "abc".
//   4. `createHash("md5")` round-trip against RFC-1321 vector for "abc".
//   5. `createHmac("sha256", key="key")` round-trip against RFC-4231
//      test-case-1 ("Hi There").
//   6. `randomUUID` format check (length 36, dashes at 8/13/18/23,
//      version nibble = 4, variant nibble = 8/9/a/b).
//   7. `createHash("not-a-real-algorithm")` returns `error.UnknownAlgorithm`.

const std = @import("std");
const builtin = @import("builtin");

// ---- Errors -----------------------------------------------------------

pub const CryptoError = error{
    UnknownAlgorithm,
    BufferTooSmall,
    EntropyUnavailable,
    InvalidRange,
} || std.mem.Allocator.Error;

// ---- CSPRNG -----------------------------------------------------------

/// Fill `buf` with cryptographically-secure random bytes. Mirrors
/// `crypto.randomFillSync` (sync, void-returning, can fail only on
/// entropy-source error which we surface via panic — Node's spec is to
/// throw, which we'll re-attach at the JS shim).
pub fn randomFillSync(buf: []u8) void {
    fillRandomBytes(buf) catch |err| {
        std.debug.panic("randomFillSync: entropy source failed: {s}", .{@errorName(err)});
    };
}

/// Allocates `size` bytes filled with CSPRNG output. Caller owns the
/// returned slice. Mirrors `crypto.randomBytes(size)`.
pub fn randomBytes(allocator: std.mem.Allocator, size: usize) CryptoError![]u8 {
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    try fillRandomBytes(buf);
    return buf;
}

/// Uniform integer in `[min, max)` via rejection sampling. Mirrors
/// `crypto.randomInt(min, max)` (Node's two-arg form). Returns
/// `error.InvalidRange` if `max <= min`.
pub fn randomInt(min: u64, max: u64) CryptoError!u64 {
    if (max <= min) return error.InvalidRange;
    const span = max - min;
    // Rejection sampling: discard draws that fall in the truncation tail
    // so the modulo is exact. With a 64-bit raw draw the tail is at most
    // `span` wide, so expected loops is ~1.
    const limit = std.math.maxInt(u64) - (std.math.maxInt(u64) % span);
    while (true) {
        var raw_bytes: [8]u8 = undefined;
        try fillRandomBytes(&raw_bytes);
        const raw = std.mem.readInt(u64, &raw_bytes, .little);
        if (raw < limit) return min + (raw % span);
    }
}

/// Writes a version-4 RFC-4122 UUID into the caller's 36-byte buffer.
/// Format: `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` where `y` is one of
/// 8/9/a/b. Mirrors `crypto.randomUUID()` (which returns a JS string —
/// we fill a buffer instead so callers can avoid allocation).
pub fn randomUUID(buf: *[36]u8) void {
    var raw: [16]u8 = undefined;
    randomFillSync(&raw);
    // Set version (4) and variant (10xx) per RFC-4122 §4.4.
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex_chars = "0123456789abcdef";
    var out_idx: usize = 0;
    var raw_idx: usize = 0;
    while (raw_idx < 16) : (raw_idx += 1) {
        // Dashes between bytes 4-5, 6-7, 8-9, 10-11 (i.e. after raw
        // indices 4, 6, 8, 10).
        if (raw_idx == 4 or raw_idx == 6 or raw_idx == 8 or raw_idx == 10) {
            buf[out_idx] = '-';
            out_idx += 1;
        }
        buf[out_idx] = hex_chars[raw[raw_idx] >> 4];
        buf[out_idx + 1] = hex_chars[raw[raw_idx] & 0x0f];
        out_idx += 2;
    }
}

/// Platform-dispatching CSPRNG fill. `link_libc=true` in home_rt build
/// gives us `arc4random_buf` on Darwin/BSD and `getrandom(2)` on Linux.
fn fillRandomBytes(buf: []u8) CryptoError!void {
    if (buf.len == 0) return;
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .openbsd, .netbsd, .dragonfly => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            // Loop in case of short reads / EINTR. `getrandom` with
            // flags=0 reads from the urandom pool, blocking only until
            // the pool is initialized (which it is by the time userspace
            // runs).
            var i: usize = 0;
            while (i < buf.len) {
                const rc = std.os.linux.getrandom(buf[i..].ptr, buf.len - i, 0);
                switch (std.os.linux.E.init(rc)) {
                    .SUCCESS => i += @intCast(rc),
                    .INTR => continue,
                    else => return error.EntropyUnavailable,
                }
            }
        },
        else => return error.EntropyUnavailable,
    }
}

// ---- Hash -------------------------------------------------------------

/// Supported one-shot hash algorithm. Construct from a string via
/// `algorithmFromName`. The variants mirror Node's case-insensitive
/// alias table for the std.crypto-backed subset.
pub const HashAlgorithm = enum {
    md5,
    sha1,
    sha256,
    sha384,
    sha512,
    sha3_256,
    sha3_512,

    pub fn digestLength(self: HashAlgorithm) usize {
        return switch (self) {
            .md5 => std.crypto.hash.Md5.digest_length,
            .sha1 => std.crypto.hash.Sha1.digest_length,
            .sha256 => std.crypto.hash.sha2.Sha256.digest_length,
            .sha384 => std.crypto.hash.sha2.Sha384.digest_length,
            .sha512 => std.crypto.hash.sha2.Sha512.digest_length,
            .sha3_256 => std.crypto.hash.sha3.Sha3_256.digest_length,
            .sha3_512 => std.crypto.hash.sha3.Sha3_512.digest_length,
        };
    }
};

/// Maps a Node-style algorithm name to `HashAlgorithm`. Accepts the
/// case variants Node accepts (`SHA256`, `sha256`, `sha-256`).
pub fn algorithmFromName(name: []const u8) CryptoError!HashAlgorithm {
    // ASCII lower + strip `-` so `sha-256` / `SHA256` / `sha256` all match.
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return error.UnknownAlgorithm;
    var len: usize = 0;
    for (name) |c| {
        if (c == '-') continue;
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    const norm = buf[0..len];
    if (std.mem.eql(u8, norm, "md5")) return .md5;
    if (std.mem.eql(u8, norm, "sha1")) return .sha1;
    if (std.mem.eql(u8, norm, "sha256")) return .sha256;
    if (std.mem.eql(u8, norm, "sha384")) return .sha384;
    if (std.mem.eql(u8, norm, "sha512")) return .sha512;
    if (std.mem.eql(u8, norm, "sha3256")) return .sha3_256;
    if (std.mem.eql(u8, norm, "sha3512")) return .sha3_512;
    return error.UnknownAlgorithm;
}

/// Tagged union over the std.crypto hash variants. Held by value inside
/// `Hash` so callers don't have to size the wrapper to the largest
/// internal state up-front.
const HashImpl = union(HashAlgorithm) {
    md5: std.crypto.hash.Md5,
    sha1: std.crypto.hash.Sha1,
    sha256: std.crypto.hash.sha2.Sha256,
    sha384: std.crypto.hash.sha2.Sha384,
    sha512: std.crypto.hash.sha2.Sha512,
    sha3_256: std.crypto.hash.sha3.Sha3_256,
    sha3_512: std.crypto.hash.sha3.Sha3_512,
};

/// Node's `crypto.Hash` — `createHash → update*  → digest`. Once
/// `digest` is called the hash is consumed (the std.crypto APIs all
/// take `*Self` for `final`); call `init` again for a fresh hash.
pub const Hash = struct {
    impl: HashImpl,

    /// Construct from a Node-style algorithm name. Aliases `createHash`.
    pub fn init(algorithm: []const u8) CryptoError!Hash {
        const tag = try algorithmFromName(algorithm);
        return initWith(tag);
    }

    /// Construct from an already-parsed algorithm tag.
    pub fn initWith(algorithm: HashAlgorithm) Hash {
        return switch (algorithm) {
            .md5 => .{ .impl = .{ .md5 = std.crypto.hash.Md5.init(.{}) } },
            .sha1 => .{ .impl = .{ .sha1 = std.crypto.hash.Sha1.init(.{}) } },
            .sha256 => .{ .impl = .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) } },
            .sha384 => .{ .impl = .{ .sha384 = std.crypto.hash.sha2.Sha384.init(.{}) } },
            .sha512 => .{ .impl = .{ .sha512 = std.crypto.hash.sha2.Sha512.init(.{}) } },
            .sha3_256 => .{ .impl = .{ .sha3_256 = std.crypto.hash.sha3.Sha3_256.init(.{}) } },
            .sha3_512 => .{ .impl = .{ .sha3_512 = std.crypto.hash.sha3.Sha3_512.init(.{}) } },
        };
    }

    /// Feed bytes into the hash. Can be called any number of times
    /// before `digest`.
    pub fn update(self: *Hash, data: []const u8) void {
        switch (self.impl) {
            inline else => |*v| v.update(data),
        }
    }

    /// Returns the digest length in bytes.
    pub fn digestLength(self: Hash) usize {
        return switch (self.impl) {
            .md5 => std.crypto.hash.Md5.digest_length,
            .sha1 => std.crypto.hash.Sha1.digest_length,
            .sha256 => std.crypto.hash.sha2.Sha256.digest_length,
            .sha384 => std.crypto.hash.sha2.Sha384.digest_length,
            .sha512 => std.crypto.hash.sha2.Sha512.digest_length,
            .sha3_256 => std.crypto.hash.sha3.Sha3_256.digest_length,
            .sha3_512 => std.crypto.hash.sha3.Sha3_512.digest_length,
        };
    }

    /// Finalize and return owned digest bytes. Caller frees.
    pub fn digest(self: *Hash, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const out = try allocator.alloc(u8, self.digestLength());
        self.digestInto(out);
        return out;
    }

    /// Finalize into a caller-provided buffer (must be at least
    /// `digestLength()` bytes). Useful for stack-allocated callers.
    pub fn digestInto(self: *Hash, out: []u8) void {
        std.debug.assert(out.len >= self.digestLength());
        switch (self.impl) {
            .md5 => |*v| {
                var fixed: [std.crypto.hash.Md5.digest_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha1 => |*v| {
                var fixed: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha256 => |*v| {
                var fixed: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha384 => |*v| {
                var fixed: [std.crypto.hash.sha2.Sha384.digest_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha512 => |*v| {
                var fixed: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha3_256 => |*v| {
                var fixed: [std.crypto.hash.sha3.Sha3_256.digest_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha3_512 => |*v| {
                var fixed: [std.crypto.hash.sha3.Sha3_512.digest_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
        }
    }

    /// Finalize and lower-hex-encode into a caller-provided buffer.
    /// Buffer must be at least `2 * digestLength()` bytes. Returns the
    /// populated slice.
    pub fn digestHex(self: *Hash, buf: []u8) []const u8 {
        const dlen = self.digestLength();
        std.debug.assert(buf.len >= dlen * 2);
        // Take the raw digest into a stack scratch then hex-encode.
        var scratch: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
        const raw = scratch[0..dlen];
        self.digestInto(raw);
        const hex_chars = "0123456789abcdef";
        for (raw, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        return buf[0 .. dlen * 2];
    }

    /// Finalize and base64-encode (standard alphabet, padded). Caller
    /// frees the returned slice.
    pub fn digestBase64(self: *Hash, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const dlen = self.digestLength();
        var scratch: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
        const raw = scratch[0..dlen];
        self.digestInto(raw);
        const encoder = std.base64.standard.Encoder;
        const enc_len = encoder.calcSize(dlen);
        const out = try allocator.alloc(u8, enc_len);
        _ = encoder.encode(out, raw);
        return out;
    }
};

/// Alias for `Hash.init`. Mirrors Node's top-level constructor.
pub fn createHash(algorithm: []const u8) CryptoError!Hash {
    return Hash.init(algorithm);
}

// ---- HMAC -------------------------------------------------------------

/// HMAC algorithm tag — subset of `HashAlgorithm` that `std.crypto.auth.hmac`
/// exposes. SHA-3 family is not in `std.crypto.auth.hmac`, so HMAC-SHA3-*
/// re-attaches once that lands or via BoringSSL.
pub const HmacAlgorithm = enum {
    md5,
    sha1,
    sha256,
    sha384,
    sha512,

    pub fn digestLength(self: HmacAlgorithm) usize {
        return switch (self) {
            .md5 => std.crypto.auth.hmac.HmacMd5.mac_length,
            .sha1 => std.crypto.auth.hmac.HmacSha1.mac_length,
            .sha256 => std.crypto.auth.hmac.sha2.HmacSha256.mac_length,
            .sha384 => std.crypto.auth.hmac.sha2.HmacSha384.mac_length,
            .sha512 => std.crypto.auth.hmac.sha2.HmacSha512.mac_length,
        };
    }
};

fn hmacAlgorithmFromName(name: []const u8) CryptoError!HmacAlgorithm {
    const tag = try algorithmFromName(name);
    return switch (tag) {
        .md5 => .md5,
        .sha1 => .sha1,
        .sha256 => .sha256,
        .sha384 => .sha384,
        .sha512 => .sha512,
        .sha3_256, .sha3_512 => error.UnknownAlgorithm,
    };
}

const HmacImpl = union(HmacAlgorithm) {
    md5: std.crypto.auth.hmac.HmacMd5,
    sha1: std.crypto.auth.hmac.HmacSha1,
    sha256: std.crypto.auth.hmac.sha2.HmacSha256,
    sha384: std.crypto.auth.hmac.sha2.HmacSha384,
    sha512: std.crypto.auth.hmac.sha2.HmacSha512,
};

/// Node's `crypto.Hmac` — `createHmac(alg, key) → update* → digest`.
/// Same lifecycle constraints as `Hash`.
pub const Hmac = struct {
    impl: HmacImpl,

    pub fn init(algorithm: []const u8, key: []const u8) CryptoError!Hmac {
        const tag = try hmacAlgorithmFromName(algorithm);
        return initWith(tag, key);
    }

    pub fn initWith(algorithm: HmacAlgorithm, key: []const u8) Hmac {
        return switch (algorithm) {
            .md5 => .{ .impl = .{ .md5 = std.crypto.auth.hmac.HmacMd5.init(key) } },
            .sha1 => .{ .impl = .{ .sha1 = std.crypto.auth.hmac.HmacSha1.init(key) } },
            .sha256 => .{ .impl = .{ .sha256 = std.crypto.auth.hmac.sha2.HmacSha256.init(key) } },
            .sha384 => .{ .impl = .{ .sha384 = std.crypto.auth.hmac.sha2.HmacSha384.init(key) } },
            .sha512 => .{ .impl = .{ .sha512 = std.crypto.auth.hmac.sha2.HmacSha512.init(key) } },
        };
    }

    pub fn update(self: *Hmac, data: []const u8) void {
        switch (self.impl) {
            inline else => |*v| v.update(data),
        }
    }

    pub fn digestLength(self: Hmac) usize {
        return switch (self.impl) {
            .md5 => std.crypto.auth.hmac.HmacMd5.mac_length,
            .sha1 => std.crypto.auth.hmac.HmacSha1.mac_length,
            .sha256 => std.crypto.auth.hmac.sha2.HmacSha256.mac_length,
            .sha384 => std.crypto.auth.hmac.sha2.HmacSha384.mac_length,
            .sha512 => std.crypto.auth.hmac.sha2.HmacSha512.mac_length,
        };
    }

    pub fn digestInto(self: *Hmac, out: []u8) void {
        std.debug.assert(out.len >= self.digestLength());
        switch (self.impl) {
            .md5 => |*v| {
                var fixed: [std.crypto.auth.hmac.HmacMd5.mac_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha1 => |*v| {
                var fixed: [std.crypto.auth.hmac.HmacSha1.mac_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha256 => |*v| {
                var fixed: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha384 => |*v| {
                var fixed: [std.crypto.auth.hmac.sha2.HmacSha384.mac_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
            .sha512 => |*v| {
                var fixed: [std.crypto.auth.hmac.sha2.HmacSha512.mac_length]u8 = undefined;
                v.final(&fixed);
                @memcpy(out[0..fixed.len], &fixed);
            },
        }
    }

    pub fn digest(self: *Hmac, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const out = try allocator.alloc(u8, self.digestLength());
        self.digestInto(out);
        return out;
    }

    pub fn digestHex(self: *Hmac, buf: []u8) []const u8 {
        const dlen = self.digestLength();
        std.debug.assert(buf.len >= dlen * 2);
        var scratch: [std.crypto.auth.hmac.sha2.HmacSha512.mac_length]u8 = undefined;
        const raw = scratch[0..dlen];
        self.digestInto(raw);
        const hex_chars = "0123456789abcdef";
        for (raw, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        return buf[0 .. dlen * 2];
    }
};

pub fn createHmac(algorithm: []const u8, key: []const u8) CryptoError!Hmac {
    return Hmac.init(algorithm, key);
}

// ---- Constants --------------------------------------------------------

/// `crypto.constants`. The full set is auto-derived from BoringSSL/OpenSSL
/// headers at build-time upstream. Until the BoringSSL bindings land we
/// expose a handful of well-known integer values that callers can spell
/// without pulling in libssl. Everything else stays parked.
pub const constants = struct {
    // RSA padding modes (PKCS#1 v1.5 + OAEP + PSS). Values from
    // BoringSSL's `include/openssl/rsa.h`.
    pub const RSA_PKCS1_PADDING: i32 = 1;
    pub const RSA_NO_PADDING: i32 = 3;
    pub const RSA_PKCS1_OAEP_PADDING: i32 = 4;
    pub const RSA_PKCS1_PSS_PADDING: i32 = 6;

    // PSS salt-length sentinel values used by `crypto.sign` / `crypto.verify`.
    pub const RSA_PSS_SALTLEN_DIGEST: i32 = -1;
    pub const RSA_PSS_SALTLEN_MAX_SIGN: i32 = -2;
    pub const RSA_PSS_SALTLEN_AUTO: i32 = -2;

    // POINT_CONVERSION_* — sec1 point encoding selectors.
    pub const POINT_CONVERSION_COMPRESSED: i32 = 2;
    pub const POINT_CONVERSION_UNCOMPRESSED: i32 = 4;
    pub const POINT_CONVERSION_HYBRID: i32 = 6;
};

// ---- Deferred surfaces (BoringSSL-bound) ------------------------------

/// PBKDF2 — needs HMAC-with-iteration-count. `std.crypto.pwhash.pbkdf2`
/// exists but the Node spec requires arbitrary digest algorithms; full
/// port re-attaches with BoringSSL where the OpenSSL evp_pbkdf2 surface
/// is already wired.
pub fn pbkdf2(
    _: std.mem.Allocator,
    _: []const u8, // password
    _: []const u8, // salt
    _: usize, // iterations
    _: usize, // keylen
    _: []const u8, // digest
) []u8 {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.pbkdf2");
}

pub fn scrypt(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: usize,
) []u8 {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.scrypt");
}

pub fn createCipheriv() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.createCipheriv");
}

pub fn createDecipheriv() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.createDecipheriv");
}

pub fn createSign() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.createSign");
}

pub fn createVerify() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.createVerify");
}

pub fn createDiffieHellman() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.createDiffieHellman");
}

pub fn createECDH() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.createECDH");
}

pub fn generateKeyPair() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.generateKeyPair");
}

pub fn publicEncrypt() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.publicEncrypt");
}

pub fn privateDecrypt() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.privateDecrypt");
}

pub fn KeyObject() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.KeyObject");
}

pub fn X509Certificate() void {
    @panic("TODO(phase-12.x): BoringSSL bindings — crypto.X509Certificate");
}

// ---- Tests ------------------------------------------------------------

const testing = std.testing;

test "randomBytes returns slice of requested length" {
    const buf = try randomBytes(testing.allocator, 32);
    defer testing.allocator.free(buf);
    try testing.expectEqual(@as(usize, 32), buf.len);
}

test "randomFillSync writes into caller buffer" {
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    randomFillSync(&buf);
    // The probability of 16 consecutive zero bytes from a CSPRNG is
    // ~2^-128; treat all-zero as failure.
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "createHash sha256 matches RFC-6234 vector for 'abc'" {
    var h = try createHash("sha256");
    h.update("abc");
    var hex_buf: [64]u8 = undefined;
    const hex = h.digestHex(&hex_buf);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hex,
    );
}

test "createHash md5 matches RFC-1321 vector for 'abc'" {
    var h = try createHash("md5");
    h.update("a");
    h.update("b");
    h.update("c");
    var hex_buf: [32]u8 = undefined;
    const hex = h.digestHex(&hex_buf);
    try testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", hex);
}

test "createHmac sha256 matches RFC-4231 'Hi There' vector" {
    // Test case 1: key = 20 bytes of 0x0b, data = "Hi There".
    const key = [_]u8{
        0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
        0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
        0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
        0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
    };
    var h = try createHmac("sha256", &key);
    h.update("Hi There");
    var hex_buf: [64]u8 = undefined;
    const hex = h.digestHex(&hex_buf);
    try testing.expectEqualStrings(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        hex,
    );
}

test "randomUUID has version-4 / variant-1 format" {
    var uuid: [36]u8 = undefined;
    randomUUID(&uuid);
    try testing.expectEqual(@as(usize, 36), uuid.len);
    try testing.expectEqual(@as(u8, '-'), uuid[8]);
    try testing.expectEqual(@as(u8, '-'), uuid[13]);
    try testing.expectEqual(@as(u8, '-'), uuid[18]);
    try testing.expectEqual(@as(u8, '-'), uuid[23]);
    // Version nibble (char 14) must be '4'.
    try testing.expectEqual(@as(u8, '4'), uuid[14]);
    // Variant nibble (char 19) must be 8/9/a/b.
    const variant = uuid[19];
    try testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "createHash unknown algorithm returns UnknownAlgorithm" {
    try testing.expectError(error.UnknownAlgorithm, createHash("not-a-real-algorithm"));
}

test "createHmac unknown algorithm returns UnknownAlgorithm" {
    try testing.expectError(error.UnknownAlgorithm, createHmac("bogus", "key"));
}

test "createHash sha512 digest is 64 bytes" {
    var h = try createHash("sha512");
    h.update("");
    const out = try h.digest(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 64), out.len);
}

test "Hash digestBase64 round-trip for empty input" {
    var h = try createHash("sha256");
    const out = try h.digestBase64(testing.allocator);
    defer testing.allocator.free(out);
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    // → base64: 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
    try testing.expectEqualStrings("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", out);
}

test "randomInt is within [min, max)" {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const v = try randomInt(10, 20);
        try testing.expect(v >= 10);
        try testing.expect(v < 20);
    }
}

test "randomInt invalid range returns error" {
    try testing.expectError(error.InvalidRange, randomInt(10, 10));
    try testing.expectError(error.InvalidRange, randomInt(20, 10));
}

test "constants exposes RSA padding flags" {
    try testing.expectEqual(@as(i32, 1), constants.RSA_PKCS1_PADDING);
    try testing.expectEqual(@as(i32, 4), constants.RSA_PKCS1_OAEP_PADDING);
    try testing.expectEqual(@as(i32, 6), constants.RSA_PKCS1_PSS_PADDING);
}
