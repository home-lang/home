const std = @import("std");

/// Compression package - provides various compression algorithms
pub const Gzip = @import("gzip.zig").Gzip;
pub const GzipCompressor = @import("gzip.zig").GzipCompressor;
pub const GzipDecompressor = @import("gzip.zig").GzipDecompressor;

pub const Zstd = @import("zstd.zig").Zstd;
pub const ZstdCompressor = @import("zstd.zig").ZstdCompressor;
pub const ZstdDecompressor = @import("zstd.zig").ZstdDecompressor;

test {
    @import("std").testing.refAllDecls(@This());
}
