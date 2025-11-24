// Home Audio Library - HTTP Streaming (Shoutcast/Icecast)
// Live audio streaming client with metadata support

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Stream metadata
pub const StreamMetadata = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    bitrate: ?u32 = null,
    sample_rate: ?u32 = null,

    pub fn deinit(self: *StreamMetadata, allocator: Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.artist) |a| allocator.free(a);
        if (self.album) |a| allocator.free(a);
        if (self.genre) |g| allocator.free(g);
    }
};

/// Stream state
pub const StreamState = enum {
    disconnected,
    connecting,
    connected,
    buffering,
    playing,
    error_state,
};

/// Audio callback for decoded samples
pub const AudioCallback = *const fn (samples: []const f32, user_data: ?*anyopaque) void;

/// Metadata callback
pub const MetadataCallback = *const fn (metadata: *const StreamMetadata, user_data: ?*anyopaque) void;

/// Ring buffer for streaming audio
pub const RingBuffer = struct {
    buffer: []f32,
    read_pos: usize,
    write_pos: usize,
    capacity: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, capacity: usize) !Self {
        const buffer = try allocator.alloc(f32, capacity);
        @memset(buffer, 0);

        return Self{
            .buffer = buffer,
            .read_pos = 0,
            .write_pos = 0,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn write(self: *Self, data: []const f32) usize {
        var written: usize = 0;
        for (data) |sample| {
            const next_write = (self.write_pos + 1) % self.capacity;
            if (next_write == self.read_pos) {
                // Buffer full
                break;
            }
            self.buffer[self.write_pos] = sample;
            self.write_pos = next_write;
            written += 1;
        }
        return written;
    }

    pub fn read(self: *Self, data: []f32) usize {
        var read_count: usize = 0;
        for (data) |*sample| {
            if (self.read_pos == self.write_pos) {
                // Buffer empty
                break;
            }
            sample.* = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.capacity;
            read_count += 1;
        }
        return read_count;
    }

    pub fn available(self: *Self) usize {
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        } else {
            return self.capacity - self.read_pos + self.write_pos;
        }
    }

    pub fn space(self: *Self) usize {
        return self.capacity - self.available() - 1;
    }

    pub fn clear(self: *Self) void {
        self.read_pos = 0;
        self.write_pos = 0;
    }
};

/// HTTP streaming client
pub const StreamingClient = struct {
    allocator: Allocator,
    url: []const u8,

    // HTTP connection
    http_client: std.http.Client,
    connection: ?std.http.Client.Connection = null,

    // Stream properties
    content_type: ?[]const u8 = null,
    icy_metaint: ?usize = null, // Metadata interval for Shoutcast
    bitrate: ?u32 = null,

    // Buffers
    ring_buffer: RingBuffer,
    receive_buffer: []u8,

    // State
    state: StreamState,
    bytes_received: usize,
    next_metadata_at: usize,

    // Callbacks
    audio_callback: ?AudioCallback = null,
    audio_callback_data: ?*anyopaque = null,
    metadata_callback: ?MetadataCallback = null,
    metadata_callback_data: ?*anyopaque = null,

    // Metadata
    current_metadata: StreamMetadata,

    // Thread
    receive_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: Allocator, url: []const u8) !Self {
        const ring_buffer = try RingBuffer.init(allocator, 1024 * 1024); // 1M samples
        const receive_buffer = try allocator.alloc(u8, 64 * 1024); // 64KB chunks

        return Self{
            .allocator = allocator,
            .url = try allocator.dupe(u8, url),
            .http_client = std.http.Client{ .allocator = allocator },
            .ring_buffer = ring_buffer,
            .receive_buffer = receive_buffer,
            .state = .disconnected,
            .bytes_received = 0,
            .next_metadata_at = 0,
            .current_metadata = .{},
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.allocator.free(self.url);
        if (self.content_type) |ct| self.allocator.free(ct);
        self.ring_buffer.deinit(self.allocator);
        self.allocator.free(self.receive_buffer);
        self.current_metadata.deinit(self.allocator);
        self.http_client.deinit();
    }

    pub fn setAudioCallback(self: *Self, callback: AudioCallback, user_data: ?*anyopaque) void {
        self.audio_callback = callback;
        self.audio_callback_data = user_data;
    }

    pub fn setMetadataCallback(self: *Self, callback: MetadataCallback, user_data: ?*anyopaque) void {
        self.metadata_callback = callback;
        self.metadata_callback_data = user_data;
    }

    /// Connect to stream
    pub fn connect(self: *Self) !void {
        if (self.state != .disconnected) {
            return error.AlreadyConnected;
        }

        self.state = .connecting;

        // Parse URL
        const uri = try std.Uri.parse(self.url);

        // Create HTTP request with Icecast metadata header
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();

        try headers.append("Icy-MetaData", "1");
        try headers.append("User-Agent", "HomeAudioLibrary/1.0");

        // Make request
        var req = try self.http_client.open(.GET, uri, headers, .{});
        defer req.deinit();

        // Send request
        try req.send(.{});

        // Wait for response
        try req.wait();

        if (req.response.status != .ok) {
            self.state = .error_state;
            return error.HttpError;
        }

        // Parse Icecast headers
        if (req.response.headers.getFirstValue("icy-metaint")) |metaint_str| {
            self.icy_metaint = try std.fmt.parseInt(usize, metaint_str, 10);
            self.next_metadata_at = self.icy_metaint.?;
        }

        if (req.response.headers.getFirstValue("content-type")) |ct| {
            self.content_type = try self.allocator.dupe(u8, ct);
        }

        if (req.response.headers.getFirstValue("icy-br")) |br_str| {
            self.bitrate = try std.fmt.parseInt(u32, br_str, 10);
        }

        self.connection = req.connection;
        self.state = .connected;

        // Start receive thread
        self.should_stop.store(false, .seq_cst);
        self.receive_thread = try std.Thread.spawn(.{}, receiveThreadFn, .{self});
    }

    /// Disconnect from stream
    pub fn disconnect(self: *Self) void {
        if (self.state == .disconnected) return;

        // Stop receive thread
        self.should_stop.store(true, .seq_cst);
        if (self.receive_thread) |thread| {
            thread.join();
            self.receive_thread = null;
        }

        if (self.connection) |_| {
            // Connection cleanup handled by http_client
            self.connection = null;
        }

        self.ring_buffer.clear();
        self.state = .disconnected;
    }

    /// Receive thread function
    fn receiveThreadFn(self: *Self) void {
        self.receiveLoop() catch |err| {
            std.debug.print("Stream receive error: {}\n", .{err});
            self.state = .error_state;
        };
    }

    /// Main receive loop
    fn receiveLoop(self: *Self) !void {
        self.state = .buffering;

        while (!self.should_stop.load(.seq_cst)) {
            if (self.connection) |conn| {
                // Read chunk
                const bytes_read = try conn.reader().read(self.receive_buffer);
                if (bytes_read == 0) {
                    // Stream ended
                    break;
                }

                // Process data
                try self.processData(self.receive_buffer[0..bytes_read]);

                // Update state
                if (self.state == .buffering and self.ring_buffer.available() > 44100) {
                    self.state = .playing;
                }
            } else {
                break;
            }

            // Yield to avoid busy-waiting
            std.time.sleep(1_000_000); // 1ms
        }
    }

    /// Process received data
    fn processData(self: *Self, data: []const u8) !void {
        var pos: usize = 0;

        while (pos < data.len) {
            // Check for metadata
            if (self.icy_metaint) |metaint| {
                if (self.bytes_received >= self.next_metadata_at) {
                    // Read metadata length (1 byte * 16)
                    if (pos >= data.len) break;
                    const meta_len = @as(usize, data[pos]) * 16;
                    pos += 1;

                    // Read metadata
                    if (pos + meta_len <= data.len) {
                        const metadata_bytes = data[pos .. pos + meta_len];
                        try self.parseMetadata(metadata_bytes);
                        pos += meta_len;
                    }

                    self.next_metadata_at = self.bytes_received + metaint;
                    continue;
                }
            }

            // Process audio data (simplified - would need decoder)
            // For now, just count bytes
            const remaining = data.len - pos;
            self.bytes_received += remaining;
            pos += remaining;

            // In a real implementation, this would:
            // 1. Decode MP3/AAC/Opus frames
            // 2. Write PCM samples to ring buffer
            // 3. Call audio callback when buffer has enough data
        }
    }

    /// Parse Icecast metadata
    fn parseMetadata(self: *Self, data: []const u8) !void {
        // Parse StreamTitle='Artist - Title'; format
        var it = std.mem.splitSequence(u8, data, "='");

        while (it.next()) |key| {
            if (std.mem.eql(u8, key, "StreamTitle")) {
                if (it.next()) |value| {
                    // Find end quote
                    if (std.mem.indexOfScalar(u8, value, '\'')) |end| {
                        const title_str = value[0..end];

                        // Parse "Artist - Title" format
                        if (std.mem.indexOf(u8, title_str, " - ")) |sep| {
                            if (self.current_metadata.artist) |old| self.allocator.free(old);
                            if (self.current_metadata.title) |old| self.allocator.free(old);

                            self.current_metadata.artist = try self.allocator.dupe(u8, title_str[0..sep]);
                            self.current_metadata.title = try self.allocator.dupe(u8, title_str[sep + 3 ..]);
                        } else {
                            if (self.current_metadata.title) |old| self.allocator.free(old);
                            self.current_metadata.title = try self.allocator.dupe(u8, title_str);
                        }

                        // Call metadata callback
                        if (self.metadata_callback) |callback| {
                            callback(&self.current_metadata, self.metadata_callback_data);
                        }
                    }
                }
            }
        }
    }

    /// Get current state
    pub fn getState(self: *Self) StreamState {
        return self.state;
    }

    /// Get buffered amount (in samples)
    pub fn getBufferedAmount(self: *Self) usize {
        return self.ring_buffer.available();
    }

    /// Get current metadata
    pub fn getMetadata(self: *Self) *const StreamMetadata {
        return &self.current_metadata;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RingBuffer init" {
    const allocator = std.testing.allocator;

    var rb = try RingBuffer.init(allocator, 1024);
    defer rb.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1024), rb.capacity);
    try std.testing.expectEqual(@as(usize, 0), rb.available());
}

test "RingBuffer write/read" {
    const allocator = std.testing.allocator;

    var rb = try RingBuffer.init(allocator, 16);
    defer rb.deinit(allocator);

    const data = [_]f32{ 1, 2, 3, 4, 5 };
    const written = rb.write(&data);
    try std.testing.expectEqual(@as(usize, 5), written);
    try std.testing.expectEqual(@as(usize, 5), rb.available());

    var out: [5]f32 = undefined;
    const read_count = rb.read(&out);
    try std.testing.expectEqual(@as(usize, 5), read_count);
    try std.testing.expectEqualSlices(f32, &data, &out);
}

test "RingBuffer wraparound" {
    const allocator = std.testing.allocator;

    var rb = try RingBuffer.init(allocator, 8);
    defer rb.deinit(allocator);

    // Fill partially
    _ = rb.write(&[_]f32{ 1, 2, 3, 4, 5 });

    // Read some
    var out: [3]f32 = undefined;
    _ = rb.read(&out);

    // Write more (should wrap)
    _ = rb.write(&[_]f32{ 6, 7, 8 });

    try std.testing.expectEqual(@as(usize, 5), rb.available());
}

test "StreamMetadata deinit" {
    const allocator = std.testing.allocator;

    var meta = StreamMetadata{
        .title = try allocator.dupe(u8, "Test Title"),
        .artist = try allocator.dupe(u8, "Test Artist"),
    };
    defer meta.deinit(allocator);

    try std.testing.expect(meta.title != null);
}
