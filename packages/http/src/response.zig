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
    /// Note: This is a simplified version. Full JSON serialization will be implemented later.
    pub fn json(self: *Response, value: anytype) !void {
        _ = try self.setHeader("Content-Type", MimeType.ApplicationJSON);

        // For now, just send a simple JSON string representation
        // TODO: Implement full JSON serialization using std.json properly
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => |s| {
                try self.body.appendSlice(self.allocator, "{");
                inline for (s.fields, 0..) |field, i| {
                    if (i > 0) try self.body.appendSlice(self.allocator, ",");

                    const field_name = try std.fmt.allocPrint(self.allocator, "\"{s}\":", .{field.name});
                    defer self.allocator.free(field_name);
                    try self.body.appendSlice(self.allocator, field_name);

                    const field_value = @field(value, field.name);
                    const FT = @TypeOf(field_value);
                    const field_type_info = @typeInfo(FT);

                    switch (field_type_info) {
                        .@"int" => {
                            const val_str = try std.fmt.allocPrint(self.allocator, "{d}", .{field_value});
                            defer self.allocator.free(val_str);
                            try self.body.appendSlice(self.allocator, val_str);
                        },
                        .pointer => |ptr_info| {
                            if (ptr_info.size == .slice and ptr_info.child == u8) {
                                const val_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{field_value});
                                defer self.allocator.free(val_str);
                                try self.body.appendSlice(self.allocator, val_str);
                            }
                        },
                        else => try self.body.appendSlice(self.allocator, "null"),
                    }
                }
                try self.body.appendSlice(self.allocator, "}");
            },
            else => {
                // Fallback for non-struct types
                const str = try std.fmt.allocPrint(self.allocator, "\"{any}\"", .{value});
                defer self.allocator.free(str);
                try self.body.appendSlice(self.allocator, str);
            },
        }
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

    const Data = struct { name: []const u8, age: i32 };
    const data = Data{ .name = "John", .age = 30 };
    try res.json(data);

    // Check that the response has content and proper content type
    const body_str = res.body.items;
    try testing.expect(body_str.len > 0);
    try testing.expectEqualStrings(MimeType.ApplicationJSON, res.headers.get("Content-Type").?);

    // Verify it contains the expected data
    try testing.expect(std.mem.indexOf(u8, body_str, "John") != null);
    try testing.expect(std.mem.indexOf(u8, body_str, "30") != null);
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
