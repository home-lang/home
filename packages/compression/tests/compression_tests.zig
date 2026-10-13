const std = @import("std");
const compression = @import("compression");

const testing = std.testing;

test "gzip round trips through the public module" {
    var gzip = compression.Gzip.init(testing.io, testing.allocator, .balanced);
    const input = "Home gzip uses the std.Io flate implementation.";

    const encoded = try gzip.compress(input);
    defer testing.allocator.free(encoded);
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, encoded[0..2]);

    const decoded = try gzip.decompress(encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(input, decoded);
}

test "gzip validates its checksum" {
    var gzip = compression.Gzip.init(testing.io, testing.allocator, .best_speed);
    const encoded = try gzip.compress("checksum me");
    defer testing.allocator.free(encoded);

    encoded[encoded.len - 8] ^= 0xff;
    try testing.expectError(error.WrongGzipChecksum, gzip.decompress(encoded));
}

test "gzip streaming API emits a complete frame" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var compressor = try compression.GzipCompressor.init(
        testing.io,
        testing.allocator,
        &output.writer,
        .best_compression,
    );
    defer compressor.deinit();
    try compressor.write("stream ");
    try compressor.write("payload");
    try compressor.finish();

    var gzip = compression.Gzip.init(testing.io, testing.allocator, .balanced);
    const decoded = try gzip.decompress(output.written());
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("stream payload", decoded);
}

test "zstd preserves the established block wire format" {
    var zstd = compression.Zstd.init(testing.allocator, .balanced);
    const input = "abcabcabcabcabcabc";
    const expected_block = [_]u8{
        'a',  'b', 'c', 'a', 'b', 'c',
        0xff, 6,   0,   6,   0,   0xff,
        12,   0,   6,   0,
    };

    const encoded = try zstd.compress(input);
    defer testing.allocator.free(encoded);
    try testing.expectEqualSlices(u8, &expected_block, encoded[18 .. encoded.len - 4]);
    const decoded = try zstd.decompress(encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(input, decoded);
}

test "zstd round trips an empty frame" {
    var zstd = compression.Zstd.init(testing.allocator, .fastest);
    const encoded = try zstd.compress("");
    defer testing.allocator.free(encoded);
    const decoded = try zstd.decompress(encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "zstd rejects invalid magic and checksums" {
    var zstd = compression.Zstd.init(testing.allocator, .good);
    const encoded = try zstd.compress("validate this frame");
    defer testing.allocator.free(encoded);

    encoded[0] ^= 0xff;
    try testing.expectError(error.InvalidZstdMagic, zstd.decompress(encoded));
    encoded[0] ^= 0xff;

    encoded[encoded.len - 1] ^= 0xff;
    try testing.expectError(error.ChecksumMismatch, zstd.decompress(encoded));
}

test "zstd rejects truncated blocks" {
    var zstd = compression.Zstd.init(testing.allocator, .balanced);
    const encoded = try zstd.compress("truncated block");
    defer testing.allocator.free(encoded);

    // Frame header is 14 bytes. Make the first block claim more bytes than
    // remain before the checksum.
    std.mem.writeInt(u32, encoded[14..18], (@as(u32, 4096) << 3) | 1, .little);
    try testing.expectError(error.EndOfStream, zstd.decompress(encoded));
}

test "zstd streaming API emits a validated frame" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var compressor = compression.ZstdCompressor.init(
        testing.allocator,
        &output.writer,
        .balanced,
    );
    defer compressor.deinit();
    try compressor.write("two ");
    try compressor.write("chunks");
    try compressor.finish();

    var input: std.Io.Reader = .fixed(output.written());
    var decompressor = compression.ZstdDecompressor.init(testing.allocator, &input);
    defer decompressor.deinit();
    var decoded: [10]u8 = undefined;
    const count = try decompressor.read(&decoded);
    try testing.expectEqualStrings("two chunks", decoded[0..count]);
    try testing.expectEqual(@as(usize, 0), try decompressor.read(&decoded));
}
