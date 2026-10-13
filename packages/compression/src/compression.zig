//! Compression codecs exposed by the `compression` package build module.

const std = @import("std");

const gzip = @import("gzip.zig");
const zstd = @import("zstd.zig");
const brotli = @import("brotli.zig");
const lz4 = @import("lz4.zig");
const snappy = @import("snappy.zig");

pub const Gzip = gzip.Gzip;
pub const GzipCompressor = gzip.GzipCompressor;
pub const GzipDecompressor = gzip.GzipDecompressor;

pub const Zstd = zstd.Zstd;
pub const ZstdCompressor = zstd.ZstdCompressor;
pub const ZstdDecompressor = zstd.ZstdDecompressor;

pub const Brotli = brotli.Brotli;
pub const BrotliCompressor = brotli.BrotliCompressor;
pub const BrotliDecompressor = brotli.BrotliDecompressor;

pub const LZ4 = lz4.LZ4;
pub const LZ4Compressor = lz4.LZ4Compressor;
pub const LZ4Decompressor = lz4.LZ4Decompressor;

pub const Snappy = snappy.Snappy;
pub const SnappyCompressor = snappy.SnappyCompressor;
pub const SnappyDecompressor = snappy.SnappyDecompressor;

test {
    std.testing.refAllDecls(@This());
}
