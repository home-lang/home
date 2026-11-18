//! Interoperability with the reference tools: the fixtures under `fixtures/`
//! were written by brotli 1.2.0, zstd 1.5.7 and lz4 1.11.1 from `text.txt`,
//! `binary.bin` and `empty.bin` (see `fixtures/README.md`).

const std = @import("std");
const compression = @import("compression");
const testing = std.testing;

const inputs = .{
    .{ "text", @embedFile("fixtures/text.txt") },
    .{ "binary", @embedFile("fixtures/binary.bin") },
    .{ "empty", @embedFile("fixtures/empty.bin") },
};

fn expectDecodes(comptime name: []const u8, comptime suffix: []const u8, expected: []const u8, decode: anytype) !void {
    const encoded = @embedFile("fixtures/" ++ name ++ suffix);
    const decoded = decode(encoded) catch |err| {
        std.debug.print("fixtures/{s}{s}: {t}\n", .{ name, suffix, err });
        return err;
    };
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, expected, decoded);
}

fn brotliDecode(encoded: []const u8) ![]u8 {
    var brotli = try compression.Brotli.init(testing.allocator, 6, 22);
    return brotli.decompress(encoded);
}

test "brotli decodes streams written by the reference encoder" {
    inline for (inputs) |input| {
        inline for (.{ ".q0.br", ".q5.br", ".q11.br", ".w10.br" }) |suffix| {
            try expectDecodes(input[0], suffix, input[1], brotliDecode);
        }
    }
}

fn zstdDecode(encoded: []const u8) ![]u8 {
    var zstd = compression.Zstd.init(testing.allocator, .balanced);
    return zstd.decompress(encoded);
}

fn lz4Decode(encoded: []const u8) ![]u8 {
    var lz4 = compression.LZ4.init(testing.allocator, 1);
    return lz4.decompress(encoded);
}

test "zstd decodes frames written by the reference encoder" {
    inline for (inputs) |input| {
        inline for (.{ ".1.zst", ".19.zst", ".nocheck.zst" }) |suffix| {
            try expectDecodes(input[0], suffix, input[1], zstdDecode);
        }
    }
    // Two frames back to back decode to both contents.
    const multi = try zstdDecode(@embedFile("fixtures/multi.zst"));
    defer testing.allocator.free(multi);
    const text = @embedFile("fixtures/text.txt");
    try testing.expectEqualSlices(u8, text, multi[0..text.len]);
    try testing.expectEqualSlices(u8, @embedFile("fixtures/binary.bin"), multi[text.len..]);
}

test "lz4 decodes frames written by the reference encoder" {
    inline for (inputs) |input| {
        inline for (.{ ".lz4", ".hc-linked.lz4", ".legacy.lz4" }) |suffix| {
            try expectDecodes(input[0], suffix, input[1], lz4Decode);
        }
    }
}

/// Corrupted streams must fail cleanly, never crash or hang.
fn survivesCorruption(comptime file: []const u8, decode: anytype) !void {
    const original = @embedFile("fixtures/" ++ file);
    const copy = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(copy);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    for (0..300) |_| {
        @memcpy(copy, original);
        for (0..1 + random.uintLessThan(usize, 4)) |_| {
            copy[random.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << random.int(u3);
        }
        const cut = if (random.boolean()) copy.len else random.uintLessThan(usize, copy.len);
        if (decode(copy[0..cut])) |decoded| testing.allocator.free(decoded) else |_| {}
    }
}

test "corrupted streams are rejected without crashing" {
    try survivesCorruption("text.q11.br", brotliDecode);
    try survivesCorruption("binary.q5.br", brotliDecode);
    try survivesCorruption("text.hc-linked.lz4", lz4Decode);
    try survivesCorruption("binary.legacy.lz4", lz4Decode);
    try survivesCorruption("text.19.zst", zstdDecode);
}
