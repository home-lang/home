const std = @import("std");

/// HTTP/2 Frame Types and Encoding/Decoding

pub const FrameType = enum(u8) {
    DATA = 0x00,
    HEADERS = 0x01,
    PRIORITY = 0x02,
    RST_STREAM = 0x03,
    SETTINGS = 0x04,
    PUSH_PROMISE = 0x05,
    PING = 0x06,
    GOAWAY = 0x07,
    WINDOW_UPDATE = 0x08,
    CONTINUATION = 0x09,
};

pub const Frame = struct {
    type: FrameType,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
};

pub const DataFrame = struct {
    stream_id: u32,
    end_stream: bool,
    padded: bool,
    data: []const u8,

    pub fn init(stream_id: u32) DataFrame {
        return .{
            .stream_id = stream_id,
            .end_stream = false,
            .padded = false,
            .data = &.{},
        };
    }

    pub fn encode(self: DataFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        var flags: u8 = 0;
        if (self.end_stream) flags |= 0x01;
        if (self.padded) flags |= 0x08;

        // Frame header
        try buffer.writer().writeInt(u24, @intCast(self.data.len), .big);
        try buffer.append(@intFromEnum(FrameType.DATA));
        try buffer.append(flags);
        try buffer.writer().writeInt(u32, self.stream_id, .big);

        // Payload
        try buffer.appendSlice(self.data);

        return buffer.toOwnedSlice();
    }
};

pub const HeadersFrame = struct {
    stream_id: u32,
    end_stream: bool,
    end_headers: bool,
    padded: bool,
    priority: bool,
    fragment: []const u8,

    pub fn init(stream_id: u32) HeadersFrame {
        return .{
            .stream_id = stream_id,
            .end_stream = false,
            .end_headers = false,
            .padded = false,
            .priority = false,
            .fragment = &.{},
        };
    }

    pub fn encode(self: HeadersFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        var flags: u8 = 0;
        if (self.end_stream) flags |= 0x01;
        if (self.end_headers) flags |= 0x04;
        if (self.padded) flags |= 0x08;
        if (self.priority) flags |= 0x20;

        // Frame header
        try buffer.writer().writeInt(u24, @intCast(self.fragment.len), .big);
        try buffer.append(@intFromEnum(FrameType.HEADERS));
        try buffer.append(flags);
        try buffer.writer().writeInt(u32, self.stream_id, .big);

        // Payload
        try buffer.appendSlice(self.fragment);

        return buffer.toOwnedSlice();
    }
};

pub const SettingsFrame = struct {
    header_table_size: u32,
    enable_push: bool,
    max_concurrent_streams: u32,
    initial_window_size: u32,
    max_frame_size: u32,
    max_header_list_size: u32,
    ack: bool,

    pub const SettingId = enum(u16) {
        HEADER_TABLE_SIZE = 0x01,
        ENABLE_PUSH = 0x02,
        MAX_CONCURRENT_STREAMS = 0x03,
        INITIAL_WINDOW_SIZE = 0x04,
        MAX_FRAME_SIZE = 0x05,
        MAX_HEADER_LIST_SIZE = 0x06,
    };

    pub fn init() SettingsFrame {
        return .{
            .header_table_size = 4096,
            .enable_push = true,
            .max_concurrent_streams = 100,
            .initial_window_size = 65535,
            .max_frame_size = 16384,
            .max_header_list_size = 8192,
            .ack = false,
        };
    }

    pub fn encode(self: SettingsFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        var flags: u8 = 0;
        if (self.ack) {
            flags |= 0x01;

            // ACK frame has no payload
            try buffer.writer().writeInt(u24, 0, .big);
            try buffer.append(@intFromEnum(FrameType.SETTINGS));
            try buffer.append(flags);
            try buffer.writer().writeInt(u32, 0, .big);

            return buffer.toOwnedSlice();
        }

        // Calculate payload size (6 bytes per setting)
        const payload_size: u24 = 36; // 6 settings * 6 bytes

        // Frame header
        try buffer.writer().writeInt(u24, payload_size, .big);
        try buffer.append(@intFromEnum(FrameType.SETTINGS));
        try buffer.append(flags);
        try buffer.writer().writeInt(u32, 0, .big); // Stream ID must be 0

        // Settings
        try buffer.writer().writeInt(u16, @intFromEnum(SettingId.HEADER_TABLE_SIZE), .big);
        try buffer.writer().writeInt(u32, self.header_table_size, .big);

        try buffer.writer().writeInt(u16, @intFromEnum(SettingId.ENABLE_PUSH), .big);
        try buffer.writer().writeInt(u32, if (self.enable_push) 1 else 0, .big);

        try buffer.writer().writeInt(u16, @intFromEnum(SettingId.MAX_CONCURRENT_STREAMS), .big);
        try buffer.writer().writeInt(u32, self.max_concurrent_streams, .big);

        try buffer.writer().writeInt(u16, @intFromEnum(SettingId.INITIAL_WINDOW_SIZE), .big);
        try buffer.writer().writeInt(u32, self.initial_window_size, .big);

        try buffer.writer().writeInt(u16, @intFromEnum(SettingId.MAX_FRAME_SIZE), .big);
        try buffer.writer().writeInt(u32, self.max_frame_size, .big);

        try buffer.writer().writeInt(u16, @intFromEnum(SettingId.MAX_HEADER_LIST_SIZE), .big);
        try buffer.writer().writeInt(u32, self.max_header_list_size, .big);

        return buffer.toOwnedSlice();
    }
};

pub const PingFrame = struct {
    data: [8]u8,
    ack: bool,

    pub fn init() PingFrame {
        return .{
            .data = [_]u8{0} ** 8,
            .ack = false,
        };
    }

    pub fn encode(self: PingFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        var flags: u8 = 0;
        if (self.ack) flags |= 0x01;

        // Frame header
        try buffer.writer().writeInt(u24, 8, .big);
        try buffer.append(@intFromEnum(FrameType.PING));
        try buffer.append(flags);
        try buffer.writer().writeInt(u32, 0, .big); // Stream ID must be 0

        // Payload
        try buffer.appendSlice(&self.data);

        return buffer.toOwnedSlice();
    }
};

pub const WindowUpdateFrame = struct {
    stream_id: u32,
    increment: u32,

    pub fn encode(self: WindowUpdateFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        // Frame header
        try buffer.writer().writeInt(u24, 4, .big);
        try buffer.append(@intFromEnum(FrameType.WINDOW_UPDATE));
        try buffer.append(0); // No flags
        try buffer.writer().writeInt(u32, self.stream_id, .big);

        // Payload (increment with reserved bit cleared)
        try buffer.writer().writeInt(u32, self.increment & 0x7FFFFFFF, .big);

        return buffer.toOwnedSlice();
    }
};

pub const GoAwayFrame = struct {
    last_stream_id: u32,
    error_code: u32,
    debug_data: []const u8,

    pub fn encode(self: GoAwayFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const payload_size: u24 = @intCast(8 + self.debug_data.len);

        // Frame header
        try buffer.writer().writeInt(u24, payload_size, .big);
        try buffer.append(@intFromEnum(FrameType.GOAWAY));
        try buffer.append(0); // No flags
        try buffer.writer().writeInt(u32, 0, .big); // Stream ID must be 0

        // Payload
        try buffer.writer().writeInt(u32, self.last_stream_id & 0x7FFFFFFF, .big);
        try buffer.writer().writeInt(u32, self.error_code, .big);
        try buffer.appendSlice(self.debug_data);

        return buffer.toOwnedSlice();
    }
};
