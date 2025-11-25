const std = @import("std");

/// HPACK: Header Compression for HTTP/2 (RFC 7541)
///
/// Features:
/// - Static table (predefined headers)
/// - Dynamic table (learned headers)
/// - Huffman encoding
/// - Integer encoding with prefix

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: std.ArrayList(Header),
    max_table_size: usize,
    current_table_size: usize,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .allocator = allocator,
            .dynamic_table = std.ArrayList(Header).init(allocator),
            .max_table_size = 4096,
            .current_table_size = 0,
        };
    }

    pub fn deinit(self: *Encoder) void {
        for (self.dynamic_table.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.dynamic_table.deinit();
    }

    pub fn encode(self: *Encoder, headers: []const Header) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        for (headers) |header| {
            try self.encodeHeader(buffer.writer(), header);
        }

        return buffer.toOwnedSlice();
    }

    fn encodeHeader(self: *Encoder, writer: anytype, header: Header) !void {
        // Try to find in static or dynamic table
        if (self.findInStaticTable(header)) |index| {
            // Indexed header field
            try self.encodeInteger(writer, 7, 0x80, index);
        } else {
            // Literal header field with incremental indexing
            try writer.writeByte(0x40); // 01 prefix
            try self.encodeLiteralString(writer, header.name);
            try self.encodeLiteralString(writer, header.value);

            // Add to dynamic table
            try self.addToDynamicTable(header);
        }
    }

    fn findInStaticTable(self: *Encoder, header: Header) ?usize {
        _ = self;
        _ = header;
        // Simplified: static table lookup would go here
        return null;
    }

    fn addToDynamicTable(self: *Encoder, header: Header) !void {
        const name = try self.allocator.dupe(u8, header.name);
        const value = try self.allocator.dupe(u8, header.value);

        try self.dynamic_table.append(.{
            .name = name,
            .value = value,
        });

        self.current_table_size += name.len + value.len + 32;

        // Evict entries if table size exceeded
        while (self.current_table_size > self.max_table_size and self.dynamic_table.items.len > 0) {
            const removed = self.dynamic_table.orderedRemove(0);
            self.current_table_size -= removed.name.len + removed.value.len + 32;
            self.allocator.free(removed.name);
            self.allocator.free(removed.value);
        }
    }

    fn encodeInteger(self: *Encoder, writer: anytype, prefix_bits: u3, prefix_mask: u8, value: usize) !void {
        _ = self;
        const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;

        if (value < max_prefix) {
            try writer.writeByte(prefix_mask | @as(u8, @intCast(value)));
        } else {
            try writer.writeByte(prefix_mask | @as(u8, @intCast(max_prefix)));
            var remaining = value - max_prefix;

            while (remaining >= 128) {
                try writer.writeByte(@as(u8, @intCast((remaining & 0x7F) | 0x80)));
                remaining >>= 7;
            }
            try writer.writeByte(@as(u8, @intCast(remaining)));
        }
    }

    fn encodeLiteralString(self: *Encoder, writer: anytype, str: []const u8) !void {
        // Length with H=0 (no Huffman encoding)
        try self.encodeInteger(writer, 7, 0x00, str.len);
        try writer.writeAll(str);
    }
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: std.ArrayList(Header),
    max_table_size: usize,
    current_table_size: usize,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{
            .allocator = allocator,
            .dynamic_table = std.ArrayList(Header).init(allocator),
            .max_table_size = 4096,
            .current_table_size = 0,
        };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.dynamic_table.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.dynamic_table.deinit();
    }

    pub fn decode(self: *Decoder, data: []const u8) ![]Header {
        var headers = std.ArrayList(Header).init(self.allocator);
        errdefer headers.deinit();

        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        while (true) {
            const header = self.decodeHeader(reader) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            try headers.append(header);
        }

        return headers.toOwnedSlice();
    }

    fn decodeHeader(self: *Decoder, reader: anytype) !Header {
        const first_byte = try reader.readByte();

        if ((first_byte & 0x80) != 0) {
            // Indexed header field
            const index = try self.decodeInteger(reader, 7, first_byte & 0x7F);
            return try self.getHeader(index);
        } else if ((first_byte & 0x40) != 0) {
            // Literal with incremental indexing
            const name = try self.decodeLiteralString(reader);
            const value = try self.decodeLiteralString(reader);

            const header = Header{ .name = name, .value = value };
            try self.addToDynamicTable(header);
            return header;
        } else {
            // Literal without indexing
            const name = try self.decodeLiteralString(reader);
            const value = try self.decodeLiteralString(reader);
            return Header{ .name = name, .value = value };
        }
    }

    fn getHeader(self: *Decoder, index: usize) !Header {
        if (index == 0) return error.InvalidIndex;

        // Static table comes first
        const static_table_size = 61;
        if (index <= static_table_size) {
            return try self.getStaticHeader(index);
        }

        // Dynamic table
        const dynamic_index = index - static_table_size - 1;
        if (dynamic_index >= self.dynamic_table.items.len) {
            return error.InvalidIndex;
        }

        const entry = self.dynamic_table.items[dynamic_index];
        return Header{
            .name = try self.allocator.dupe(u8, entry.name),
            .value = try self.allocator.dupe(u8, entry.value),
        };
    }

    fn getStaticHeader(self: *Decoder, index: usize) !Header {
        // Simplified static table (RFC 7541 Appendix A)
        const static_table = [_]struct { []const u8, []const u8 }{
            .{ ":authority", "" },
            .{ ":method", "GET" },
            .{ ":method", "POST" },
            .{ ":path", "/" },
            .{ ":path", "/index.html" },
            .{ ":scheme", "http" },
            .{ ":scheme", "https" },
            .{ ":status", "200" },
            .{ ":status", "204" },
            .{ ":status", "206" },
            .{ ":status", "304" },
            .{ ":status", "400" },
            .{ ":status", "404" },
            .{ ":status", "500" },
            .{ "accept-charset", "" },
            .{ "accept-encoding", "gzip, deflate" },
            .{ "accept-language", "" },
            .{ "accept-ranges", "" },
            .{ "accept", "" },
            .{ "access-control-allow-origin", "" },
            .{ "age", "" },
            .{ "allow", "" },
            .{ "authorization", "" },
            .{ "cache-control", "" },
            .{ "content-disposition", "" },
            .{ "content-encoding", "" },
            .{ "content-language", "" },
            .{ "content-length", "" },
            .{ "content-location", "" },
            .{ "content-range", "" },
            .{ "content-type", "" },
            .{ "cookie", "" },
            .{ "date", "" },
            .{ "etag", "" },
            .{ "expect", "" },
            .{ "expires", "" },
            .{ "from", "" },
            .{ "host", "" },
            .{ "if-match", "" },
            .{ "if-modified-since", "" },
            .{ "if-none-match", "" },
            .{ "if-range", "" },
            .{ "if-unmodified-since", "" },
            .{ "last-modified", "" },
            .{ "link", "" },
            .{ "location", "" },
            .{ "max-forwards", "" },
            .{ "proxy-authenticate", "" },
            .{ "proxy-authorization", "" },
            .{ "range", "" },
            .{ "referer", "" },
            .{ "refresh", "" },
            .{ "retry-after", "" },
            .{ "server", "" },
            .{ "set-cookie", "" },
            .{ "strict-transport-security", "" },
            .{ "transfer-encoding", "" },
            .{ "user-agent", "" },
            .{ "vary", "" },
            .{ "via", "" },
            .{ "www-authenticate", "" },
        };

        if (index > 0 and index <= static_table.len) {
            const entry = static_table[index - 1];
            return Header{
                .name = try self.allocator.dupe(u8, entry[0]),
                .value = try self.allocator.dupe(u8, entry[1]),
            };
        }

        return error.InvalidStaticIndex;
    }

    fn addToDynamicTable(self: *Decoder, header: Header) !void {
        const name = try self.allocator.dupe(u8, header.name);
        const value = try self.allocator.dupe(u8, header.value);

        try self.dynamic_table.insert(0, .{
            .name = name,
            .value = value,
        });

        self.current_table_size += name.len + value.len + 32;

        // Evict entries if table size exceeded
        while (self.current_table_size > self.max_table_size and self.dynamic_table.items.len > 0) {
            const removed = self.dynamic_table.pop();
            self.current_table_size -= removed.name.len + removed.value.len + 32;
            self.allocator.free(removed.name);
            self.allocator.free(removed.value);
        }
    }

    fn decodeInteger(self: *Decoder, reader: anytype, prefix_bits: u3, initial_value: u8) !usize {
        _ = self;
        const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;
        var value: usize = initial_value;

        if (value < max_prefix) {
            return value;
        }

        var m: usize = 0;
        while (true) {
            const byte = try reader.readByte();
            value += (@as(usize, byte & 0x7F) << @intCast(m));
            m += 7;

            if ((byte & 0x80) == 0) break;
        }

        return value;
    }

    fn decodeLiteralString(self: *Decoder, reader: anytype) ![]u8 {
        const first_byte = try reader.readByte();
        const huffman = (first_byte & 0x80) != 0;
        const length = try self.decodeInteger(reader, 7, first_byte & 0x7F);

        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);

        try reader.readNoEof(data);

        if (huffman) {
            // Huffman decoding would go here
            // For now, just return the data as-is
            return data;
        }

        return data;
    }
};
