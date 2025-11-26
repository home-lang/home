const std = @import("std");

/// HTTP Cookie handling for client and server
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires: ?i64 = null,
    max_age: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .None,

    pub const SameSite = enum {
        None,
        Lax,
        Strict,

        pub fn toString(self: SameSite) []const u8 {
            return switch (self) {
                .None => "None",
                .Lax => "Lax",
                .Strict => "Strict",
            };
        }
    };

    /// Parse cookie from Set-Cookie header
    pub fn parse(allocator: std.mem.Allocator, header: []const u8) !Cookie {
        var cookie = Cookie{
            .name = "",
            .value = "",
        };

        var iter = std.mem.splitScalar(u8, header, ';');

        // First part is name=value
        if (iter.next()) |first| {
            const trimmed = std.mem.trim(u8, first, " ");
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                cookie.name = try allocator.dupe(u8, trimmed[0..eq_pos]);
                cookie.value = try allocator.dupe(u8, trimmed[eq_pos + 1 ..]);
            }
        }

        // Parse attributes
        while (iter.next()) |attr| {
            const trimmed = std.mem.trim(u8, attr, " ");

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = trimmed[0..eq_pos];
                const value = trimmed[eq_pos + 1 ..];

                if (std.mem.eql(u8, key, "Domain")) {
                    cookie.domain = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "Path")) {
                    cookie.path = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "Max-Age")) {
                    cookie.max_age = try std.fmt.parseInt(i64, value, 10);
                } else if (std.mem.eql(u8, key, "SameSite")) {
                    if (std.mem.eql(u8, value, "Lax")) {
                        cookie.same_site = .Lax;
                    } else if (std.mem.eql(u8, value, "Strict")) {
                        cookie.same_site = .Strict;
                    }
                }
            } else {
                if (std.mem.eql(u8, trimmed, "Secure")) {
                    cookie.secure = true;
                } else if (std.mem.eql(u8, trimmed, "HttpOnly")) {
                    cookie.http_only = true;
                }
            }
        }

        return cookie;
    }

    /// Serialize cookie to Set-Cookie header
    pub fn toString(self: *const Cookie, allocator: std.mem.Allocator) ![]u8 {
        var parts = std.ArrayList(u8).init(allocator);
        const writer = parts.writer();

        try writer.print("{s}={s}", .{ self.name, self.value });

        if (self.domain) |domain| {
            try writer.print("; Domain={s}", .{domain});
        }

        if (self.path) |path| {
            try writer.print("; Path={s}", .{path});
        }

        if (self.max_age) |max_age| {
            try writer.print("; Max-Age={d}", .{max_age});
        }

        if (self.secure) {
            try writer.writeAll("; Secure");
        }

        if (self.http_only) {
            try writer.writeAll("; HttpOnly");
        }

        if (self.same_site != .None) {
            try writer.print("; SameSite={s}", .{self.same_site.toString()});
        }

        return parts.toOwnedSlice();
    }

    pub fn deinit(self: *Cookie, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        if (self.domain) |domain| allocator.free(domain);
        if (self.path) |path| allocator.free(path);
    }
};

/// Cookie jar for managing multiple cookies
pub const CookieJar = struct {
    allocator: std.mem.Allocator,
    cookies: std.StringHashMap(Cookie),

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .allocator = allocator,
            .cookies = std.StringHashMap(Cookie).init(allocator),
        };
    }

    pub fn deinit(self: *CookieJar) void {
        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            var cookie = entry.value_ptr;
            cookie.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cookies.deinit();
    }

    /// Add cookie to jar
    pub fn add(self: *CookieJar, cookie: Cookie) !void {
        const key = try self.allocator.dupe(u8, cookie.name);
        try self.cookies.put(key, cookie);
    }

    /// Get cookie by name
    pub fn get(self: *const CookieJar, name: []const u8) ?*const Cookie {
        return self.cookies.getPtr(name);
    }

    /// Remove cookie by name
    pub fn remove(self: *CookieJar, name: []const u8) void {
        if (self.cookies.fetchRemove(name)) |kv| {
            var cookie = kv.value;
            cookie.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }

    /// Get all cookies for a domain and path
    pub fn getForRequest(
        self: *const CookieJar,
        domain: []const u8,
        path: []const u8,
        secure: bool,
    ) ![]Cookie {
        var result = std.ArrayList(Cookie).init(self.allocator);

        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            const cookie = entry.value_ptr;

            // Check domain match
            if (cookie.domain) |cookie_domain| {
                if (!std.mem.endsWith(u8, domain, cookie_domain)) {
                    continue;
                }
            }

            // Check path match
            if (cookie.path) |cookie_path| {
                if (!std.mem.startsWith(u8, path, cookie_path)) {
                    continue;
                }
            }

            // Check secure flag
            if (cookie.secure and !secure) {
                continue;
            }

            // Check expiration
            if (cookie.max_age) |max_age| {
                if (max_age <= 0) {
                    continue;
                }
            }

            try result.append(cookie.*);
        }

        return result.toOwnedSlice();
    }

    /// Generate Cookie header value
    pub fn toCookieHeader(self: *const CookieJar, allocator: std.mem.Allocator) ![]u8 {
        var parts = std.ArrayList(u8).init(allocator);
        const writer = parts.writer();

        var first = true;
        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            const cookie = entry.value_ptr;

            if (!first) {
                try writer.writeAll("; ");
            }
            first = false;

            try writer.print("{s}={s}", .{ cookie.name, cookie.value });
        }

        return parts.toOwnedSlice();
    }
};

test "Cookie parse" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const header = "session=abc123; Domain=example.com; Path=/; Secure; HttpOnly";
    var cookie = try Cookie.parse(allocator, header);
    defer cookie.deinit(allocator);

    try testing.expectEqualStrings("session", cookie.name);
    try testing.expectEqualStrings("abc123", cookie.value);
    try testing.expect(cookie.secure);
    try testing.expect(cookie.http_only);
}

test "CookieJar" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    const cookie = Cookie{
        .name = try allocator.dupe(u8, "test"),
        .value = try allocator.dupe(u8, "value"),
    };

    try jar.add(cookie);

    const retrieved = jar.get("test");
    try testing.expect(retrieved != null);
}
