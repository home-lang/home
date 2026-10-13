const std = @import("std");

const flate = std.compress.flate;

/// GZIP compression and decompression (RFC 1952).
pub const Gzip = struct {
    io: std.Io,
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

    pub fn init(io: std.Io, allocator: std.mem.Allocator, level: CompressionLevel) Gzip {
        return .{ .io = io, .allocator = allocator, .level = level };
    }

    pub fn compress(self: *Gzip, data: []const u8) ![]u8 {
        var output = try std.Io.Writer.Allocating.initCapacity(self.allocator, 4096);
        defer output.deinit();

        var compressor = try GzipCompressor.init(
            self.io,
            self.allocator,
            &output.writer,
            self.level,
        );
        defer compressor.deinit();

        try compressor.write(data);
        try compressor.finish();
        return output.toOwnedSlice();
    }

    pub fn decompress(self: *Gzip, data: []const u8) ![]u8 {
        var input: std.Io.Reader = .fixed(data);
        var decompressor = try GzipDecompressor.init(self.allocator, &input);
        defer decompressor.deinit();

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var buffer: [8192]u8 = undefined;
        while (true) {
            const count = try decompressor.read(&buffer);
            if (count == 0) break;
            try output.writer.writeAll(buffer[0..count]);
        }
        return output.toOwnedSlice();
    }
};

/// Streaming GZIP compressor. The clock is injected so tests and embedders use
/// the same `std.Io` source as the rest of their runtime.
pub const GzipCompressor = struct {
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    work: []u8,
    compressor: flate.Compress,
    crc: std.hash.Crc32 = .init(),
    size: u32 = 0,
    finished: bool = false,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        output: *std.Io.Writer,
        level: Gzip.CompressionLevel,
    ) !GzipCompressor {
        try writeHeader(io, output);
        try output.rebase(0, 8);

        const work = try allocator.alloc(u8, flate.max_window_len);
        errdefer allocator.free(work);

        return .{
            .allocator = allocator,
            .output = output,
            .work = work,
            .compressor = try flate.Compress.init(output, work, .raw, options(level)),
        };
    }

    pub fn deinit(self: *GzipCompressor) void {
        self.allocator.free(self.work);
    }

    pub fn write(self: *GzipCompressor, data: []const u8) !void {
        if (self.finished) return error.AlreadyFinished;
        self.crc.update(data);
        self.size +%= @truncate(data.len);
        try self.compressor.writer.writeAll(data);
    }

    pub fn finish(self: *GzipCompressor) !void {
        if (self.finished) return error.AlreadyFinished;
        try self.compressor.finish();
        try self.output.writeInt(u32, self.crc.final(), .little);
        try self.output.writeInt(u32, self.size, .little);
        try self.output.flush();
        self.finished = true;
    }

    fn writeHeader(io: std.Io, output: *std.Io.Writer) !void {
        const seconds = std.Io.Clock.real.now(io).toSeconds();
        const mtime: u32 = if (seconds < 0)
            0
        else if (seconds > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(seconds);

        try output.writeAll(&.{ 0x1f, 0x8b, 0x08, 0x00 });
        try output.writeInt(u32, mtime, .little);
        try output.writeByte(0);
        try output.writeByte(@backingInt(Gzip.Header.OS.unix));
    }

    fn options(level: Gzip.CompressionLevel) flate.Compress.Options {
        return switch (level) {
            .no_compression, .best_speed => .level_1,
            .balanced => .level_6,
            .best_compression => .level_9,
        };
    }
};

/// Streaming GZIP decompressor backed by Zig's RFC 1952 implementation.
pub const GzipDecompressor = struct {
    allocator: std.mem.Allocator,
    window: []u8,
    decompressor: flate.Decompress,
    crc: std.hash.Crc32 = .init(),
    size: u32 = 0,
    validated: bool = false,

    pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader) !GzipDecompressor {
        const window = try allocator.alloc(u8, flate.max_window_len);
        errdefer allocator.free(window);
        return .{
            .allocator = allocator,
            .window = window,
            .decompressor = flate.Decompress.init(input, .gzip, window),
        };
    }

    pub fn deinit(self: *GzipDecompressor) void {
        self.allocator.free(self.window);
    }

    pub fn read(self: *GzipDecompressor, buffer: []u8) !usize {
        const count = self.decompressor.reader.readSliceShort(buffer) catch |err|
            return self.decompressor.err orelse err;
        if (count != 0) {
            self.crc.update(buffer[0..count]);
            self.size +%= @truncate(count);
            return count;
        }
        if (!self.validated) {
            const metadata = self.decompressor.container_metadata.gzip;
            if (metadata.crc != self.crc.final()) return error.WrongGzipChecksum;
            if (metadata.count != self.size) return error.WrongGzipSize;
            self.validated = true;
        }
        return 0;
    }
};
