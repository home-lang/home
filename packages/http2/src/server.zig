const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");

/// HTTP/2 Server implementation
///
/// Features:
/// - Binary framing layer
/// - Stream multiplexing
/// - Header compression (HPACK)
/// - Flow control
/// - Server push support
/// - Connection management
/// - Request routing
pub const HTTP2Server = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    listener: ?std.net.Server,
    settings: Settings,
    handler: RequestHandler,
    running: bool,

    pub const Settings = struct {
        header_table_size: u32 = 4096,
        enable_push: bool = true,
        max_concurrent_streams: u32 = 100,
        initial_window_size: u32 = 65535,
        max_frame_size: u32 = 16384,
        max_header_list_size: u32 = std.math.maxInt(u32),
    };

    pub const Request = struct {
        method: []const u8,
        path: []const u8,
        scheme: []const u8,
        authority: []const u8,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
        stream_id: u32,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Request) void {
            self.allocator.free(self.method);
            self.allocator.free(self.path);
            self.allocator.free(self.scheme);
            self.allocator.free(self.authority);
            var it = self.headers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            self.allocator.free(self.body);
        }
    };

    pub const Response = struct {
        status: u16,
        headers: std.StringHashMap([]const u8),
        body: []const u8,

        pub fn init(allocator: std.mem.Allocator, status: u16) Response {
            return .{
                .status = status,
                .headers = std.StringHashMap([]const u8).init(allocator),
                .body = &.{},
            };
        }

        pub fn setBody(self: *Response, body: []const u8) void {
            self.body = body;
        }

        pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
            try self.headers.put(name, value);
        }
    };

    /// Request handler callback
    pub const RequestHandler = *const fn (req: *Request) anyerror!Response;

    /// Server connection state
    const Connection = struct {
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        hpack_encoder: hpack.Encoder,
        hpack_decoder: hpack.Decoder,
        streams: std.AutoHashMap(u32, *Stream),
        next_stream_id: u32,
        window_size: u32,
        settings: Settings,
        handler: RequestHandler,

        const Stream = struct {
            id: u32,
            state: StreamState,
            window_size: u32,
            headers: std.StringHashMap([]const u8),
            data: std.ArrayList(u8),
            headers_complete: bool,
            request_complete: bool,

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
                    .headers_complete = false,
                    .request_complete = false,
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

        pub fn init(
            allocator: std.mem.Allocator,
            stream: std.net.Stream,
            settings: Settings,
            handler: RequestHandler,
        ) !Connection {
            return .{
                .allocator = allocator,
                .stream = stream,
                .hpack_encoder = hpack.Encoder.init(allocator),
                .hpack_decoder = hpack.Decoder.init(allocator),
                .streams = std.AutoHashMap(u32, *Stream).init(allocator),
                .next_stream_id = 2, // Server uses even stream IDs
                .window_size = 65535,
                .settings = settings,
                .handler = handler,
            };
        }

        pub fn deinit(self: *Connection) void {
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

        /// Handle client connection
        pub fn handle(self: *Connection) !void {
            // Read connection preface
            var preface_buf: [24]u8 = undefined;
            try self.stream.reader().readNoEof(&preface_buf);

            const expected_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
            if (!std.mem.eql(u8, &preface_buf, expected_preface)) {
                return error.InvalidPreface;
            }

            // Send SETTINGS frame
            try self.sendSettings();

            // Process frames
            while (true) {
                const received_frame = self.readFrame() catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };

                self.processFrame(received_frame) catch |err| {
                    self.allocator.free(received_frame.payload);
                    return err;
                };
            }
        }

        fn sendSettings(self: *Connection) !void {
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

        fn readFrame(self: *Connection) !frame.Frame {
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

        fn processFrame(self: *Connection, received_frame: frame.Frame) !void {
            defer self.allocator.free(received_frame.payload);

            switch (received_frame.type) {
                .HEADERS => try self.handleHeadersFrame(received_frame),
                .DATA => try self.handleDataFrame(received_frame),
                .SETTINGS => try self.handleSettingsFrame(received_frame),
                .WINDOW_UPDATE => try self.handleWindowUpdateFrame(received_frame),
                .PING => try self.handlePingFrame(received_frame),
                .RST_STREAM => try self.handleRstStreamFrame(received_frame),
                .GOAWAY => return,
                else => {},
            }
        }

        fn handleHeadersFrame(self: *Connection, received_frame: frame.Frame) !void {
            const stream_id = received_frame.stream_id;

            // Get or create stream
            const stream_ptr = try self.getOrCreateStream(stream_id);

            // Decode HPACK headers
            const headers = try self.hpack_decoder.decode(received_frame.payload);
            defer {
                for (headers) |header| {
                    self.allocator.free(header.name);
                    self.allocator.free(header.value);
                }
                self.allocator.free(headers);
            }

            // Store headers
            for (headers) |header| {
                try stream_ptr.headers.put(
                    try self.allocator.dupe(u8, header.name),
                    try self.allocator.dupe(u8, header.value),
                );
            }

            // Check if headers are complete
            if ((received_frame.flags & 0x04) != 0) { // END_HEADERS
                stream_ptr.headers_complete = true;
            }

            // Check if request is complete
            if ((received_frame.flags & 0x01) != 0) { // END_STREAM
                stream_ptr.request_complete = true;
                try self.handleRequest(stream_id);
            }

            stream_ptr.state = .open;
        }

        fn handleDataFrame(self: *Connection, received_frame: frame.Frame) !void {
            const stream_id = received_frame.stream_id;
            const stream_ptr = self.streams.get(stream_id) orelse return;

            // Append data
            try stream_ptr.data.appendSlice(received_frame.payload);

            // Check if request is complete
            if ((received_frame.flags & 0x01) != 0) { // END_STREAM
                stream_ptr.request_complete = true;
                try self.handleRequest(stream_id);
            }

            // Send WINDOW_UPDATE to allow more data
            try self.sendWindowUpdate(stream_id, @intCast(received_frame.payload.len));
        }

        fn handleSettingsFrame(self: *Connection, received_frame: frame.Frame) !void {
            if ((received_frame.flags & 0x01) != 0) { // ACK
                return;
            }

            // Parse settings
            var i: usize = 0;
            while (i + 6 <= received_frame.payload.len) : (i += 6) {
                const id = (@as(u16, received_frame.payload[i]) << 8) |
                    @as(u16, received_frame.payload[i + 1]);
                const value = (@as(u32, received_frame.payload[i + 2]) << 24) |
                    (@as(u32, received_frame.payload[i + 3]) << 16) |
                    (@as(u32, received_frame.payload[i + 4]) << 8) |
                    @as(u32, received_frame.payload[i + 5]);

                switch (id) {
                    0x01 => self.settings.header_table_size = value,
                    0x02 => self.settings.enable_push = (value != 0),
                    0x03 => self.settings.max_concurrent_streams = value,
                    0x04 => self.settings.initial_window_size = value,
                    0x05 => self.settings.max_frame_size = value,
                    0x06 => self.settings.max_header_list_size = value,
                    else => {},
                }
            }

            // Send SETTINGS ACK
            var ack_frame = frame.SettingsFrame.init();
            ack_frame.ack = true;
            const encoded = try ack_frame.encode(self.allocator);
            defer self.allocator.free(encoded);
            try self.stream.writeAll(encoded);
        }

        fn handleWindowUpdateFrame(self: *Connection, received_frame: frame.Frame) !void {
            const increment = (@as(u32, received_frame.payload[0] & 0x7F) << 24) |
                (@as(u32, received_frame.payload[1]) << 16) |
                (@as(u32, received_frame.payload[2]) << 8) |
                @as(u32, received_frame.payload[3]);

            if (received_frame.stream_id == 0) {
                self.window_size += increment;
            } else if (self.streams.get(received_frame.stream_id)) |stream_ptr| {
                stream_ptr.window_size += increment;
            }
        }

        fn handlePingFrame(self: *Connection, received_frame: frame.Frame) !void {
            // Send PING ACK
            var pong_frame = frame.PingFrame.init();
            pong_frame.ack = true;
            @memcpy(&pong_frame.data, received_frame.payload[0..8]);
            const encoded = try pong_frame.encode(self.allocator);
            defer self.allocator.free(encoded);
            try self.stream.writeAll(encoded);
        }

        fn handleRstStreamFrame(self: *Connection, received_frame: frame.Frame) !void {
            const stream_id = received_frame.stream_id;
            if (self.streams.get(stream_id)) |stream_ptr| {
                stream_ptr.state = .closed;
            }
        }

        fn handleRequest(self: *Connection, stream_id: u32) !void {
            const stream_ptr = self.streams.get(stream_id) orelse return;

            if (!stream_ptr.headers_complete or !stream_ptr.request_complete) {
                return;
            }

            // Build request
            var request = Request{
                .method = try self.allocator.dupe(u8, stream_ptr.headers.get(":method") orelse "GET"),
                .path = try self.allocator.dupe(u8, stream_ptr.headers.get(":path") orelse "/"),
                .scheme = try self.allocator.dupe(u8, stream_ptr.headers.get(":scheme") orelse "https"),
                .authority = try self.allocator.dupe(u8, stream_ptr.headers.get(":authority") orelse ""),
                .headers = std.StringHashMap([]const u8).init(self.allocator),
                .body = try stream_ptr.data.toOwnedSlice(),
                .stream_id = stream_id,
                .allocator = self.allocator,
            };
            defer request.deinit();

            // Copy non-pseudo headers
            var it = stream_ptr.headers.iterator();
            while (it.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.key_ptr.*, ":")) {
                    try request.headers.put(
                        try self.allocator.dupe(u8, entry.key_ptr.*),
                        try self.allocator.dupe(u8, entry.value_ptr.*),
                    );
                }
            }

            // Call handler
            const response = try self.handler(&request);

            // Send response
            try self.sendResponse(stream_id, response);

            // Clean up stream
            stream_ptr.state = .closed;
        }

        fn sendResponse(self: *Connection, stream_id: u32, response: Response) !void {
            // Encode headers
            var headers = std.ArrayList(hpack.Header).init(self.allocator);
            defer headers.deinit();

            // Status pseudo-header
            var status_buf: [3]u8 = undefined;
            const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{response.status});
            try headers.append(.{ .name = ":status", .value = status_str });

            // Regular headers
            var it = response.headers.iterator();
            while (it.next()) |entry| {
                try headers.append(.{
                    .name = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }

            // Add content-length if body exists
            if (response.body.len > 0) {
                var len_buf: [32]u8 = undefined;
                const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{response.body.len});
                try headers.append(.{ .name = "content-length", .value = len_str });
            }

            // Encode with HPACK
            const encoded_headers = try self.hpack_encoder.encode(headers.items);
            defer self.allocator.free(encoded_headers);

            // Send HEADERS frame
            var headers_frame = frame.HeadersFrame.init(stream_id);
            headers_frame.end_headers = true;
            headers_frame.end_stream = (response.body.len == 0);
            headers_frame.fragment = encoded_headers;

            const encoded = try headers_frame.encode(self.allocator);
            defer self.allocator.free(encoded);
            try self.stream.writeAll(encoded);

            // Send DATA frame if body exists
            if (response.body.len > 0) {
                try self.sendData(stream_id, response.body, true);
            }
        }

        fn sendData(self: *Connection, stream_id: u32, data: []const u8, end_stream: bool) !void {
            var data_frame = frame.DataFrame.init(stream_id);
            data_frame.end_stream = end_stream;
            data_frame.data = data;

            const encoded = try data_frame.encode(self.allocator);
            defer self.allocator.free(encoded);

            try self.stream.writeAll(encoded);
        }

        fn sendWindowUpdate(self: *Connection, stream_id: u32, increment: u32) !void {
            var buffer: [13]u8 = undefined;

            // Frame header
            buffer[0] = 0; // Length (3 bytes)
            buffer[1] = 0;
            buffer[2] = 4;
            buffer[3] = @intFromEnum(frame.FrameType.WINDOW_UPDATE);
            buffer[4] = 0; // Flags
            buffer[5] = @intCast((stream_id >> 24) & 0xFF);
            buffer[6] = @intCast((stream_id >> 16) & 0xFF);
            buffer[7] = @intCast((stream_id >> 8) & 0xFF);
            buffer[8] = @intCast(stream_id & 0xFF);

            // Payload
            buffer[9] = @intCast((increment >> 24) & 0x7F);
            buffer[10] = @intCast((increment >> 16) & 0xFF);
            buffer[11] = @intCast((increment >> 8) & 0xFF);
            buffer[12] = @intCast(increment & 0xFF);

            try self.stream.writeAll(&buffer);
        }

        fn getOrCreateStream(self: *Connection, stream_id: u32) !*Stream {
            if (self.streams.get(stream_id)) |stream_ptr| {
                return stream_ptr;
            }

            const stream_ptr = try self.allocator.create(Stream);
            stream_ptr.* = Stream.init(self.allocator, stream_id);
            try self.streams.put(stream_id, stream_ptr);
            return stream_ptr;
        }

        /// Server push - send a push promise
        pub fn pushPromise(
            self: *Connection,
            stream_id: u32,
            promised_method: []const u8,
            promised_path: []const u8,
        ) !u32 {
            const promised_stream_id = self.next_stream_id;
            self.next_stream_id += 2;

            // Encode push promise headers
            var headers = std.ArrayList(hpack.Header).init(self.allocator);
            defer headers.deinit();

            try headers.append(.{ .name = ":method", .value = promised_method });
            try headers.append(.{ .name = ":path", .value = promised_path });
            try headers.append(.{ .name = ":scheme", .value = "https" });
            try headers.append(.{ .name = ":authority", .value = "localhost" });

            const encoded_headers = try self.hpack_encoder.encode(headers.items);
            defer self.allocator.free(encoded_headers);

            // Build PUSH_PROMISE frame
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();

            // Promised stream ID (4 bytes)
            try buffer.writer().writeInt(u32, promised_stream_id, .big);

            // Header block fragment
            try buffer.appendSlice(encoded_headers);

            const payload = try buffer.toOwnedSlice();
            defer self.allocator.free(payload);

            // Frame header
            var frame_buf = std.ArrayList(u8).init(self.allocator);
            defer frame_buf.deinit();

            try frame_buf.writer().writeInt(u24, @intCast(payload.len), .big);
            try frame_buf.append(@intFromEnum(frame.FrameType.PUSH_PROMISE));
            try frame_buf.append(0x04); // END_HEADERS flag
            try frame_buf.writer().writeInt(u32, stream_id, .big);
            try frame_buf.appendSlice(payload);

            const encoded = try frame_buf.toOwnedSlice();
            defer self.allocator.free(encoded);

            try self.stream.writeAll(encoded);

            return promised_stream_id;
        }

        /// Send pushed response
        pub fn sendPushedResponse(self: *Connection, stream_id: u32, response: Response) !void {
            try self.sendResponse(stream_id, response);
        }
    };

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address, handler: RequestHandler) HTTP2Server {
        return .{
            .allocator = allocator,
            .address = address,
            .listener = null,
            .settings = .{},
            .handler = handler,
            .running = false,
        };
    }

    pub fn deinit(self: *HTTP2Server) void {
        if (self.listener) |*listener| {
            listener.deinit();
        }
    }

    /// Start the server
    pub fn listen(self: *HTTP2Server) !void {
        self.listener = try self.address.listen(.{
            .reuse_address = true,
        });

        self.running = true;

        std.debug.print("HTTP/2 server listening on {}\n", .{self.address});

        while (self.running) {
            const client_connection = try self.listener.?.accept();

            // Handle connection in a separate thread (for production, use thread pool)
            const thread = try std.Thread.spawn(.{}, handleConnection, .{
                self.allocator,
                client_connection.stream,
                self.settings,
                self.handler,
            });
            thread.detach();
        }
    }

    fn handleConnection(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        settings: Settings,
        handler: RequestHandler,
    ) void {
        var conn = Connection.init(allocator, stream, settings, handler) catch |err| {
            std.debug.print("Failed to initialize connection: {}\n", .{err});
            return;
        };
        defer conn.deinit();

        conn.handle() catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }

    /// Stop the server
    pub fn stop(self: *HTTP2Server) void {
        self.running = false;
    }
};

/// Simple routing helper
pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.StringHashMap(RouteHandler),

    pub const RouteHandler = *const fn (req: *HTTP2Server.Request) anyerror!HTTP2Server.Response;

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = std.StringHashMap(RouteHandler).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit();
    }

    pub fn addRoute(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.routes.put(path, handler);
    }

    pub fn handle(self: *Router, req: *HTTP2Server.Request) !HTTP2Server.Response {
        if (self.routes.get(req.path)) |handler| {
            return try handler(req);
        }

        // 404 Not Found
        var response = HTTP2Server.Response.init(self.allocator, 404);
        response.body = "Not Found";
        return response;
    }
};
