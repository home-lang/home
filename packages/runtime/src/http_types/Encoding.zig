// Copied verbatim from bun/src/http_types/Encoding.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const Encoding = enum {
    identity,
    gzip,
    deflate,
    brotli,
    zstd,
    chunked,

    pub fn canUseLibDeflate(this: Encoding) bool {
        return switch (this) {
            .gzip, .deflate => true,
            else => false,
        };
    }

    pub fn isCompressed(this: Encoding) bool {
        return switch (this) {
            .brotli, .gzip, .deflate, .zstd => true,
            else => false,
        };
    }
};

test "Encoding flags compressed vs identity" {
    const std = @import("std");
    try std.testing.expect(Encoding.gzip.isCompressed());
    try std.testing.expect(Encoding.brotli.isCompressed());
    try std.testing.expect(Encoding.zstd.isCompressed());
    try std.testing.expect(!Encoding.identity.isCompressed());
    try std.testing.expect(!Encoding.chunked.isCompressed());
}

test "Encoding.canUseLibDeflate flags gzip/deflate only" {
    const std = @import("std");
    try std.testing.expect(Encoding.gzip.canUseLibDeflate());
    try std.testing.expect(Encoding.deflate.canUseLibDeflate());
    try std.testing.expect(!Encoding.brotli.canUseLibDeflate());
    try std.testing.expect(!Encoding.zstd.canUseLibDeflate());
}
