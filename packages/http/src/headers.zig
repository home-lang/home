const std = @import("std");

/// HTTP headers collection
pub const Headers = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Headers {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Headers) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Set a header value (case-insensitive name)
    pub fn set(self: *Headers, name: []const u8, value: []const u8) !void {
        const lower_name = try self.toLower(name);
        errdefer self.allocator.free(lower_name);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        // Remove old entry if it exists
        if (self.map.fetchRemove(lower_name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.map.put(lower_name, owned_value);
    }

    /// Get a header value (case-insensitive name)
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        const lower_name = self.toLower(name) catch return null;
        defer self.allocator.free(lower_name);
        return self.map.get(lower_name);
    }

    /// Check if header exists (case-insensitive name)
    pub fn has(self: *const Headers, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Remove a header (case-insensitive name)
    pub fn remove(self: *Headers, name: []const u8) void {
        const lower_name = self.toLower(name) catch return;
        defer self.allocator.free(lower_name);

        if (self.map.fetchRemove(lower_name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    /// Get all header names
    pub fn names(self: *const Headers, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8).init(allocator);
        errdefer list.deinit();

        var it = self.map.keyIterator();
        while (it.next()) |key| {
            try list.append(key.*);
        }

        return list.toOwnedSlice();
    }

    /// Convert string to lowercase for case-insensitive comparison
    fn toLower(self: *const Headers, str: []const u8) ![]u8 {
        const result = try self.allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return result;
    }

    /// Common header name constants
    pub const ContentType = "Content-Type";
    pub const ContentLength = "Content-Length";
    pub const Accept = "Accept";
    pub const AcceptEncoding = "Accept-Encoding";
    pub const AcceptLanguage = "Accept-Language";
    pub const Authorization = "Authorization";
    pub const CacheControl = "Cache-Control";
    pub const Connection = "Connection";
    pub const Cookie = "Cookie";
    pub const Host = "Host";
    pub const Origin = "Origin";
    pub const Referer = "Referer";
    pub const UserAgent = "User-Agent";
    pub const SetCookie = "Set-Cookie";
    pub const Location = "Location";
    pub const Server = "Server";
    pub const WWWAuthenticate = "WWW-Authenticate";
    pub const AccessControlAllowOrigin = "Access-Control-Allow-Origin";
    pub const AccessControlAllowMethods = "Access-Control-Allow-Methods";
    pub const AccessControlAllowHeaders = "Access-Control-Allow-Headers";
    pub const AccessControlAllowCredentials = "Access-Control-Allow-Credentials";
};

/// Common MIME types
pub const MimeType = struct {
    pub const TextPlain = "text/plain";
    pub const TextHTML = "text/html";
    pub const TextCSS = "text/css";
    pub const TextJavaScript = "text/javascript";
    pub const ApplicationJSON = "application/json";
    pub const ApplicationXML = "application/xml";
    pub const ApplicationFormUrlEncoded = "application/x-www-form-urlencoded";
    pub const MultipartFormData = "multipart/form-data";
    pub const ApplicationOctetStream = "application/octet-stream";
    pub const ImagePNG = "image/png";
    pub const ImageJPEG = "image/jpeg";
    pub const ImageGIF = "image/gif";
    pub const ImageSVG = "image/svg+xml";
    pub const ImageWebP = "image/webp";
};

test "Headers set and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "application/json");
    try testing.expectEqualStrings("application/json", headers.get("Content-Type").?);

    // Case insensitive
    try testing.expectEqualStrings("application/json", headers.get("content-type").?);
    try testing.expectEqualStrings("application/json", headers.get("CONTENT-TYPE").?);
}

test "Headers has and remove" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Accept", "application/json");
    try testing.expect(headers.has("Accept"));
    try testing.expect(headers.has("accept"));

    headers.remove("Accept");
    try testing.expect(!headers.has("Accept"));
}
