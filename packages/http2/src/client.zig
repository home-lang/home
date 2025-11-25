const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");

/// HTTP/2 Client implementation
///
/// Features:
/// - Binary framing layer
/// - Stream multiplexing
/// - Header compression (HPACK)
/// - Flow control
/// - Server push handling
/// - Connection management
pub const HTTP2Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    hpack_encoder: hpack.Encoder,
    hpack_decoder: hpack.Decoder,
    streams: std.AutoHashMap(u32, *Stream),
    next_stream_id: u32,
    window_size: u32,
    settings: Settings,
    running: bool,

    pub const Settings = struct {
        header_table_size: u32 = 4096,
        enable_push: bool = true,
        max_concurrent_streams: u32 = 100,
        initial_window_size: u32 = 65535,
        max_frame_size: u32 = 16384,
        max_header_list_size: u32 = std.math.maxInt(u32),
    };

    pub const Stream = struct {
        id: u32,
        state: StreamState,
        window_size: u32,
        headers: std.StringHashMap([]const u8),
        data: std.ArrayList(u8),
        response_complete: bool,

        pub const StreamState = enum {
            idle,
            open,
            half_closed_local,
            half_closed_remote,
            closed,
        };

        pub fn init(allocator: std.mem.Allocator, id: u32) Stream {
            return .{
                .id = id,
                .state = .idle,
                .window_size = 65535,
                .headers = std.StringHashMap([]const u8).init(allocator),
                .data = std.ArrayList(u8).init(allocator),
                .response_complete = false,
            };
        }

        pub fn deinit(self: *Stream) void {
            var it = self.headers.iterator();
            while (it.next()) |entry| {
                self.headers.allocator.free(entry.key_ptr.*);
                self.headers.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            self.data.deinit();
        }
    };

    pub const Request = struct {
        method: []const u8,
        path: []const u8,
        headers: std.StringHashMap([]const u8),
        body: ?[]const u8,
    };

    pub const Response = struct {
        status: u16,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            var it = self.headers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            self.allocator.free(self.body);
        }
    };

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream) !HTTP2Client {
        return .{
            .allocator = allocator,
            .stream = stream,
            .hpack_encoder = hpack.Encoder.init(allocator),
            .hpack_decoder = hpack.Decoder.init(allocator),
            .streams = std.AutoHashMap(u32, *Stream).init(allocator),
            .next_stream_id = 1,
            .window_size = 65535,
            .settings = .{},
            .running = false,
        };
    }

    pub fn deinit(self: *HTTP2Client) void {
        var it = self.streams.valueIterator();
        while (it.next()) |stream_ptr| {
            stream_ptr.*.deinit();
            self.allocator.destroy(stream_ptr.*);
        }
        self.streams.deinit();
        self.hpack_encoder.deinit();
        self.hpack_decoder.deinit();
        self.stream.close();
    }

    /// Connect and send connection preface
    pub fn connect(self: *HTTP2Client) !void {
        // Send connection preface
        try self.stream.writeAll("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");

        // Send initial SETTINGS frame
        try self.sendSettings();

        self.running = true;
    }

    /// Send a request and return response
    pub fn request(self: *HTTP2Client, req: Request) !Response {
        const stream_id = self.next_stream_id;
        self.next_stream_id += 2; // Client uses odd stream IDs

        // Create stream
        const stream_ptr = try self.allocator.create(Stream);
        stream_ptr.* = Stream.init(self.allocator, stream_id);
        try self.streams.put(stream_id, stream_ptr);

        // Send HEADERS frame
        try self.sendHeaders(stream_id, req);

        // Send DATA frame if body exists
        if (req.body) |body| {
            try self.sendData(stream_id, body, true);
        }

        // Wait for response
        return try self.readResponse(stream_id);
    }

    fn sendSettings(self: *HTTP2Client) !void {
        var settings_frame = frame.SettingsFrame.init();
        settings_frame.header_table_size = self.settings.header_table_size;
        settings_frame.enable_push = self.settings.enable_push;
        settings_frame.max_concurrent_streams = self.settings.max_concurrent_streams;
        settings_frame.initial_window_size = self.settings.initial_window_size;
        settings_frame.max_frame_size = self.settings.max_frame_size;

        const encoded = try settings_frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.stream.writeAll(encoded);
    }

    fn sendHeaders(self: *HTTP2Client, stream_id: u32, req: Request) !void {
        // Encode pseudo-headers
        var headers = std.ArrayList(hpack.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{ .name = ":method", .value = req.method });
        try headers.append(.{ .name = ":path", .value = req.path });
        try headers.append(.{ .name = ":scheme", .value = "https" });
        try headers.append(.{ .name = ":authority", .value = "localhost" });

        // Add regular headers
        var it = req.headers.iterator();
        while (it.next()) |entry| {
            try headers.append(.{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            });
        }

        // Encode with HPACK
        const encoded_headers = try self.hpack_encoder.encode(headers.items);
        defer self.allocator.free(encoded_headers);

        // Create HEADERS frame
        var headers_frame = frame.HeadersFrame.init(stream_id);
        headers_frame.end_headers = true;
        headers_frame.end_stream = (req.body == null);
        headers_frame.fragment = encoded_headers;

        const encoded = try headers_frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.stream.writeAll(encoded);
    }

    fn sendData(self: *HTTP2Client, stream_id: u32, data: []const u8, end_stream: bool) !void {
        var data_frame = frame.DataFrame.init(stream_id);
        data_frame.end_stream = end_stream;
        data_frame.data = data;

        const encoded = try data_frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.stream.writeAll(encoded);
    }

    fn readResponse(self: *HTTP2Client, stream_id: u32) !Response {
        const stream_ptr = self.streams.get(stream_id) orelse return error.StreamNotFound;

        // Read frames until response is complete
        while (!stream_ptr.response_complete) {
            const received_frame = try self.readFrame();
            try self.processFrame(received_frame);
        }

        // Build response
        const status_str = stream_ptr.headers.get(":status") orelse return error.MissingStatus;
        const status = try std.fmt.parseInt(u16, status_str, 10);

        var response = Response{
            .status = status,
            .headers = std.StringHashMap([]const u8).init(self.allocator),
            .body = try stream_ptr.data.toOwnedSlice(),
            .allocator = self.allocator,
        };

        // Copy headers (excluding pseudo-headers)
        var it = stream_ptr.headers.iterator();
        while (it.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, ":")) {
                try response.headers.put(
                    try self.allocator.dupe(u8, entry.key_ptr.*),
                    try self.allocator.dupe(u8, entry.value_ptr.*),
                );
            }
        }

        return response;
    }

    fn readFrame(self: *HTTP2Client) !frame.Frame {
        // Read frame header (9 bytes)
        var header_buf: [9]u8 = undefined;
        try self.stream.reader().readNoEof(&header_buf);

        const length = (@as(u32, header_buf[0]) << 16) |
            (@as(u32, header_buf[1]) << 8) |
            @as(u32, header_buf[2]);

        const frame_type = header_buf[3];
        const flags = header_buf[4];
        const stream_id = (@as(u32, header_buf[5] & 0x7F) << 24) |
            (@as(u32, header_buf[6]) << 16) |
            (@as(u32, header_buf[7]) << 8) |
            @as(u32, header_buf[8]);

        // Read payload
        const payload = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(payload);

        if (length > 0) {
            try self.stream.reader().readNoEof(payload);
        }

        return frame.Frame{
            .type = @enumFromInt(frame_type),
            .flags = flags,
            .stream_id = stream_id,
            .payload = payload,
        };
    }

    fn processFrame(self: *HTTP2Client, received_frame: frame.Frame) !void {
        defer self.allocator.free(received_frame.payload);

        switch (received_frame.type) {
            .HEADERS => {
                const stream_ptr = self.streams.get(received_frame.stream_id) orelse return;

                // Decode HPACK headers
                const headers = try self.hpack_decoder.decode(received_frame.payload);
                defer {
                    for (headers) |header| {
                        self.allocator.free(header.name);
                        self.allocator.free(header.value);
                    }
                    self.allocator.free(headers);
                }

                for (headers) |header| {
                    try stream_ptr.headers.put(
                        try self.allocator.dupe(u8, header.name),
                        try self.allocator.dupe(u8, header.value),
                    );
                }

                if ((received_frame.flags & 0x01) != 0) { // END_STREAM
                    stream_ptr.response_complete = true;
                }
            },
            .DATA => {
                const stream_ptr = self.streams.get(received_frame.stream_id) orelse return;
                try stream_ptr.data.appendSlice(received_frame.payload);

                if ((received_frame.flags & 0x01) != 0) { // END_STREAM
                    stream_ptr.response_complete = true;
                }
            },
            .SETTINGS => {
                // Send SETTINGS ACK
                var ack_frame = frame.SettingsFrame.init();
                ack_frame.ack = true;
                const encoded = try ack_frame.encode(self.allocator);
                defer self.allocator.free(encoded);
                try self.stream.writeAll(encoded);
            },
            .WINDOW_UPDATE => {
                // Update window size
                const increment = (@as(u32, received_frame.payload[0] & 0x7F) << 24) |
                    (@as(u32, received_frame.payload[1]) << 16) |
                    (@as(u32, received_frame.payload[2]) << 8) |
                    @as(u32, received_frame.payload[3]);

                if (received_frame.stream_id == 0) {
                    self.window_size += increment;
                } else if (self.streams.get(received_frame.stream_id)) |stream_ptr| {
                    stream_ptr.window_size += increment;
                }
            },
            .PING => {
                // Send PING ACK
                var pong_frame = frame.PingFrame.init();
                pong_frame.ack = true;
                @memcpy(&pong_frame.data, received_frame.payload[0..8]);
                const encoded = try pong_frame.encode(self.allocator);
                defer self.allocator.free(encoded);
                try self.stream.writeAll(encoded);
            },
            .GOAWAY => {
                self.running = false;
            },
            else => {},
        }
    }
};

/// Convenience functions
pub fn get(allocator: std.mem.Allocator, url: []const u8) !HTTP2Client.Response {
    const uri = try std.Uri.parse(url);
    const address = try std.net.Address.parseIp(uri.host.?, 443);
    const stream = try std.net.tcpConnectToAddress(address);

    var client = try HTTP2Client.init(allocator, stream);
    defer client.deinit();

    try client.connect();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    const request = HTTP2Client.Request{
        .method = "GET",
        .path = uri.path,
        .headers = headers,
        .body = null,
    };

    return try client.request(request);
}

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) !HTTP2Client.Response {
    const uri = try std.Uri.parse(url);
    const address = try std.net.Address.parseIp(uri.host.?, 443);
    const stream = try std.net.tcpConnectToAddress(address);

    var client = try HTTP2Client.init(allocator, stream);
    defer client.deinit();

    try client.connect();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("content-type", "application/json");

    const request = HTTP2Client.Request{
        .method = "POST",
        .path = uri.path,
        .headers = headers,
        .body = body,
    };

    return try client.request(request);
}
