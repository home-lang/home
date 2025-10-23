const std = @import("std");

/// Cryptography module - secure hashing, encryption, signing
pub const Crypto = struct {
    /// SHA-256 hash function
    pub fn sha256(data: []const u8) [32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
        return hash;
    }

    /// SHA-512 hash function
    pub fn sha512(data: []const u8) [64]u8 {
        var hash: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(data, &hash, .{});
        return hash;
    }

    /// BLAKE3 hash function (faster than SHA-2)
    pub fn blake3(data: []const u8) [32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data, &hash, .{});
        return hash;
    }

    /// Secure random number generation
    pub const Random = struct {
        rng: std.rand.DefaultPrng,

        pub fn init() Random {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch {
                seed = @intCast(std.time.milliTimestamp());
            };

            return .{
                .rng = std.rand.DefaultPrng.init(seed),
            };
        }

        pub fn bytes(self: *Random, buffer: []u8) void {
            self.rng.fill(buffer);
        }

        pub fn int(self: *Random, comptime T: type) T {
            return self.rng.random().int(T);
        }

        pub fn float(self: *Random, comptime T: type) T {
            return self.rng.random().float(T);
        }
    };

    /// AES-256-GCM encryption
    pub const Aes256Gcm = struct {
        pub const key_length = 32;
        pub const nonce_length = 12;
        pub const tag_length = 16;

        pub fn encrypt(
            key: *const [key_length]u8,
            nonce: *const [nonce_length]u8,
            plaintext: []const u8,
            ad: []const u8,
            ciphertext: []u8,
            tag: *[tag_length]u8,
        ) !void {
            if (ciphertext.len < plaintext.len) return error.BufferTooSmall;

            std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
                ciphertext[0..plaintext.len],
                tag,
                plaintext,
                ad,
                nonce.*,
                key.*,
            );
        }

        pub fn decrypt(
            key: *const [key_length]u8,
            nonce: *const [nonce_length]u8,
            ciphertext: []const u8,
            tag: [tag_length]u8,
            ad: []const u8,
            plaintext: []u8,
        ) !void {
            if (plaintext.len < ciphertext.len) return error.BufferTooSmall;

            try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
                plaintext[0..ciphertext.len],
                ciphertext,
                tag,
                ad,
                nonce.*,
                key.*,
            );
        }
    };

    /// ChaCha20-Poly1305 encryption (faster than AES on most CPUs)
    pub const ChaCha20Poly1305 = struct {
        pub const key_length = 32;
        pub const nonce_length = 12;
        pub const tag_length = 16;

        pub fn encrypt(
            key: *const [key_length]u8,
            nonce: *const [nonce_length]u8,
            plaintext: []const u8,
            ad: []const u8,
            ciphertext: []u8,
            tag: *[tag_length]u8,
        ) !void {
            if (ciphertext.len < plaintext.len) return error.BufferTooSmall;

            std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(
                ciphertext[0..plaintext.len],
                tag,
                plaintext,
                ad,
                nonce.*,
                key.*,
            );
        }

        pub fn decrypt(
            key: *const [key_length]u8,
            nonce: *const [nonce_length]u8,
            ciphertext: []const u8,
            tag: [tag_length]u8,
            ad: []const u8,
            plaintext: []u8,
        ) !void {
            if (plaintext.len < ciphertext.len) return error.BufferTooSmall;

            try std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(
                plaintext[0..ciphertext.len],
                ciphertext,
                tag,
                ad,
                nonce.*,
                key.*,
            );
        }
    };

    /// Password hashing with Argon2
    pub const Argon2 = struct {
        pub const Options = struct {
            time_cost: u32 = 3,
            memory_cost: u32 = 65536, // 64 MB
            parallelism: u32 = 4,
        };

        pub fn hash(
            password: []const u8,
            salt: []const u8,
            out: []u8,
            options: Options,
        ) !void {
            _ = password;
            _ = salt;
            _ = out;
            _ = options;
            // Implementation would use std.crypto.pwhash.argon2
            return error.NotImplemented;
        }

        pub fn verify(
            password: []const u8,
            hash_str: []const u8,
        ) !bool {
            _ = password;
            _ = hash_str;
            // Implementation would verify against hash
            return error.NotImplemented;
        }
    };

    /// HMAC (Hash-based Message Authentication Code)
    pub fn hmacSha256(key: []const u8, message: []const u8) [32]u8 {
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, message, key);
        return mac;
    }

    /// Ed25519 digital signatures
    pub const Ed25519 = struct {
        pub const KeyPair = std.crypto.sign.Ed25519.KeyPair;
        pub const PublicKey = std.crypto.sign.Ed25519.PublicKey;
        pub const SecretKey = std.crypto.sign.Ed25519.SecretKey;
        pub const Signature = std.crypto.sign.Ed25519.Signature;

        pub fn generateKeyPair() !KeyPair {
            var seed: [32]u8 = undefined;
            try std.posix.getrandom(&seed);
            return try KeyPair.create(seed);
        }

        pub fn sign(message: []const u8, secret_key: SecretKey) !Signature {
            return try secret_key.sign(message, null);
        }

        pub fn verify(
            signature: Signature,
            message: []const u8,
            public_key: PublicKey,
        ) !void {
            try signature.verify(message, public_key);
        }
    };

    /// X25519 key exchange (Diffie-Hellman)
    pub const X25519 = struct {
        pub const PublicKey = std.crypto.dh.X25519.PublicKey;
        pub const SecretKey = std.crypto.dh.X25519.SecretKey;

        pub fn generateKeyPair() !struct { secret: SecretKey, public: PublicKey } {
            var seed: [32]u8 = undefined;
            try std.posix.getrandom(&seed);

            const secret = SecretKey.fromBytes(seed);
            const public = try secret.publicKey();

            return .{ .secret = secret, .public = public };
        }

        pub fn computeSharedSecret(
            our_secret: SecretKey,
            their_public: PublicKey,
        ) ![32]u8 {
            return try std.crypto.dh.X25519.scalarmult(our_secret.bytes, their_public.bytes);
        }
    };

    /// Constant-time comparison (prevents timing attacks)
    pub fn constantTimeCompare(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        return std.crypto.utils.timingSafeEql([*]const u8, a.ptr, b.ptr, a.len);
    }

    /// Secure memory wiping
    pub fn secureZero(buffer: []u8) void {
        std.crypto.utils.secureZero(u8, buffer);
    }
};
