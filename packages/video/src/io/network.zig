// Home Video Library - Network I/O
// HTTP/HTTPS sources and network streaming

const std = @import("std");
const source = @import("source.zig");
const err = @import("../core/error.zig");

pub const Source = source.Source;
pub const VideoError = err.VideoError;

// ============================================================================
// HTTP Source
// ============================================================================

pub const HTTPSource = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    client: std.http.Client,
    response: ?std.http.Client.Response = null,
    position: u64 = 0,
    total_size: ?u64 = null,
    supports_range: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !Self {
        var client = std.http.Client{ .allocator = allocator };

        return .{
            .allocator = allocator,
            .url = try allocator.dupe(u8, url),
            .client = client,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.response) |*resp| {
            resp.deinit();
        }
        self.client.deinit();
        self.allocator.free(self.url);
    }

    pub fn open(self: *Self) !void {
        // Make HEAD request first to check capabilities
        try self.checkCapabilities();
    }

    fn checkCapabilities(self: *Self) !void {
        // Parse URL
        const uri = try std.Uri.parse(self.url);

        // Create HEAD request
        var header_buffer: [8192]u8 = undefined;
        var req = try self.client.open(.HEAD, uri, .{
            .server_header_buffer = &header_buffer,
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        // Check Content-Length
        if (req.response.headers.getFirstValue("Content-Length")) |content_length| {
            self.total_size = try std.fmt.parseInt(u64, content_length, 10);
        }

        // Check Accept-Ranges
        if (req.response.headers.getFirstValue("Accept-Ranges")) |accept_ranges| {
            self.supports_range = std.mem.eql(u8, accept_ranges, "bytes");
        }
    }

    pub fn source_interface(self: *Self) Source {
        return Source{
            .ctx = self,
            .read_fn = readImpl,
            .seek_fn = if (self.supports_range) seekImpl else null,
            .tell_fn = tellImpl,
            .size_fn = sizeImpl,
        };
    }

    fn readImpl(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Start new request if we don't have an active response
        if (self.response == null) {
            const uri = try std.Uri.parse(self.url);

            var header_buffer: [8192]u8 = undefined;
            var req = try self.client.open(.GET, uri, .{
                .server_header_buffer = &header_buffer,
                .extra_headers = if (self.position > 0) &[_]std.http.Header{
                    .{ .name = "Range", .value = try std.fmt.allocPrint(
                        self.allocator,
                        "bytes={d}-",
                        .{self.position},
                    ) },
                } else &[_]std.http.Header{},
            });

            try req.send();
            try req.finish();
            try req.wait();

            self.response = req;
        }

        if (self.response) |*resp| {
            const bytes_read = try resp.read(buffer);
            self.position += bytes_read;
            return bytes_read;
        }

        return 0;
    }

    fn seekImpl(ctx: *anyopaque, offset: i64, whence: source.SeekWhence) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (!self.supports_range) return VideoError.NotSeekable;

        // Calculate new position
        const new_pos: i64 = switch (whence) {
            .start => offset,
            .current => @as(i64, @intCast(self.position)) + offset,
            .end => blk: {
                const size = self.total_size orelse return VideoError.NotSeekable;
                break :blk @as(i64, @intCast(size)) + offset;
            },
        };

        if (new_pos < 0) return VideoError.SeekOutOfRange;

        self.position = @intCast(new_pos);

        // Close current response and create new one with Range header
        if (self.response) |*resp| {
            resp.deinit();
            self.response = null;
        }

        return self.position;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.position;
    }

    fn sizeImpl(ctx: *anyopaque) ?u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.total_size;
    }
};

// ============================================================================
// RTSP Source (placeholder for Real Time Streaming Protocol)
// ============================================================================

pub const RTSPSource = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    session_id: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !Self {
        return .{
            .allocator = allocator,
            .url = try allocator.dupe(u8, url),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.session_id) |id| {
            self.allocator.free(id);
        }
        self.allocator.free(self.url);
    }

    pub fn connect(self: *Self) !void {
        // Parse RTSP URL (rtsp://server:port/path)
        const uri = try std.Uri.parse(self.url);

        // For full RTSP implementation, would need:
        // 1. TCP connection to server
        // 2. Send DESCRIBE request
        // 3. Parse SDP response
        // 4. Send SETUP for each track
        // 5. Send PLAY to start streaming
        // 6. Receive RTP packets

        // Minimal implementation for demonstration
        const host = uri.host orelse return error.InvalidUrl;
        const port = uri.port orelse 554; // Default RTSP port

        // Open TCP connection
        const stream = try std.net.tcpConnectToHost(self.allocator, host.percent_encoded, port);
        defer stream.close();

        // Send OPTIONS request (first RTSP handshake)
        const options_req = try std.fmt.allocPrint(
            self.allocator,
            "OPTIONS {s} RTSP/1.0\r\nCSeq: 1\r\n\r\n",
            .{self.url}
        );
        defer self.allocator.free(options_req);

        _ = try stream.write(options_req);

        // Read response
        var response_buf: [4096]u8 = undefined;
        const bytes_read = try stream.read(&response_buf);

        // Parse session ID from response if present
        const response = response_buf[0..bytes_read];
        if (std.mem.indexOf(u8, response, "Session: ")) |session_start| {
            const session_line = response[session_start + 9..];
            if (std.mem.indexOfScalar(u8, session_line, '\r')) |end| {
                self.session_id = try self.allocator.dupe(u8, session_line[0..end]);
            }
        }
    }

    pub fn source_interface(self: *Self) Source {
        return Source{
            .ctx = self,
            .read_fn = readImpl,
            .seek_fn = null, // RTSP typically non-seekable for live streams
            .tell_fn = tellImpl,
            .size_fn = sizeImpl,
        };
    }

    fn readImpl(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // RTP packet reading would require:
        // 1. UDP socket for RTP data (typically even ports)
        // 2. Parse RTP header (12 bytes minimum)
        // 3. Extract payload based on payload type
        // 4. Handle sequence numbers for ordering

        // For live RTSP streams, the data comes via interleaved
        // TCP channels or separate UDP ports after SETUP

        // Since we don't have an active session, return 0
        if (self.session_id == null) {
            return 0;
        }

        // RTP header structure (RFC 3550):
        // - Byte 0: V(2) P(1) X(1) CC(4)
        // - Byte 1: M(1) PT(7)
        // - Bytes 2-3: Sequence number
        // - Bytes 4-7: Timestamp
        // - Bytes 8-11: SSRC
        const RTP_HEADER_SIZE = 12;

        // Need at least header size in buffer
        if (buffer.len < RTP_HEADER_SIZE) {
            return 0;
        }

        // In a full implementation:
        // - Receive UDP packet
        // - Validate RTP version (should be 2)
        // - Handle padding and extensions
        // - Track sequence numbers for packet loss
        // - Reassemble NAL units for H.264

        return 0; // No data available without active stream
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        _ = ctx;
        return 0;
    }

    fn sizeImpl(ctx: *anyopaque) ?u64 {
        _ = ctx;
        return null; // Live stream has no fixed size
    }
};

// ============================================================================
// Network Utilities
// ============================================================================

pub const NetworkUtils = struct {
    /// Parse URL to extract scheme, host, port, path
    pub fn parseURL(url: []const u8) !URLComponents {
        var result: URLComponents = undefined;

        // Find scheme
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse {
            return error.InvalidURL;
        };

        result.scheme = url[0..scheme_end];

        // Find host start
        var pos = scheme_end + 3;
        const path_start = std.mem.indexOfScalarPos(u8, url, pos, '/') orelse url.len;

        const host_part = url[pos..path_start];

        // Check for port
        if (std.mem.lastIndexOfScalar(u8, host_part, ':')) |port_sep| {
            result.host = host_part[0..port_sep];
            const port_str = host_part[port_sep + 1 ..];
            result.port = try std.fmt.parseInt(u16, port_str, 10);
        } else {
            result.host = host_part;
            result.port = getDefaultPort(result.scheme);
        }

        result.path = if (path_start < url.len) url[path_start..] else "/";

        return result;
    }

    fn getDefaultPort(scheme: []const u8) u16 {
        if (std.mem.eql(u8, scheme, "http")) return 80;
        if (std.mem.eql(u8, scheme, "https")) return 443;
        if (std.mem.eql(u8, scheme, "rtsp")) return 554;
        if (std.mem.eql(u8, scheme, "rtmp")) return 1935;
        return 0;
    }

    pub const URLComponents = struct {
        scheme: []const u8,
        host: []const u8,
        port: u16,
        path: []const u8,
    };

    /// Check if URL is a network resource
    pub fn isNetworkURL(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://") or
            std.mem.startsWith(u8, url, "rtsp://") or
            std.mem.startsWith(u8, url, "rtmp://") or
            std.mem.startsWith(u8, url, "rtp://");
    }

    /// Format byte range header
    pub fn formatRangeHeader(
        allocator: std.mem.Allocator,
        start: u64,
        end: ?u64,
    ) ![]u8 {
        if (end) |e| {
            return try std.fmt.allocPrint(allocator, "bytes={d}-{d}", .{ start, e });
        } else {
            return try std.fmt.allocPrint(allocator, "bytes={d}-", .{start});
        }
    }
};

// ============================================================================
// Download Progress Callback
// ============================================================================

pub const ProgressCallback = *const fn (
    bytes_downloaded: u64,
    total_bytes: ?u64,
    speed_bps: u64,
) void;

pub const DownloadTracker = struct {
    start_time: i64,
    bytes_downloaded: u64 = 0,
    last_report_time: i64,
    last_bytes: u64 = 0,
    callback: ?ProgressCallback = null,

    const Self = @This();

    pub fn init(callback: ?ProgressCallback) Self {
        const now = std.time.timestamp();
        return .{
            .start_time = now,
            .last_report_time = now,
            .callback = callback,
        };
    }

    pub fn update(self: *Self, bytes: u64, total: ?u64) void {
        self.bytes_downloaded += bytes;

        const now = std.time.timestamp();
        const elapsed = now - self.last_report_time;

        // Report every second
        if (elapsed >= 1) {
            const speed = self.bytes_downloaded - self.last_bytes;

            if (self.callback) |cb| {
                cb(self.bytes_downloaded, total, speed);
            }

            self.last_report_time = now;
            self.last_bytes = self.bytes_downloaded;
        }
    }

    pub fn getSpeed(self: *const Self) u64 {
        const elapsed = std.time.timestamp() - self.start_time;
        if (elapsed == 0) return 0;
        return self.bytes_downloaded / @as(u64, @intCast(elapsed));
    }

    pub fn getProgress(self: *const Self, total: ?u64) ?f32 {
        if (total) |t| {
            if (t == 0) return null;
            return @as(f32, @floatFromInt(self.bytes_downloaded)) /
                @as(f32, @floatFromInt(t));
        }
        return null;
    }
};
