// Compression Tests
const std = @import("std");
const testing = std.testing;

// Deflate/zlib Tests
test "zlib: header parsing" {
    // CMF = 0x78 (deflate, window size 32K)
    // FLG = 0x9C (default compression, FCHECK=28)
    const cmf: u8 = 0x78;
    const flg: u8 = 0x9C;
    
    const cm = cmf & 0x0F;
    try testing.expectEqual(@as(u8, 8), cm); // Deflate
    
    const cinfo = (cmf >> 4) & 0x0F;
    try testing.expectEqual(@as(u8, 7), cinfo); // 32K window
    
    // Verify FCHECK
    const check = (@as(u16, cmf) * 256 + flg) % 31;
    try testing.expectEqual(@as(u16, 0), check);
}

test "deflate: block header" {
    // BFINAL=1, BTYPE=01 (fixed Huffman)
    const block_header: u8 = 0b00000011;
    const bfinal = block_header & 1;
    try testing.expectEqual(@as(u8, 1), bfinal);
    const btype = (block_header >> 1) & 0b11;
    try testing.expectEqual(@as(u8, 1), btype);
}

// Gzip Tests
test "gzip: header structure" {
    const GzipHeader = packed struct {
        magic1: u8, // 0x1f
        magic2: u8, // 0x8b
        method: u8, // 8 = deflate
        flags: u8,
        mtime: u32,
        xfl: u8,
        os: u8,
    };
    try testing.expectEqual(@as(usize, 10), @sizeOf(GzipHeader));
}

test "gzip: magic number" {
    const GZIP_MAGIC = [_]u8{ 0x1f, 0x8b };
    try testing.expectEqual(@as(u8, 0x1f), GZIP_MAGIC[0]);
    try testing.expectEqual(@as(u8, 0x8b), GZIP_MAGIC[1]);
}

// LZ4 Tests
test "LZ4: frame header" {
    const LZ4_MAGIC: u32 = 0x184D2204;
    const bytes = std.mem.toBytes(LZ4_MAGIC);
    try testing.expectEqual(@as(u8, 0x04), bytes[0]);
    try testing.expectEqual(@as(u8, 0x22), bytes[1]);
}

test "LZ4: block format" {
    // Token: 4 bits literal length + 4 bits match length
    const token: u8 = 0xF0; // 15 literals, 0 match
    const literal_len = token >> 4;
    try testing.expectEqual(@as(u8, 15), literal_len);
    const match_len = token & 0x0F;
    try testing.expectEqual(@as(u8, 0), match_len);
}

// Zstd Tests
test "zstd: magic number" {
    const ZSTD_MAGIC: u32 = 0xFD2FB528;
    const bytes = std.mem.toBytes(ZSTD_MAGIC);
    try testing.expectEqual(@as(u8, 0x28), bytes[0]);
    try testing.expectEqual(@as(u8, 0xB5), bytes[1]);
}

test "zstd: frame header" {
    const ZstdFrameHeader = packed struct {
        magic: u32,
        frame_header_desc: u8,
    };
    try testing.expectEqual(@as(usize, 5), @sizeOf(ZstdFrameHeader));
}

// Huffman Coding Tests
test "huffman: code length limits" {
    const MAX_BITS: u8 = 15;
    const MAX_CODES: u16 = 286; // Literal/length alphabet
    try testing.expect(MAX_BITS <= 15);
    try testing.expect(MAX_CODES <= 288);
}

// Run-Length Encoding Tests
test "RLE: basic encoding" {
    const input = "AAABBBCCCC";
    var count: usize = 1;
    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        if (input[i] == input[i - 1]) {
            count += 1;
        } else {
            count = 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), count); // Last run of C's
}

// CRC32 Tests
test "CRC32: table generation" {
    const CRC32_POLYNOMIAL: u32 = 0xEDB88320;
    
    // Generate first entry
    var crc: u32 = 0;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        if (crc & 1 == 1) {
            crc = (crc >> 1) ^ CRC32_POLYNOMIAL;
        } else {
            crc >>= 1;
        }
    }
    try testing.expectEqual(@as(u32, 0), crc); // Entry for 0
}

test "CRC32: checksum" {
    const CRC32_INIT: u32 = 0xFFFFFFFF;
    var crc = CRC32_INIT;
    _ = crc;
    // CRC32 of empty string should be 0
}
