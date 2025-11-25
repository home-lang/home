const std = @import("std");

/// HTTP/2 package - provides HTTP/2 client and server functionality
pub const HTTP2Client = @import("client.zig").HTTP2Client;
pub const hpack = @import("hpack.zig");
pub const frame = @import("frame.zig");

// Re-export commonly used types
pub const Header = hpack.Header;
pub const Request = HTTP2Client.Request;
pub const Response = HTTP2Client.Response;
pub const Settings = HTTP2Client.Settings;

// Convenience functions
pub const get = @import("client.zig").get;
pub const post = @import("client.zig").post;

test {
    @import("std").testing.refAllDecls(@This());
}
