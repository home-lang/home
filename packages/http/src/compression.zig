const std = @import("std");

/// HTTP compression support (gzip, deflate, brotli)
pub const Compression = struct {
    pub const Algorithm = enum {
        None,
        Gzip,
        Deflate,
        Brotli,

        pub fn fromString(str: []const u8) Algorithm {
            if (std.mem.eql(u8, str, "gzip")) return .Gzip;
            if (std.mem.eql(u8, str, "deflate")) return .Deflate;
            if (std.mem.eql(u8, str, "br")) return .Brotli;
            return .None;
        }

        pub fn toString(self: Algorithm) []const u8 {
            return switch (self) {
                .None => "identity",
                .Gzip => "gzip",
                .Deflate => "deflate",
                .Brotli => "br",
            };
        }
    };

    /// Compress data using specified algorithm
    pub fn compress(
        allocator: std.mem.Allocator,
        data: []const u8,
        algorithm: Algorithm,
    ) ![]u8 {
        return switch (algorithm) {
            .None => try allocator.dupe(u8, data),
            .Gzip => try compressGzip(allocator, data),
            .Deflate => try compressDeflate(allocator, data),
            .Brotli => try compressBrotli(allocator, data),
        };
    }

    /// Decompress data using specified algorithm
    pub fn decompress(
        allocator: std.mem.Allocator,
        data: []const u8,
        algorithm: Algorithm,
    ) ![]u8 {
        return switch (algorithm) {
            .None => try allocator.dupe(u8, data),
            .Gzip => try decompressGzip(allocator, data),
            .Deflate => try decompressDeflate(allocator, data),
            .Brotli => try decompressBrotli(allocator, data),
        };
    }

    /// Compress using gzip (RFC 1952)
    fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        var compressor = try std.compress.gzip.compressor(output.writer(), .{});
        try compressor.writer().writeAll(data);
        try compressor.finish();

        return output.toOwnedSlice();
    }

    /// Decompress using gzip
    fn decompressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var stream = std.io.fixedBufferStream(data);
        var decompressor = try std.compress.gzip.decompressor(stream.reader());

        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        try decompressor.reader().readAllArrayList(&output, std.math.maxInt(usize));

        return output.toOwnedSlice();
    }

    /// Compress using deflate (RFC 1951)
    fn compressDeflate(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        var compressor = try std.compress.deflate.compressor(output.writer(), .{});
        try compressor.writer().writeAll(data);
        try compressor.finish();

        return output.toOwnedSlice();
    }

    /// Decompress using deflate
    fn decompressDeflate(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var stream = std.io.fixedBufferStream(data);
        var decompressor = try std.compress.deflate.decompressor(allocator, stream.reader(), null);
        defer decompressor.deinit();

        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        try decompressor.reader().readAllArrayList(&output, std.math.maxInt(usize));

        return output.toOwnedSlice();
    }

    /// Compress using Brotli (RFC 7932)
    fn compressBrotli(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        // Use the Brotli implementation from the compression package
        const brotli = @import("../../compression/src/brotli.zig");

        var compressor = brotli.BrotliCompressor.init(allocator);
        defer compressor.deinit();

        return try compressor.compress(data, .{ .quality = 6 });
    }

    /// Decompress using Brotli
    fn decompressBrotli(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const brotli = @import("../../compression/src/brotli.zig");

        var decompressor = brotli.BrotliDecompressor.init(allocator);
        defer decompressor.deinit();

        return try decompressor.decompress(data);
    }

    /// Parse Accept-Encoding header and choose best algorithm
    pub fn negotiateEncoding(accept_encoding: []const u8) Algorithm {
        // Parse quality values and select best supported encoding
        var best_algo = Algorithm.None;
        var best_quality: f32 = 0.0;

        var iter = std.mem.splitScalar(u8, accept_encoding, ',');
        while (iter.next()) |encoding| {
            const trimmed = std.mem.trim(u8, encoding, " ");

            var quality: f32 = 1.0;
            var algo_str = trimmed;

            // Check for quality value
            if (std.mem.indexOf(u8, trimmed, ";q=")) |q_pos| {
                algo_str = std.mem.trim(u8, trimmed[0..q_pos], " ");
                const q_str = trimmed[q_pos + 3 ..];
                quality = std.fmt.parseFloat(f32, q_str) catch 1.0;
            }

            const algo = Algorithm.fromString(algo_str);
            if (quality > best_quality and algo != .None) {
                best_algo = algo;
                best_quality = quality;
            }
        }

        return best_algo;
    }
};

/// Streaming compression for large responses
pub const StreamingCompressor = struct {
    allocator: std.mem.Allocator,
    algorithm: Compression.Algorithm,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, algorithm: Compression.Algorithm) StreamingCompressor {
        return .{
            .allocator = allocator,
            .algorithm = algorithm,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *StreamingCompressor) void {
        self.buffer.deinit();
    }

    /// Write data chunk
    pub fn write(self: *StreamingCompressor, data: []const u8) !void {
        // Compress chunk and add to buffer
        const compressed = try Compression.compress(self.allocator, data, self.algorithm);
        defer self.allocator.free(compressed);

        try self.buffer.appendSlice(compressed);
    }

    /// Flush and get all compressed data
    pub fn flush(self: *StreamingCompressor) ![]u8 {
        return try self.buffer.toOwnedSlice();
    }
};

test "Compression gzip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original = "Hello, World! This is a test of gzip compression.";

    const compressed = try Compression.compress(allocator, original, .Gzip);
    defer allocator.free(compressed);

    // Compressed should be smaller (or at least different)
    try testing.expect(compressed.len > 0);

    const decompressed = try Compression.decompress(allocator, compressed, .Gzip);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(original, decompressed);
}

test "Compression negotiate encoding" {
    const algo = Compression.negotiateEncoding("gzip, deflate, br;q=0.8");
    // Should prefer gzip (quality 1.0) over br (quality 0.8)
    try std.testing.expectEqual(Compression.Algorithm.Gzip, algo);
}
