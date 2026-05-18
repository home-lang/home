// Copied from bun/src/jsc/uuid.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Pure-Zig UUID v4 / v5 / v7 implementation. Upstream calls into
// `bun.csprng`, `bun.sha.SHA1`, and `bun.Mutex` — none ported yet. We
// substitute `std.crypto.hash.Sha1` (drop-in replacement) and
// `std.Thread.Mutex` for the v7 counter lock. The csprng entry point in
// `UUID.init()` is parked on a thread-safe `DefaultCsprng` seeded once from
// the wall clock + thread id; the production-grade kernel-backed csprng
// (`getrandom(2)` on Linux, `arc4random_buf` on Darwin) re-attaches when
// `bun.csprng` lands.
//
// The 16-byte byte layout, the encoded-pos table, and every public function
// signature stay verbatim. `format()` writes into a `*std.Io.Writer` to
// match the Zig 0.17 IO shape.

const UUID = @This();

pub const Error = error{InvalidUUID};

bytes: [16]u8,

var csprng_lock: Mutex = .{};
var csprng_state: ?std.Random.DefaultCsprng = null;

fn fillRandom(buf: []u8) void {
    csprng_lock.lock();
    defer csprng_lock.unlock();
    if (csprng_state == null) {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        // Stub seed: thread id + stack-address (ASLR) + a per-call counter.
        // Production-grade seeding (kernel getrandom on Linux, arc4random_buf
        // on Darwin) re-attaches with `bun.csprng`.
        @memset(&seed, 0);
        const tid: u64 = std.Thread.getCurrentId();
        std.mem.writeInt(u64, seed[0..8], tid, .little);
        const stack_var: u32 = 0;
        std.mem.writeInt(u64, seed[8..16], @intFromPtr(&stack_var), .little);
        const counter: u64 = seed_counter.fetchAdd(1, .monotonic);
        std.mem.writeInt(u64, seed[16..24], counter, .little);
        csprng_state = std.Random.DefaultCsprng.init(seed);
    }
    csprng_state.?.fill(buf);
}

var seed_counter: std.atomic.Value(u64) = .{ .raw = 0 };

pub fn init() UUID {
    var uuid = UUID{ .bytes = undefined };

    fillRandom(&uuid.bytes);
    // Version 4
    uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;
    // Variant 1
    uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;

    return uuid;
}

pub fn initWith(bytes: *const [16]u8) UUID {
    var uuid = UUID{ .bytes = bytes.* };

    uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;
    uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;

    return uuid;
}
pub const stringLength = 36;

// Indices in the UUID string representation for each byte.
const encoded_pos = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };

// Hex to nibble mapping.
const hex_to_nibble = [256]u8{
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

pub fn format(
    self: UUID,
    writer: *std.Io.Writer,
) !void {
    var buf: [36]u8 = undefined;
    self.print(&buf);

    try writer.print("{s}", .{buf});
}

fn printBytes(
    bytes: *const [16]u8,
    buf: *[36]u8,
) void {
    const hex = "0123456789abcdef";

    buf[8] = '-';
    buf[13] = '-';
    buf[18] = '-';
    buf[23] = '-';
    inline for (encoded_pos, 0..) |i, j| {
        buf[comptime i + 0] = hex[bytes[j] >> 4];
        buf[comptime i + 1] = hex[bytes[j] & 0x0f];
    }
}
pub fn print(
    self: UUID,
    buf: *[36]u8,
) void {
    printBytes(&self.bytes, buf);
}

pub fn parse(buf: []const u8) Error!UUID {
    var uuid = UUID{ .bytes = undefined };

    if (buf.len != 36 or buf[8] != '-' or buf[13] != '-' or buf[18] != '-' or buf[23] != '-')
        return Error.InvalidUUID;

    inline for (encoded_pos, 0..) |i, j| {
        const hi = hex_to_nibble[buf[i + 0]];
        const lo = hex_to_nibble[buf[i + 1]];
        if (hi == 0xff or lo == 0xff) {
            return Error.InvalidUUID;
        }
        uuid.bytes[j] = hi << 4 | lo;
    }

    return uuid;
}

// Zero UUID
pub const zero: UUID = .{ .bytes = @splat(0) };

// Convenience function to return a new v4 UUID.
pub fn newV4() UUID {
    return UUID.init();
}

/// # --- 48 ---   -- 4 --   - 12 -   -- 2 --   - 62 -
/// # unix_ts_ms | version | rand_a | variant | rand_b
pub const UUID7 = struct {
    bytes: [16]u8,

    var uuid_v7_lock: Mutex = .{};
    var uuid_v7_last_timestamp: std.atomic.Value(u64) = .{ .raw = 0 };
    var uuid_v7_counter: std.atomic.Value(u32) = .{ .raw = 0 };

    fn getCount(timestamp: u64) u32 {
        uuid_v7_lock.lock();
        defer uuid_v7_lock.unlock();
        if (uuid_v7_last_timestamp.swap(timestamp, .monotonic) != timestamp) {
            uuid_v7_counter.store(0, .monotonic);
        }

        return uuid_v7_counter.fetchAdd(1, .monotonic) % 4096;
    }

    pub fn init(timestamp: u64, random: *[8]u8) UUID7 {
        const count = getCount(timestamp);

        var bytes: [16]u8 = undefined;

        // First 6 bytes: timestamp in big-endian
        bytes[0] = @truncate(timestamp >> 40);
        bytes[1] = @truncate(timestamp >> 32);
        bytes[2] = @truncate(timestamp >> 24);
        bytes[3] = @truncate(timestamp >> 16);
        bytes[4] = @truncate(timestamp >> 8);
        bytes[5] = @truncate(timestamp);

        // Byte 6: Version 7 in high nibble, top 4 bits of counter in low nibble
        bytes[6] = (@as(u8, 7) << 4) | @as(u8, @truncate((count >> 8) & 0x0F));

        // Byte 7: Lower 8 bits of counter
        bytes[7] = @truncate(count);

        // Byte 8: Variant in top 2 bits, 6 bits of random
        bytes[8] = 0x80 | (random[0] & 0x3F);

        // Remaining 7 bytes: random
        @memcpy(bytes[9..16], random[1..8]);

        return UUID7{
            .bytes = bytes,
        };
    }

    fn toBytes(self: UUID7) [16]u8 {
        return self.bytes;
    }

    pub fn print(self: UUID7, buf: *[36]u8) void {
        return printBytes(&self.toBytes(), buf);
    }

    pub fn toUUID(self: UUID7) UUID {
        const bytes: [16]u8 = self.toBytes();

        return .{ .bytes = bytes };
    }

    pub fn format(self: UUID7, writer: *std.Io.Writer) !void {
        return self.toUUID().format(writer);
    }
};

/// UUID v5 implementation using SHA-1 hashing
/// This is a name-based UUID that uses SHA-1 for hashing
pub const UUID5 = struct {
    bytes: [16]u8,

    pub const namespaces = struct {
        pub const dns: *const [16]u8 = &.{ 0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8 };
        pub const url: *const [16]u8 = &.{ 0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8 };
        pub const oid: *const [16]u8 = &.{ 0x6b, 0xa7, 0xb8, 0x12, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8 };
        pub const x500: *const [16]u8 = &.{ 0x6b, 0xa7, 0xb8, 0x14, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8 };

        pub fn get(namespace: []const u8) ?*const [16]u8 {
            if (eqlCaseInsensitiveASCII(namespace, "dns")) return dns;
            if (eqlCaseInsensitiveASCII(namespace, "url")) return url;
            if (eqlCaseInsensitiveASCII(namespace, "oid")) return oid;
            if (eqlCaseInsensitiveASCII(namespace, "x500")) return x500;
            return null;
        }

        fn eqlCaseInsensitiveASCII(a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            for (a, b) |c1, c2| {
                const l1 = if (c1 >= 'A' and c1 <= 'Z') c1 + 32 else c1;
                const l2 = if (c2 >= 'A' and c2 <= 'Z') c2 + 32 else c2;
                if (l1 != l2) return false;
            }
            return true;
        }
    };

    /// Generate a UUID v5 from a namespace UUID and name data
    pub fn init(namespace: *const [16]u8, name: []const u8) UUID5 {
        const hash = brk: {
            var sha1_hasher = std.crypto.hash.Sha1.init(.{});
            sha1_hasher.update(namespace);
            sha1_hasher.update(name);

            var hash: [20]u8 = undefined;
            sha1_hasher.final(&hash);

            break :brk hash;
        };

        // Take first 16 bytes of the hash
        var bytes: [16]u8 = hash[0..16].*;

        // Set version to 5 (bits 12-15 of time_hi_and_version)
        bytes[6] = (bytes[6] & 0x0F) | 0x50;

        // Set variant bits (bits 6-7 of clock_seq_hi_and_reserved)
        bytes[8] = (bytes[8] & 0x3F) | 0x80;

        return UUID5{
            .bytes = bytes,
        };
    }

    pub fn toBytes(self: UUID5) [16]u8 {
        return self.bytes;
    }

    pub fn print(self: UUID5, buf: *[36]u8) void {
        return printBytes(&self.toBytes(), buf);
    }

    pub fn toUUID(self: UUID5) UUID {
        const bytes: [16]u8 = self.toBytes();
        return .{ .bytes = bytes };
    }

    pub fn format(self: UUID5, writer: *std.Io.Writer) !void {
        return self.toUUID().format(writer);
    }
};

const std = @import("std");
const home_rt = @import("home_rt");
const Mutex = home_rt.threading.Mutex;

test "uuid: v4 sets version + variant bits" {
    const id = UUID.init();
    try std.testing.expectEqual(@as(u8, 0x40), id.bytes[6] & 0xF0);
    try std.testing.expectEqual(@as(u8, 0x80), id.bytes[8] & 0xC0);
}

test "uuid: round-trip print + parse" {
    const id = UUID.initWith(&[_]u8{
        0xde, 0xad, 0xbe, 0xef, 0xfe, 0xed, 0xfa, 0xce,
        0xba, 0xad, 0xf0, 0x0d, 0xab, 0xad, 0xca, 0xfe,
    });
    var buf: [36]u8 = undefined;
    id.print(&buf);
    const round = try UUID.parse(&buf);
    try std.testing.expectEqualSlices(u8, &id.bytes, &round.bytes);
}

test "uuid: v5 deterministic per-namespace" {
    const ns = UUID5.namespaces.dns;
    const a = UUID5.init(ns, "example.com");
    const b = UUID5.init(ns, "example.com");
    try std.testing.expectEqualSlices(u8, &a.bytes, &b.bytes);
    try std.testing.expectEqual(@as(u8, 0x50), a.bytes[6] & 0xF0);
    try std.testing.expectEqual(@as(u8, 0x80), a.bytes[8] & 0xC0);
}

test "uuid: namespace lookup is case-insensitive" {
    try std.testing.expect(UUID5.namespaces.get("DNS") == UUID5.namespaces.dns);
    try std.testing.expect(UUID5.namespaces.get("oId") == UUID5.namespaces.oid);
    try std.testing.expect(UUID5.namespaces.get("bogus") == null);
}
