/// Home HTTP Framework
///
/// A high-performance, Express.js/Laravel-inspired HTTP framework for Home.
///
/// Features:
/// - Type-safe routing with path parameters
/// - Middleware system for request/response processing
/// - Built-in JSON support
/// - Cookie and session management
/// - Async request handling
///
/// Example usage:
/// ```home
/// let app = HttpServer.new();
/// app.get("/users/:id", async (req, res) => {
///     let user = await User.find(req.params.id);
///     res.json(user);
/// });
/// app.listen(3000);
/// ```

const std = @import("std");

// Core HTTP types
pub const Method = @import("method.zig").Method;
pub const Status = @import("method.zig").Status;
pub const Version = @import("method.zig").Version;

// Headers
pub const Headers = @import("headers.zig").Headers;
pub const MimeType = @import("headers.zig").MimeType;

// Request and Response
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const CookieOptions = @import("response.zig").CookieOptions;
pub const SameSite = @import("response.zig").SameSite;

// Router (to be implemented)
// pub const Router = @import("router.zig").Router;
// pub const Route = @import("router.zig").Route;

// Server (to be implemented)
// pub const HttpServer = @import("server.zig").HttpServer;

test {
    std.testing.refAllDecls(@This());
}
