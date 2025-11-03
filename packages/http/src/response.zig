const std = @import("std");
const Status = @import("method.zig").Status;
const Version = @import("method.zig").Version;
const Headers = @import("headers.zig").Headers;
const MimeType = @import("headers.zig").MimeType;

/// HTTP Response
pub const Response = struct {
    status: Status,
    version: Version,
    headers: Headers,
    body: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) *Response {
        const res = allocator.create(Response) catch unreachable;
        res.* = .{
            .status = .OK,
            .version = .HTTP_1_1,
            .headers = Headers.init(allocator),
            .body = .{},
            .allocator = allocator,
        };
        return res;
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.body.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Set the HTTP status code
    pub fn setStatus(self: *Response, status: Status) *Response {
        self.status = status;
        return self;
    }

    /// Set a header
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !*Response {
        try self.headers.set(name, value);
        return self;
    }

    /// Send plain text response
    pub fn send(self: *Response, text: []const u8) !void {
        _ = try self.setHeader("Content-Type", MimeType.TextPlain);
        try self.body.appendSlice(self.allocator, text);
    }

    /// Send JSON response
    pub fn json(self: *Response, value: anytype) !void {
        _ = try self.setHeader("Content-Type", MimeType.ApplicationJSON);
        try std.json.stringify(value, .{}, self.body.writer(self.allocator));
    }

    /// Send HTML response
    pub fn html(self: *Response, content: []const u8) !void {
        _ = try self.setHeader("Content-Type", MimeType.TextHTML);
        try self.body.appendSlice(self.allocator, content);
    }

    /// Redirect to another URL
    pub fn redirect(self: *Response, location: []const u8, status: ?Status) !void {
        self.status = status orelse .Found;
        _ = try self.setHeader("Location", location);
    }

    /// Set cookie
    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, options: CookieOptions) !void {
        var cookie_value = std.ArrayList(u8).init(self.allocator);
        defer cookie_value.deinit();

        try cookie_value.writer().print("{s}={s}", .{ name, value });

        if (options.max_age) |max_age| {
            try cookie_value.writer().print("; Max-Age={d}", .{max_age});
        }

        if (options.path) |path| {
            try cookie_value.writer().print("; Path={s}", .{path});
        }

        if (options.domain) |domain| {
            try cookie_value.writer().print("; Domain={s}", .{domain});
        }

        if (options.secure) {
            try cookie_value.appendSlice("; Secure");
        }

        if (options.http_only) {
            try cookie_value.appendSlice("; HttpOnly");
        }

        if (options.same_site) |same_site| {
            try cookie_value.writer().print("; SameSite={s}", .{@tagName(same_site)});
        }

        try self.setHeader("Set-Cookie", cookie_value.items);
    }

    /// Build the complete HTTP response as bytes
    pub fn build(self: *Response) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        // Status line
        try result.writer().print("{s} {d} {s}\r\n", .{
            self.version.toString(),
            @intFromEnum(self.status),
            self.status.reasonPhrase(),
        });

        // Set Content-Length if not already set
        if (!self.headers.has("Content-Length")) {
            try self.headers.set("Content-Length", try std.fmt.allocPrint(
                self.allocator,
                "{d}",
                .{self.body.items.len},
            ));
        }

        // Headers
        const names_list = try self.headers.names(self.allocator);
        defer self.allocator.free(names_list);

        for (names_list) |name| {
            if (self.headers.get(name)) |value| {
                try result.writer().print("{s}: {s}\r\n", .{ name, value });
            }
        }

        // Empty line between headers and body
        try result.appendSlice("\r\n");

        // Body
        try result.appendSlice(self.body.items);

        return result.toOwnedSlice();
    }
};

/// Cookie options for setting cookies
pub const CookieOptions = struct {
    max_age: ?i64 = null, // Cookie lifetime in seconds
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
};

pub const SameSite = enum {
    Strict,
    Lax,
    None,
};

test "Response basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var res = Response.init(allocator);
    defer res.deinit();

    _ = res.setStatus(.NotFound);
    try res.send("Page not found");

    try testing.expectEqual(Status.NotFound, res.status);
    try testing.expectEqualStrings("Page not found", res.body.items);
}

test "Response JSON" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var res = Response.init(allocator);
    defer res.deinit();

    const data = .{ .name = "John", .age = 30 };
    try res.json(data);

    try testing.expect(std.mem.indexOf(u8, res.body.items, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.body.items, "John") != null);
}

test "Response redirect" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var res = Response.init(allocator);
    defer res.deinit();

    try res.redirect("/login", null);

    try testing.expectEqual(Status.Found, res.status);
    try testing.expectEqualStrings("/login", res.headers.get("Location").?);
}
