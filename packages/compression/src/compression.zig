const std = @import("std");

/// Compression package - provides various compression algorithms
pub const Gzip = @import("gzip.zig").Gzip;
pub const GzipCompressor = @import("gzip.zig").GzipCompressor;
pub const GzipDecompressor = @import("gzip.zig").GzipDecompressor;

pub const Zstd = @import("zstd.zig").Zstd;
pub const ZstdCompressor = @import("zstd.zig").ZstdCompressor;
pub const ZstdDecompressor = @import("zstd.zig").ZstdDecompressor;

pub const Brotli = @import("brotli.zig").Brotli;
pub const BrotliCompressor = @import("brotli.zig").BrotliCompressor;
pub const BrotliDecompressor = @import("brotli.zig").BrotliDecompressor;

pub const LZ4 = @import("lz4.zig").LZ4;
pub const LZ4Compressor = @import("lz4.zig").LZ4Compressor;
pub const LZ4Decompressor = @import("lz4.zig").LZ4Decompressor;

pub const Snappy = @import("snappy.zig").Snappy;
pub const SnappyCompressor = @import("snappy.zig").SnappyCompressor;
pub const SnappyDecompressor = @import("snappy.zig").SnappyDecompressor;

test {
    @import("std").testing.refAllDecls(@This());
}
