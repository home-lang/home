const std = @import("std");

/// GZIP compression and decompression (RFC 1952)
///
/// Features:
/// - DEFLATE algorithm
/// - CRC32 checksums
/// - Multiple compression levels
/// - Streaming support
/// - Header metadata
pub const Gzip = struct {
    allocator: std.mem.Allocator,
    level: CompressionLevel,

    pub const CompressionLevel = enum(u8) {
        no_compression = 0,
        best_speed = 1,
        balanced = 6,
        best_compression = 9,
    };

    pub const Header = struct {
        modification_time: u32,
        compression_method: u8,
        flags: Flags,
        os: OS,
        extra: ?[]const u8,
        filename: ?[]const u8,
        comment: ?[]const u8,

        pub const Flags = packed struct {
            text: bool = false,
            crc: bool = false,
            extra: bool = false,
            name: bool = false,
            comment: bool = false,
            _reserved: u3 = 0,
        };

        pub const OS = enum(u8) {
            fat = 0,
            amiga = 1,
            vms = 2,
            unix = 3,
            vm_cms = 4,
            atari = 5,
            hpfs = 6,
            macintosh = 7,
            z_system = 8,
            cpm = 9,
            tops20 = 10,
            ntfs = 11,
            qdos = 12,
            acorn = 13,
            unknown = 255,
        };
    };

    const GZIP_MAGIC = [2]u8{ 0x1f, 0x8b };
    const GZIP_METHOD_DEFLATE: u8 = 8;

    pub fn init(allocator: std.mem.Allocator, level: CompressionLevel) Gzip {
        return .{
            .allocator = allocator,
            .level = level,
        };
    }

    /// Compress data with GZIP
    pub fn compress(self: *Gzip, data: []const u8) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Write header
        try self.writeHeader(output.writer(), .{
            .modification_time = @intCast(std.time.timestamp()),
            .compression_method = GZIP_METHOD_DEFLATE,
            .flags = .{},
            .os = .unix,
            .extra = null,
            .filename = null,
            .comment = null,
        });

        // Compress with DEFLATE
        const compressed = try self.deflate(data);
        defer self.allocator.free(compressed);

        try output.appendSlice(compressed);

        // Write CRC32
        const crc = std.hash.Crc32.hash(data);
        try output.writer().writeInt(u32, crc, .little);

        // Write uncompressed size (modulo 2^32)
        const size: u32 = @truncate(data.len);
        try output.writer().writeInt(u32, size, .little);

        return output.toOwnedSlice();
    }

    /// Decompress GZIP data
    pub fn decompress(self: *Gzip, data: []const u8) ![]u8 {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Read and validate header
        const header = try self.readHeader(reader);
        defer self.freeHeader(header);

        if (header.compression_method != GZIP_METHOD_DEFLATE) {
            return error.UnsupportedCompressionMethod;
        }

        // Get compressed data (everything except header, CRC32, and size)
        const header_size = @as(usize, @intCast(stream.pos));
        const footer_size = 8; // CRC32 + size
        const compressed_size = data.len - header_size - footer_size;
        const compressed = data[header_size .. header_size + compressed_size];

        // Decompress
        const decompressed = try self.inflate(compressed);
        errdefer self.allocator.free(decompressed);

        // Verify CRC32
        const stored_crc = std.mem.readInt(u32, data[data.len - 8 .. data.len - 4][0..4], .little);
        const calculated_crc = std.hash.Crc32.hash(decompressed);

        if (stored_crc != calculated_crc) {
            self.allocator.free(decompressed);
            return error.ChecksumMismatch;
        }

        // Verify size
        const stored_size = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
        const actual_size: u32 = @truncate(decompressed.len);

        if (stored_size != actual_size) {
            self.allocator.free(decompressed);
            return error.SizeMismatch;
        }

        return decompressed;
    }

    fn writeHeader(self: *Gzip, writer: anytype, header: Header) !void {
        _ = self;

        // Magic number
        try writer.writeAll(&GZIP_MAGIC);

        // Compression method
        try writer.writeByte(header.compression_method);

        // Flags
        try writer.writeByte(@bitCast(header.flags));

        // Modification time
        try writer.writeInt(u32, header.modification_time, .little);

        // Extra flags (compression level indicator)
        try writer.writeByte(0);

        // OS
        try writer.writeByte(@intFromEnum(header.os));

        // Optional fields
        if (header.extra) |extra| {
            try writer.writeInt(u16, @intCast(extra.len), .little);
            try writer.writeAll(extra);
        }

        if (header.filename) |filename| {
            try writer.writeAll(filename);
            try writer.writeByte(0);
        }

        if (header.comment) |comment| {
            try writer.writeAll(comment);
            try writer.writeByte(0);
        }
    }

    fn readHeader(self: *Gzip, reader: anytype) !Header {
        // Read magic number
        var magic: [2]u8 = undefined;
        try reader.readNoEof(&magic);

        if (!std.mem.eql(u8, &magic, &GZIP_MAGIC)) {
            return error.InvalidGzipHeader;
        }

        // Read compression method
        const method = try reader.readByte();

        // Read flags
        const flags: Header.Flags = @bitCast(try reader.readByte());

        // Read modification time
        const mtime = try reader.readInt(u32, .little);

        // Read extra flags
        _ = try reader.readByte();

        // Read OS
        const os: Header.OS = @enumFromInt(try reader.readByte());

        // Read optional fields
        var extra: ?[]const u8 = null;
        if (flags.extra) {
            const len = try reader.readInt(u16, .little);
            const data = try self.allocator.alloc(u8, len);
            try reader.readNoEof(data);
            extra = data;
        }

        var filename: ?[]const u8 = null;
        if (flags.name) {
            var name_list = std.ArrayList(u8).init(self.allocator);
            while (true) {
                const byte = try reader.readByte();
                if (byte == 0) break;
                try name_list.append(byte);
            }
            filename = try name_list.toOwnedSlice();
        }

        var comment: ?[]const u8 = null;
        if (flags.comment) {
            var comment_list = std.ArrayList(u8).init(self.allocator);
            while (true) {
                const byte = try reader.readByte();
                if (byte == 0) break;
                try comment_list.append(byte);
            }
            comment = try comment_list.toOwnedSlice();
        }

        if (flags.crc) {
            _ = try reader.readInt(u16, .little);
        }

        return Header{
            .modification_time = mtime,
            .compression_method = method,
            .flags = flags,
            .os = os,
            .extra = extra,
            .filename = filename,
            .comment = comment,
        };
    }

    fn freeHeader(self: *Gzip, header: Header) void {
        if (header.extra) |extra| self.allocator.free(extra);
        if (header.filename) |filename| self.allocator.free(filename);
        if (header.comment) |comment| self.allocator.free(comment);
    }

    fn deflate(self: *Gzip, data: []const u8) ![]u8 {
        // Use Zig's built-in DEFLATE compression
        var compressed = std.ArrayList(u8).init(self.allocator);
        errdefer compressed.deinit();

        var compressor = try std.compress.flate.compressor(
            self.allocator,
            compressed.writer(),
            .{ .level = @enumFromInt(@intFromEnum(self.level)) },
        );
        defer compressor.deinit();

        try compressor.writer().writeAll(data);
        try compressor.close();

        return compressed.toOwnedSlice();
    }

    fn inflate(self: *Gzip, data: []const u8) ![]u8 {
        // Use Zig's built-in DEFLATE decompression
        var stream = std.io.fixedBufferStream(data);
        var decompressor = try std.compress.flate.decompressor(self.allocator, stream.reader(), null);
        defer decompressor.deinit();

        var decompressed = std.ArrayList(u8).init(self.allocator);
        errdefer decompressed.deinit();

        try decompressor.reader().readAllArrayList(&decompressed, std.math.maxInt(usize));

        return decompressed.toOwnedSlice();
    }
};

/// Streaming GZIP compressor
pub const GzipCompressor = struct {
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    compressor: std.compress.flate.Compressor(std.io.AnyWriter),
    crc: std.hash.Crc32,
    size: u32,
    header_written: bool,

    pub fn init(allocator: std.mem.Allocator, writer: std.io.AnyWriter) !GzipCompressor {
        const compressor = try std.compress.flate.compressor(allocator, writer, .{});

        return .{
            .allocator = allocator,
            .writer = writer,
            .compressor = compressor,
            .crc = std.hash.Crc32.init(),
            .size = 0,
            .header_written = false,
        };
    }

    pub fn deinit(self: *GzipCompressor) void {
        self.compressor.deinit();
    }

    pub fn write(self: *GzipCompressor, data: []const u8) !void {
        if (!self.header_written) {
            // Write GZIP header
            try self.writer.writeAll(&Gzip.GZIP_MAGIC);
            try self.writer.writeByte(Gzip.GZIP_METHOD_DEFLATE);
            try self.writer.writeByte(0); // Flags
            try self.writer.writeInt(u32, @intCast(std.time.timestamp()), .little);
            try self.writer.writeByte(0); // Extra flags
            try self.writer.writeByte(@intFromEnum(Gzip.Header.OS.unix));
            self.header_written = true;
        }

        // Update CRC and size
        self.crc.update(data);
        self.size +%= @truncate(data.len);

        // Compress
        try self.compressor.writer().writeAll(data);
    }

    pub fn finish(self: *GzipCompressor) !void {
        try self.compressor.close();

        // Write CRC32 and size
        try self.writer.writeInt(u32, self.crc.final(), .little);
        try self.writer.writeInt(u32, self.size, .little);
    }
};

/// Streaming GZIP decompressor
pub const GzipDecompressor = struct {
    allocator: std.mem.Allocator,
    reader: std.io.AnyReader,
    decompressor: std.compress.flate.Decompressor(std.io.AnyReader),
    crc: std.hash.Crc32,
    size: u32,
    header_read: bool,
    finished: bool,

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) !GzipDecompressor {
        return .{
            .allocator = allocator,
            .reader = reader,
            .decompressor = undefined, // Will be initialized after reading header
            .crc = std.hash.Crc32.init(),
            .size = 0,
            .header_read = false,
            .finished = false,
        };
    }

    pub fn deinit(self: *GzipDecompressor) void {
        if (self.header_read) {
            self.decompressor.deinit();
        }
    }

    pub fn read(self: *GzipDecompressor, buffer: []u8) !usize {
        if (!self.header_read) {
            // Read and validate header
            var gzip = Gzip.init(self.allocator, .balanced);
            const header = try gzip.readHeader(self.reader);
            defer gzip.freeHeader(header);

            if (header.compression_method != Gzip.GZIP_METHOD_DEFLATE) {
                return error.UnsupportedCompressionMethod;
            }

            self.decompressor = try std.compress.flate.decompressor(self.allocator, self.reader, null);
            self.header_read = true;
        }

        if (self.finished) return 0;

        const n = try self.decompressor.reader().read(buffer);
        if (n == 0) {
            // Read footer
            var footer: [8]u8 = undefined;
            try self.reader.readNoEof(&footer);

            const stored_crc = std.mem.readInt(u32, footer[0..4], .little);
            const stored_size = std.mem.readInt(u32, footer[4..8], .little);

            if (stored_crc != self.crc.final()) {
                return error.ChecksumMismatch;
            }

            if (stored_size != self.size) {
                return error.SizeMismatch;
            }

            self.finished = true;
            return 0;
        }

        self.crc.update(buffer[0..n]);
        self.size +%= @truncate(n);

        return n;
    }
};
