const std = @import("std");
const posix = std.posix;
const net = std.net;

// ============================================================================
// Core Types
// ============================================================================

/// HTTP Methods
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    CONNECT,
    TRACE,

    pub fn fromString(str: []const u8) ?Method {
        const methods = .{
            .{ "GET", Method.GET },
            .{ "POST", Method.POST },
            .{ "PUT", Method.PUT },
            .{ "DELETE", Method.DELETE },
            .{ "PATCH", Method.PATCH },
            .{ "HEAD", Method.HEAD },
            .{ "OPTIONS", Method.OPTIONS },
            .{ "CONNECT", Method.CONNECT },
            .{ "TRACE", Method.TRACE },
        };
        inline for (methods) |m| {
            if (std.mem.eql(u8, str, m[0])) return m[1];
        }
        return null;
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .CONNECT => "CONNECT",
            .TRACE => "TRACE",
        };
    }
};

/// HTTP Status codes
pub const Status = enum(u16) {
    // 1xx Informational
    continue_ = 100,
    switching_protocols = 101,
    processing = 102,

    // 2xx Success
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,

    // 3xx Redirection
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,

    // 4xx Client Errors
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    im_a_teapot = 418,
    unprocessable_entity = 422,
    too_many_requests = 429,

    // 5xx Server Errors
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,

    pub fn phrase(self: Status) []const u8 {
        return switch (self) {
            .continue_ => "Continue",
            .switching_protocols => "Switching Protocols",
            .processing => "Processing",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .im_a_teapot => "I'm a teapot",
            .unprocessable_entity => "Unprocessable Entity",
            .too_many_requests => "Too Many Requests",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
        };
    }
};

// ============================================================================
// Headers
// ============================================================================

pub const Headers = struct {
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn set(self: *Self, name: []const u8, value: []const u8) !void {
        const lower_name = try self.toLower(name);
        errdefer self.allocator.free(lower_name);

        // Check if header exists
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, lower_name)) {
                self.allocator.free(lower_name);
                self.allocator.free(entry.value);
                entry.value = try self.allocator.dupe(u8, value);
                return;
            }
        }

        const value_copy = try self.allocator.dupe(u8, value);
        try self.entries.append(self.allocator, .{
            .name = lower_name,
            .value = value_copy,
        });
    }

    pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const lower = toLowerBuf(name, &buf) catch return null;

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, lower)) {
                return entry.value;
            }
        }
        return null;
    }

    pub fn remove(self: *Self, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const lower = toLowerBuf(name, &buf) catch return;

        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].name, lower)) {
                self.allocator.free(self.entries.items[i].name);
                self.allocator.free(self.entries.items[i].value);
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn has(self: *const Self, name: []const u8) bool {
        return self.get(name) != null;
    }

    fn toLower(self: *Self, str: []const u8) ![]u8 {
        const result = try self.allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return result;
    }

    fn toLowerBuf(str: []const u8, buf: []u8) ![]u8 {
        if (str.len > buf.len) return error.BufferTooSmall;
        for (str, 0..) |c, i| {
            buf[i] = std.ascii.toLower(c);
        }
        return buf[0..str.len];
    }

    pub fn iterator(self: *const Self) []const Entry {
        return self.entries.items;
    }
};

// ============================================================================
// Request
// ============================================================================

pub const Request = struct {
    method: Method,
    path: []const u8,
    query_string: ?[]const u8,
    headers: Headers,
    body: ?[]const u8,
    params: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    // Parsed data (lazy)
    _query_params: ?std.StringHashMap([]const u8),
    _cookies: ?std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8) Self {
        // Split path and query string
        var actual_path = path;
        var qs: ?[]const u8 = null;

        if (std.mem.indexOf(u8, path, "?")) |idx| {
            actual_path = path[0..idx];
            qs = path[idx + 1 ..];
        }

        return .{
            .method = method,
            .path = actual_path,
            .query_string = qs,
            .headers = Headers.init(allocator),
            .body = null,
            .params = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            ._query_params = null,
            ._cookies = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.params.deinit();
        if (self._query_params) |*qp| qp.deinit();
        if (self._cookies) |*c| c.deinit();
    }

    /// Get a route parameter
    pub fn param(self: *const Self, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Get a query parameter
    pub fn query(self: *Self, name: []const u8) ?[]const u8 {
        if (self._query_params == null) {
            self._query_params = self.parseQueryString();
        }
        if (self._query_params) |qp| {
            return qp.get(name);
        }
        return null;
    }

    /// Get a cookie value
    pub fn cookie(self: *Self, name: []const u8) ?[]const u8 {
        if (self._cookies == null) {
            self._cookies = self.parseCookies();
        }
        if (self._cookies) |c| {
            return c.get(name);
        }
        return null;
    }

    /// Get header value
    pub fn header(self: *const Self, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Check if request accepts JSON
    pub fn acceptsJson(self: *const Self) bool {
        if (self.headers.get("accept")) |accept| {
            return std.mem.indexOf(u8, accept, "application/json") != null;
        }
        return false;
    }

    /// Check if request is AJAX
    pub fn isAjax(self: *const Self) bool {
        if (self.headers.get("x-requested-with")) |xrw| {
            return std.mem.eql(u8, xrw, "xmlhttprequest");
        }
        return false;
    }

    /// Get content type
    pub fn contentType(self: *const Self) ?[]const u8 {
        return self.headers.get("content-type");
    }

    fn parseQueryString(self: *Self) ?std.StringHashMap([]const u8) {
        const qs = self.query_string orelse return null;

        var result = std.StringHashMap([]const u8).init(self.allocator);
        var pairs = std.mem.splitScalar(u8, qs, '&');

        while (pairs.next()) |pair| {
            if (std.mem.indexOf(u8, pair, "=")) |eq_idx| {
                const key = pair[0..eq_idx];
                const value = pair[eq_idx + 1 ..];
                result.put(key, value) catch continue;
            }
        }

        return result;
    }

    fn parseCookies(self: *Self) ?std.StringHashMap([]const u8) {
        const cookie_header = self.headers.get("cookie") orelse return null;

        var result = std.StringHashMap([]const u8).init(self.allocator);
        var pairs = std.mem.splitSequence(u8, cookie_header, "; ");

        while (pairs.next()) |pair| {
            if (std.mem.indexOf(u8, pair, "=")) |eq_idx| {
                const key = pair[0..eq_idx];
                const value = pair[eq_idx + 1 ..];
                result.put(key, value) catch continue;
            }
        }

        return result;
    }
};

// ============================================================================
// Response
// ============================================================================

pub const Response = struct {
    status: Status,
    headers: Headers,
    body: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    sent: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .status = .ok,
            .headers = Headers.init(allocator),
            .body = .empty,
            .allocator = allocator,
            .sent = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.body.deinit(self.allocator);
    }

    /// Set response status
    pub fn setStatus(self: *Self, status: Status) *Self {
        self.status = status;
        return self;
    }

    /// Set a header
    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !*Self {
        try self.headers.set(name, value);
        return self;
    }

    /// Write to body
    pub fn write(self: *Self, data: []const u8) !*Self {
        try self.body.appendSlice(self.allocator, data);
        return self;
    }

    /// Write formatted data
    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !*Self {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.body.appendSlice(self.allocator, formatted);
        return self;
    }

    /// Send plain text
    pub fn text(self: *Self, content: []const u8) !void {
        _ = try self.setHeader("Content-Type", "text/plain; charset=utf-8");
        _ = try self.write(content);
    }

    /// Send HTML
    pub fn html(self: *Self, content: []const u8) !void {
        _ = try self.setHeader("Content-Type", "text/html; charset=utf-8");
        _ = try self.write(content);
    }

    /// Send JSON (pass a JSON string directly)
    pub fn json(self: *Self, json_str: []const u8) !void {
        _ = try self.setHeader("Content-Type", "application/json");
        _ = try self.write(json_str);
    }

    /// Send JSON string directly
    pub fn jsonRaw(self: *Self, json_str: []const u8) !void {
        _ = try self.setHeader("Content-Type", "application/json");
        _ = try self.write(json_str);
    }

    /// Redirect to URL
    pub fn redirect(self: *Self, url: []const u8, permanent: bool) !void {
        self.status = if (permanent) .moved_permanently else .found;
        _ = try self.setHeader("Location", url);
    }

    /// Set a cookie
    pub fn setCookie(self: *Self, name: []const u8, value: []const u8, options: CookieOptions) !void {
        var cookie_parts: std.ArrayListUnmanaged(u8) = .empty;
        defer cookie_parts.deinit(self.allocator);

        // Build cookie string
        try cookie_parts.appendSlice(self.allocator, name);
        try cookie_parts.append(self.allocator, '=');
        try cookie_parts.appendSlice(self.allocator, value);

        if (options.max_age) |max_age| {
            const part = try std.fmt.allocPrint(self.allocator, "; Max-Age={d}", .{max_age});
            defer self.allocator.free(part);
            try cookie_parts.appendSlice(self.allocator, part);
        }
        if (options.path) |p| {
            try cookie_parts.appendSlice(self.allocator, "; Path=");
            try cookie_parts.appendSlice(self.allocator, p);
        }
        if (options.domain) |domain| {
            try cookie_parts.appendSlice(self.allocator, "; Domain=");
            try cookie_parts.appendSlice(self.allocator, domain);
        }
        if (options.secure) {
            try cookie_parts.appendSlice(self.allocator, "; Secure");
        }
        if (options.http_only) {
            try cookie_parts.appendSlice(self.allocator, "; HttpOnly");
        }
        if (options.same_site) |same_site| {
            try cookie_parts.appendSlice(self.allocator, "; SameSite=");
            try cookie_parts.appendSlice(self.allocator, same_site);
        }

        _ = try self.setHeader("Set-Cookie", cookie_parts.items);
    }

    /// Build HTTP response bytes
    pub fn build(self: *Self) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Status line
        const status_line = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.status), self.status.phrase() });
        defer self.allocator.free(status_line);
        try result.appendSlice(self.allocator, status_line);

        // Content-Length header
        const content_length = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n", .{self.body.items.len});
        defer self.allocator.free(content_length);
        try result.appendSlice(self.allocator, content_length);

        // Headers
        for (self.headers.iterator()) |entry| {
            const header_line = try std.fmt.allocPrint(self.allocator, "{s}: {s}\r\n", .{ entry.name, entry.value });
            defer self.allocator.free(header_line);
            try result.appendSlice(self.allocator, header_line);
        }

        // Empty line
        try result.appendSlice(self.allocator, "\r\n");

        // Body
        try result.appendSlice(self.allocator, self.body.items);

        return result.toOwnedSlice(self.allocator);
    }
};

pub const CookieOptions = struct {
    max_age: ?i64 = null,
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = true,
    same_site: ?[]const u8 = "Lax",
};

// ============================================================================
// Context - The heart of request handling
// ============================================================================

pub const Context = struct {
    request: *Request,
    response: *Response,
    app: *Application,
    allocator: std.mem.Allocator,
    state: std.StringHashMap(*anyopaque),
    _next_index: usize,
    _middlewares: []const *const fn (*Context) anyerror!void,
    _handler: ?*const fn (*Context) anyerror!void,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        request: *Request,
        response: *Response,
        app: *Application,
    ) Self {
        return .{
            .request = request,
            .response = response,
            .app = app,
            .allocator = allocator,
            .state = std.StringHashMap(*anyopaque).init(allocator),
            ._next_index = 0,
            ._middlewares = &.{},
            ._handler = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.state.deinit();
    }

    /// Call next middleware
    pub fn next(self: *Self) !void {
        if (self._next_index < self._middlewares.len) {
            const middleware = self._middlewares[self._next_index];
            self._next_index += 1;
            try middleware(self);
        } else if (self._handler) |handler| {
            try handler(self);
        }
    }

    /// Store state for this request
    pub fn set(self: *Self, comptime T: type, key: []const u8, value: *T) !void {
        try self.state.put(key, @ptrCast(value));
    }

    /// Get state from this request
    pub fn get(self: *Self, comptime T: type, key: []const u8) ?*T {
        if (self.state.get(key)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    /// Get a service from the container
    pub fn service(self: *Self, comptime T: type) ?*T {
        return self.app.container.resolve(T);
    }

    /// Get config value
    pub fn config(self: *Self, key: []const u8) ?ConfigValue {
        return self.app.config.get(key);
    }

    // Response helpers
    pub fn text(self: *Self, content: []const u8) !void {
        try self.response.text(content);
    }

    pub fn html(self: *Self, content: []const u8) !void {
        try self.response.html(content);
    }

    pub fn json(self: *Self, value: anytype) !void {
        try self.response.json(value);
    }

    pub fn status(self: *Self, s: Status) *Self {
        _ = self.response.setStatus(s);
        return self;
    }

    pub fn redirect(self: *Self, url: []const u8) !void {
        try self.response.redirect(url, false);
    }

    pub fn notFound(self: *Self) !void {
        _ = self.response.setStatus(.not_found);
        try self.response.text("Not Found");
    }

    pub fn badRequest(self: *Self, message: []const u8) !void {
        _ = self.response.setStatus(.bad_request);
        try self.response.text(message);
    }

    pub fn serverError(self: *Self, message: []const u8) !void {
        _ = self.response.setStatus(.internal_server_error);
        try self.response.text(message);
    }
};

// ============================================================================
// Handler Type Aliases
// ============================================================================

pub const HandlerFn = *const fn (*Context) anyerror!void;
pub const MiddlewareFn = HandlerFn; // Middleware has same signature

// ============================================================================
// Router
// ============================================================================

const RouteSegment = union(enum) {
    static: []const u8,
    param: []const u8,
    wildcard: void,
};

const StoredRoute = struct {
    method: Method,
    pattern: []const u8,
    segments: []const RouteSegment,
    handler: HandlerFn,
    middlewares: []const HandlerFn,
    name: ?[]const u8,
};

pub const Router = struct {
    routes: std.ArrayListUnmanaged(StoredRoute),
    groups: std.ArrayListUnmanaged(*RouteGroup),
    global_middlewares: std.ArrayListUnmanaged(HandlerFn),
    allocator: std.mem.Allocator,
    not_found_handler: ?HandlerFn,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .routes = .empty,
            .groups = .empty,
            .global_middlewares = .empty,
            .allocator = allocator,
            .not_found_handler = null,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.pattern);
            self.allocator.free(route.segments);
        }
        self.routes.deinit(self.allocator);
        // Free all groups created by this router
        for (self.groups.items) |grp| {
            grp.deinit();
            self.allocator.destroy(grp);
        }
        self.groups.deinit(self.allocator);
        self.global_middlewares.deinit(self.allocator);
    }

    /// Add global middleware
    pub fn use(self: *Self, middleware: MiddlewareFn) !void {
        try self.global_middlewares.append(self.allocator, middleware);
    }

    /// Register a route
    pub fn add(self: *Self, method: Method, pattern: []const u8, handler: HandlerFn) !void {
        const pattern_copy = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_copy);
        const segments = try self.compilePattern(pattern_copy);

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern_copy,
            .segments = segments,
            .handler = handler,
            .middlewares = &.{},
            .name = null,
        });
    }

    // Convenience methods
    pub fn get(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.GET, pattern, handler);
    }

    pub fn post(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.POST, pattern, handler);
    }

    pub fn put(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PUT, pattern, handler);
    }

    pub fn delete(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PATCH, pattern, handler);
    }

    pub fn options(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.OPTIONS, pattern, handler);
    }

    /// Create a route group
    pub fn group(self: *Self, prefix: []const u8) !*RouteGroup {
        const grp = try self.allocator.create(RouteGroup);
        grp.* = RouteGroup.init(self, prefix);
        try self.groups.append(self.allocator, grp);
        return grp;
    }

    /// Set 404 handler
    pub fn notFound(self: *Self, handler: HandlerFn) void {
        self.not_found_handler = handler;
    }

    /// Match a request
    pub fn match(self: *Self, method: Method, path: []const u8) ?MatchResult {
        for (self.routes.items) |route| {
            if (route.method != method) continue;

            if (self.matchPattern(route.segments, path)) |params| {
                return .{
                    .route = route,
                    .params = params,
                };
            }
        }
        return null;
    }

    const MatchResult = struct {
        route: StoredRoute,
        params: std.StringHashMap([]const u8),
    };

    fn compilePattern(self: *Self, pattern: []const u8) ![]RouteSegment {
        var segments: std.ArrayListUnmanaged(RouteSegment) = .empty;
        errdefer segments.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, pattern, '/');
        while (iter.next()) |part| {
            if (part.len == 0) continue;

            if (part[0] == ':') {
                try segments.append(self.allocator, .{ .param = part[1..] });
            } else if (std.mem.eql(u8, part, "*")) {
                try segments.append(self.allocator, .{ .wildcard = {} });
            } else {
                try segments.append(self.allocator, .{ .static = part });
            }
        }

        return segments.toOwnedSlice(self.allocator);
    }

    fn matchPattern(self: *Self, segments: []const RouteSegment, path: []const u8) ?std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(self.allocator);

        var path_iter = std.mem.splitScalar(u8, path, '/');
        var seg_idx: usize = 0;

        while (path_iter.next()) |part| {
            if (part.len == 0) continue;

            if (seg_idx >= segments.len) {
                params.deinit();
                return null;
            }

            const segment = segments[seg_idx];
            switch (segment) {
                .static => |s| {
                    if (!std.mem.eql(u8, s, part)) {
                        params.deinit();
                        return null;
                    }
                },
                .param => |name| {
                    params.put(name, part) catch {
                        params.deinit();
                        return null;
                    };
                },
                .wildcard => return params,
            }
            seg_idx += 1;
        }

        if (seg_idx != segments.len) {
            params.deinit();
            return null;
        }

        return params;
    }
};

/// Route group for prefixed routes
pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    middlewares: std.ArrayListUnmanaged(MiddlewareFn),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(router: *Router, prefix: []const u8) Self {
        return .{
            .router = router,
            .prefix = prefix,
            .middlewares = .empty,
            .allocator = router.allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.middlewares.deinit(self.allocator);
    }

    pub fn use(self: *Self, middleware: MiddlewareFn) !*Self {
        try self.middlewares.append(self.allocator, middleware);
        return self;
    }

    fn fullPath(self: *Self, pattern: []const u8) ![]const u8 {
        if (self.prefix.len == 0) {
            return self.allocator.dupe(u8, pattern);
        }
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, pattern });
    }

    pub fn add(self: *Self, method: Method, pattern: []const u8, handler: HandlerFn) !void {
        const full = try self.fullPath(pattern);
        defer self.allocator.free(full);
        try self.router.add(method, full, handler);
    }

    pub fn get(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.GET, pattern, handler);
    }

    pub fn post(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.POST, pattern, handler);
    }

    pub fn put(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PUT, pattern, handler);
    }

    pub fn delete(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PATCH, pattern, handler);
    }
};

// ============================================================================
// Service Container (Dependency Injection)
// ============================================================================

pub const Container = struct {
    services: std.StringHashMap(ServiceEntry),
    allocator: std.mem.Allocator,

    const ServiceEntry = struct {
        instance: ?*anyopaque,
        factory: ?*const fn (*Container) anyerror!*anyopaque,
        singleton: bool,
        destructor: ?*const fn (*anyopaque) void,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .services = std.StringHashMap(ServiceEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.services.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.instance) |instance| {
                if (entry.value_ptr.destructor) |destructor| {
                    destructor(instance);
                }
            }
        }
        self.services.deinit();
    }

    /// Register a singleton instance
    pub fn singleton(self: *Self, comptime T: type, instance: *T) !void {
        const name = @typeName(T);
        try self.services.put(name, .{
            .instance = @ptrCast(instance),
            .factory = null,
            .singleton = true,
            .destructor = null,
        });
    }

    /// Register a factory function
    pub fn register(self: *Self, comptime T: type, factory: *const fn (*Container) anyerror!*T) !void {
        const name = @typeName(T);
        try self.services.put(name, .{
            .instance = null,
            .factory = @ptrCast(factory),
            .singleton = false,
            .destructor = null,
        });
    }

    /// Register a singleton factory (lazy instantiation)
    pub fn singletonFactory(self: *Self, comptime T: type, factory: *const fn (*Container) anyerror!*T) !void {
        const name = @typeName(T);
        try self.services.put(name, .{
            .instance = null,
            .factory = @ptrCast(factory),
            .singleton = true,
            .destructor = null,
        });
    }

    /// Resolve a service
    pub fn resolve(self: *Self, comptime T: type) ?*T {
        const name = @typeName(T);
        if (self.services.getPtr(name)) |entry| {
            if (entry.instance) |instance| {
                return @ptrCast(@alignCast(instance));
            }

            if (entry.factory) |factory| {
                const typed_factory: *const fn (*Container) anyerror!*T = @ptrCast(factory);
                if (typed_factory(self)) |instance| {
                    if (entry.singleton) {
                        entry.instance = @ptrCast(instance);
                    }
                    return instance;
                } else |_| {
                    return null;
                }
            }
        }
        return null;
    }

    /// Check if a service is registered
    pub fn has(self: *Self, comptime T: type) bool {
        const name = @typeName(T);
        return self.services.contains(name);
    }
};

// ============================================================================
// Configuration
// ============================================================================

pub const ConfigValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const ConfigValue,
    object: std.StringHashMap(ConfigValue),
    null_value: void,

    pub fn asString(self: ConfigValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(self: ConfigValue) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn asBool(self: ConfigValue) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn asFloat(self: ConfigValue) ?f64 {
        return switch (self) {
            .float => |f| f,
            else => null,
        };
    }
};

pub const Config = struct {
    values: std.StringHashMap(ConfigValue),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .values = std.StringHashMap(ConfigValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.values.deinit();
    }

    pub fn set(self: *Self, key: []const u8, value: ConfigValue) !void {
        try self.values.put(key, value);
    }

    pub fn get(self: *const Self, key: []const u8) ?ConfigValue {
        // Support dot notation: "app.name" -> nested lookup
        if (std.mem.indexOf(u8, key, ".")) |dot_idx| {
            const first_key = key[0..dot_idx];
            const rest = key[dot_idx + 1 ..];

            if (self.values.get(first_key)) |val| {
                switch (val) {
                    .object => |obj| return obj.get(rest),
                    else => return null,
                }
            }
            return null;
        }

        return self.values.get(key);
    }

    pub fn getString(self: *const Self, key: []const u8) ?[]const u8 {
        if (self.get(key)) |val| {
            return val.asString();
        }
        return null;
    }

    pub fn getInt(self: *const Self, key: []const u8) ?i64 {
        if (self.get(key)) |val| {
            return val.asInt();
        }
        return null;
    }

    pub fn getBool(self: *const Self, key: []const u8) ?bool {
        if (self.get(key)) |val| {
            return val.asBool();
        }
        return null;
    }

    /// Load from environment variable
    pub fn loadEnv(self: *Self, key: []const u8, env_name: []const u8) !void {
        if (posix.getenv(env_name)) |value| {
            try self.set(key, .{ .string = value });
        }
    }

    /// Load from environment with default
    pub fn loadEnvOr(self: *Self, key: []const u8, env_name: []const u8, default: ConfigValue) !void {
        if (posix.getenv(env_name)) |value| {
            try self.set(key, .{ .string = value });
        } else {
            try self.set(key, default);
        }
    }
};

// ============================================================================
// Service Provider
// ============================================================================

pub const ServiceProvider = struct {
    name: []const u8,
    register_fn: ?*const fn (*Application) anyerror!void,
    boot_fn: ?*const fn (*Application) anyerror!void,

    pub fn init(name: []const u8) ServiceProvider {
        return .{
            .name = name,
            .register_fn = null,
            .boot_fn = null,
        };
    }

    pub fn onRegister(self: *ServiceProvider, f: *const fn (*Application) anyerror!void) *ServiceProvider {
        self.register_fn = f;
        return self;
    }

    pub fn onBoot(self: *ServiceProvider, f: *const fn (*Application) anyerror!void) *ServiceProvider {
        self.boot_fn = f;
        return self;
    }
};

// ============================================================================
// Event System
// ============================================================================

pub const EventListener = *const fn (*anyopaque) void;

pub const EventEmitter = struct {
    listeners: std.StringHashMap(std.ArrayListUnmanaged(EventListener)),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .listeners = std.StringHashMap(std.ArrayListUnmanaged(EventListener)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.listeners.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.listeners.deinit();
    }

    pub fn on(self: *Self, event: []const u8, listener: EventListener) !void {
        const result = try self.listeners.getOrPut(event);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.append(self.allocator, listener);
    }

    pub fn emit(self: *Self, event: []const u8, data: *anyopaque) void {
        if (self.listeners.get(event)) |event_listeners| {
            for (event_listeners.items) |listener| {
                listener(data);
            }
        }
    }

    pub fn off(self: *Self, event: []const u8) void {
        if (self.listeners.getPtr(event)) |event_listeners| {
            event_listeners.deinit(self.allocator);
            _ = self.listeners.remove(event);
        }
    }
};

// ============================================================================
// Logger Integration
// ============================================================================

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
    fatal,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
};

pub const Logger = struct {
    level: LogLevel,
    prefix: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .level = .info,
            .prefix = "",
            .allocator = allocator,
        };
    }

    pub fn setLevel(self: *Self, level: LogLevel) void {
        self.level = level;
    }

    pub fn setPrefix(self: *Self, prefix: []const u8) void {
        self.prefix = prefix;
    }

    fn shouldLogLevel(self: *const Self, level: LogLevel) bool {
        return @intFromEnum(level) >= @intFromEnum(self.level);
    }

    pub fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLogLevel(.debug)) return;
        std.debug.print("[DEBUG] " ++ fmt ++ "\n", args);
    }

    pub fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLogLevel(.info)) return;
        std.debug.print("[INFO] " ++ fmt ++ "\n", args);
    }

    pub fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLogLevel(.warn)) return;
        std.debug.print("[WARN] " ++ fmt ++ "\n", args);
    }

    pub fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLogLevel(.err)) return;
        std.debug.print("[ERROR] " ++ fmt ++ "\n", args);
    }

    pub fn fatal(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLogLevel(.fatal)) return;
        std.debug.print("[FATAL] " ++ fmt ++ "\n", args);
    }
};

// ============================================================================
// Error Handler
// ============================================================================

pub const ErrorHandler = struct {
    handlers: std.ArrayListUnmanaged(ErrorHandlerFn),
    allocator: std.mem.Allocator,
    logger: *Logger,

    const ErrorHandlerFn = *const fn (anyerror, *Context) void;
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, logger: *Logger) Self {
        return .{
            .handlers = .empty,
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Self) void {
        self.handlers.deinit(self.allocator);
    }

    pub fn register(self: *Self, handler: ErrorHandlerFn) !void {
        try self.handlers.append(self.allocator, handler);
    }

    pub fn handle(self: *Self, err: anyerror, ctx: *Context) void {
        // Log the error
        self.logger.err("Request error: {s} - {s}", .{ ctx.request.path, @errorName(err) });

        // Call custom handlers
        for (self.handlers.items) |handler| {
            handler(err, ctx);
            if (ctx.response.sent) return;
        }

        // Default error response
        _ = ctx.response.setStatus(.internal_server_error);
        ctx.response.text("Internal Server Error") catch {};
    }
};

// ============================================================================
// Built-in Middleware
// ============================================================================

pub const Middleware = struct {
    /// Request logging middleware
    pub fn requestLogger(ctx: *Context) !void {
        const start = std.time.milliTimestamp();

        try ctx.next();

        const duration = std.time.milliTimestamp() - start;
        ctx.app.logger.info("{s} {s} - {d}ms - {d}", .{
            ctx.request.method.toString(),
            ctx.request.path,
            duration,
            @intFromEnum(ctx.response.status),
        });
    }

    /// Recovery middleware (catches panics)
    pub fn recovery(ctx: *Context) !void {
        ctx.next() catch |e| {
            ctx.app.error_handler.handle(e, ctx);
        };
    }

    /// CORS middleware
    pub fn cors(ctx: *Context) !void {
        _ = try ctx.response.setHeader("Access-Control-Allow-Origin", "*");
        _ = try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
        _ = try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

        if (ctx.request.method == .OPTIONS) {
            _ = ctx.response.setStatus(.no_content);
            return;
        }

        try ctx.next();
    }

    /// Security headers middleware
    pub fn securityHeaders(ctx: *Context) !void {
        _ = try ctx.response.setHeader("X-Content-Type-Options", "nosniff");
        _ = try ctx.response.setHeader("X-Frame-Options", "DENY");
        _ = try ctx.response.setHeader("X-XSS-Protection", "1; mode=block");
        _ = try ctx.response.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");

        try ctx.next();
    }

    /// Request ID middleware
    pub fn requestId(ctx: *Context) !void {
        var buf: [36]u8 = undefined;
        const id = generateUuid(&buf);
        _ = try ctx.response.setHeader("X-Request-ID", id);
        try ctx.next();
    }

    fn generateUuid(buf: *[36]u8) []const u8 {
        const timestamp = std.time.nanoTimestamp();
        const hash: u64 = @bitCast(timestamp);

        const hex = "0123456789abcdef";
        var i: usize = 0;
        var h = hash;

        while (i < 36) : (i += 1) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                buf[i] = '-';
            } else {
                buf[i] = hex[@as(usize, @intCast(h & 0xf))];
                h >>= 4;
                if (h == 0) h = hash ^ @as(u64, i);
            }
        }

        return buf;
    }
};

// ============================================================================
// HTTP Server
// ============================================================================

pub const Server = struct {
    app: *Application,
    address: net.Address,
    listener: ?posix.socket_t,
    running: bool,

    const Self = @This();

    pub fn init(app: *Application, host: []const u8, port: u16) !Self {
        const address = try net.Address.parseIp(host, port);
        return .{
            .app = app,
            .address = address,
            .listener = null,
            .running = false,
        };
    }

    pub fn listen(self: *Self) !void {
        const sock = try posix.socket(
            self.address.any.family,
            posix.SOCK.STREAM,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(sock);

        // Allow address reuse
        posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

        try posix.bind(sock, &self.address.any, self.address.getOsSockLen());
        try posix.listen(sock, 128);

        self.listener = sock;
        self.running = true;

        self.app.logger.info("Server listening on {s}:{d}", .{
            "0.0.0.0",
            self.address.getPort(),
        });

        // Accept loop
        while (self.running) {
            self.acceptConnection() catch |e| {
                self.app.logger.err("Accept error: {s}", .{@errorName(e)});
                continue;
            };
        }
    }

    fn acceptConnection(self: *Self) !void {
        const listener = self.listener orelse return error.NotListening;

        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client = try posix.accept(listener, &client_addr, &addr_len, 0);
        defer posix.close(client);

        self.handleConnection(client) catch |e| {
            self.app.logger.err("Connection error: {s}", .{@errorName(e)});
        };
    }

    fn handleConnection(self: *Self, client: posix.socket_t) !void {
        var buf: [8192]u8 = undefined;
        const bytes_read = try posix.read(client, &buf);

        if (bytes_read == 0) return;

        const request_data = buf[0..bytes_read];

        // Parse request
        var request = try self.parseRequest(request_data);
        defer request.deinit();

        var response = Response.init(self.app.allocator);
        defer response.deinit();

        // Handle the request
        self.app.handleRequest(&request, &response);

        // Send response
        const response_bytes = try response.build();
        defer self.app.allocator.free(response_bytes);

        _ = try posix.write(client, response_bytes);
    }

    fn parseRequest(self: *Self, data: []const u8) !Request {
        var lines = std.mem.splitSequence(u8, data, "\r\n");

        // Parse request line
        const request_line = lines.next() orelse return error.InvalidRequest;
        var parts = std.mem.splitScalar(u8, request_line, ' ');

        const method_str = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;

        const method = Method.fromString(method_str) orelse return error.InvalidMethod;

        var request = Request.init(self.app.allocator, method, path);
        errdefer request.deinit();

        // Parse headers
        while (lines.next()) |line| {
            if (line.len == 0) break;

            if (std.mem.indexOf(u8, line, ": ")) |colon_idx| {
                const name = line[0..colon_idx];
                const value = line[colon_idx + 2 ..];
                try request.headers.set(name, value);
            }
        }

        // Rest is body
        const body_start = std.mem.indexOf(u8, data, "\r\n\r\n");
        if (body_start) |start| {
            const body = data[start + 4 ..];
            if (body.len > 0) {
                request.body = body;
            }
        }

        return request;
    }

    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.listener) |sock| {
            posix.close(sock);
            self.listener = null;
        }
    }
};

// ============================================================================
// Application - The main entry point
// ============================================================================

pub const Application = struct {
    allocator: std.mem.Allocator,
    router: Router,
    container: Container,
    config: Config,
    events: EventEmitter,
    logger: Logger,
    error_handler: ErrorHandler,
    providers: std.ArrayListUnmanaged(ServiceProvider),
    booted: bool,

    // Application metadata
    name: []const u8,
    version: []const u8,
    environment: []const u8,

    const Self = @This();

    /// Create a new application instance
    pub fn init(allocator: std.mem.Allocator) Self {
        var logger = Logger.init(allocator);

        return .{
            .allocator = allocator,
            .router = Router.init(allocator),
            .container = Container.init(allocator),
            .config = Config.init(allocator),
            .events = EventEmitter.init(allocator),
            .logger = logger,
            .error_handler = ErrorHandler.init(allocator, &logger),
            .providers = .empty,
            .booted = false,
            .name = "Home App",
            .version = "1.0.0",
            .environment = "development",
        };
    }

    pub fn deinit(self: *Self) void {
        self.router.deinit();
        self.container.deinit();
        self.config.deinit();
        self.events.deinit();
        self.error_handler.deinit();
        self.providers.deinit(self.allocator);
    }

    /// Set application name
    pub fn setName(self: *Self, name: []const u8) *Self {
        self.name = name;
        return self;
    }

    /// Set application version
    pub fn setVersion(self: *Self, version: []const u8) *Self {
        self.version = version;
        return self;
    }

    /// Set environment
    pub fn setEnvironment(self: *Self, env: []const u8) *Self {
        self.environment = env;
        return self;
    }

    /// Check if running in production
    pub fn isProduction(self: *const Self) bool {
        return std.mem.eql(u8, self.environment, "production") or
            std.mem.eql(u8, self.environment, "prod");
    }

    /// Check if running in development
    pub fn isDevelopment(self: *const Self) bool {
        return std.mem.eql(u8, self.environment, "development") or
            std.mem.eql(u8, self.environment, "dev");
    }

    // ========================================================================
    // Configuration
    // ========================================================================

    /// Configure the application
    pub fn configure(self: *Self, f: *const fn (*Config) anyerror!void) !*Self {
        try f(&self.config);
        return self;
    }

    /// Set a config value
    pub fn set(self: *Self, key: []const u8, value: ConfigValue) !*Self {
        try self.config.set(key, value);
        return self;
    }

    /// Get a config value
    pub fn getConfig(self: *const Self, key: []const u8) ?ConfigValue {
        return self.config.get(key);
    }

    // ========================================================================
    // Service Container
    // ========================================================================

    /// Register a singleton service
    pub fn singleton(self: *Self, comptime T: type, instance: *T) !*Self {
        try self.container.singleton(T, instance);
        return self;
    }

    /// Register a service factory
    pub fn register(self: *Self, comptime T: type, factory: *const fn (*Container) anyerror!*T) !*Self {
        try self.container.register(T, factory);
        return self;
    }

    /// Resolve a service
    pub fn resolve(self: *Self, comptime T: type) ?*T {
        return self.container.resolve(T);
    }

    // ========================================================================
    // Service Providers
    // ========================================================================

    /// Register a service provider
    pub fn provider(self: *Self, p: ServiceProvider) !*Self {
        try self.providers.append(self.allocator, p);
        return self;
    }

    /// Boot all providers
    pub fn boot(self: *Self) !void {
        if (self.booted) return;

        // Register phase
        for (self.providers.items) |p| {
            if (p.register_fn) |register_fn| {
                try register_fn(self);
            }
        }

        // Boot phase
        for (self.providers.items) |p| {
            if (p.boot_fn) |boot_fn| {
                try boot_fn(self);
            }
        }

        self.booted = true;
        self.events.emit("app.booted", @ptrCast(self));
    }

    // ========================================================================
    // Routing
    // ========================================================================

    /// Add global middleware
    pub fn use(self: *Self, middleware: MiddlewareFn) !*Self {
        try self.router.use(middleware);
        return self;
    }

    /// Register a GET route
    pub fn get(self: *Self, pattern: []const u8, handler: HandlerFn) !*Self {
        try self.router.get(pattern, handler);
        return self;
    }

    /// Register a POST route
    pub fn post(self: *Self, pattern: []const u8, handler: HandlerFn) !*Self {
        try self.router.post(pattern, handler);
        return self;
    }

    /// Register a PUT route
    pub fn put(self: *Self, pattern: []const u8, handler: HandlerFn) !*Self {
        try self.router.put(pattern, handler);
        return self;
    }

    /// Register a DELETE route
    pub fn delete(self: *Self, pattern: []const u8, handler: HandlerFn) !*Self {
        try self.router.delete(pattern, handler);
        return self;
    }

    /// Register a PATCH route
    pub fn patch(self: *Self, pattern: []const u8, handler: HandlerFn) !*Self {
        try self.router.patch(pattern, handler);
        return self;
    }

    /// Register an OPTIONS route
    pub fn options(self: *Self, pattern: []const u8, handler: HandlerFn) !*Self {
        try self.router.options(pattern, handler);
        return self;
    }

    /// Create a route group
    pub fn group(self: *Self, prefix: []const u8) !*RouteGroup {
        return self.router.group(prefix);
    }

    /// Set 404 handler
    pub fn notFound(self: *Self, handler: HandlerFn) *Self {
        self.router.notFound(handler);
        return self;
    }

    // ========================================================================
    // Events
    // ========================================================================

    /// Register an event listener
    pub fn on(self: *Self, event: []const u8, listener: EventListener) !*Self {
        try self.events.on(event, listener);
        return self;
    }

    /// Emit an event
    pub fn emit(self: *Self, event: []const u8, data: *anyopaque) void {
        self.events.emit(event, data);
    }

    // ========================================================================
    // Error Handling
    // ========================================================================

    /// Register an error handler
    pub fn onError(self: *Self, handler: *const fn (anyerror, *Context) void) !*Self {
        try self.error_handler.register(handler);
        return self;
    }

    // ========================================================================
    // Request Handling
    // ========================================================================

    /// Handle an incoming request
    pub fn handleRequest(self: *Self, request: *Request, response: *Response) void {
        var ctx = Context.init(self.allocator, request, response, self);
        defer ctx.deinit();

        // Match route
        var match_result = self.router.match(request.method, request.path);
        defer {
            if (match_result) |*m| {
                m.params.deinit();
            }
        }

        if (match_result) |*m| {
            // Copy params to request
            var iter = m.params.iterator();
            while (iter.next()) |entry| {
                request.params.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }

            // Set up middleware chain
            ctx._middlewares = self.router.global_middlewares.items;
            ctx._handler = m.route.handler;

            // Execute middleware chain
            ctx.next() catch |e| {
                self.error_handler.handle(e, &ctx);
            };
        } else {
            // 404
            if (self.router.not_found_handler) |handler| {
                handler(&ctx) catch |e| {
                    self.error_handler.handle(e, &ctx);
                };
            } else {
                _ = response.setStatus(.not_found);
                response.text("Not Found") catch {};
            }
        }
    }

    // ========================================================================
    // Server
    // ========================================================================

    /// Create and start an HTTP server
    pub fn listen(self: *Self, host: []const u8, port: u16) !void {
        try self.boot();

        var server = try Server.init(self, host, port);
        try server.listen();
    }

    /// Run the application (alias for listen with defaults)
    pub fn run(self: *Self) !void {
        const host = self.config.getString("server.host") orelse "0.0.0.0";
        const port: u16 = if (self.config.getInt("server.port")) |p| @intCast(p) else 3000;

        try self.listen(host, port);
    }
};

// ============================================================================
// Builder Pattern for Fluent Configuration
// ============================================================================

pub const AppBuilder = struct {
    app: *Application,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const app = try allocator.create(Application);
        app.* = Application.init(allocator);
        return .{ .app = app };
    }

    pub fn name(self: *Self, n: []const u8) *Self {
        _ = self.app.setName(n);
        return self;
    }

    pub fn version(self: *Self, v: []const u8) *Self {
        _ = self.app.setVersion(v);
        return self;
    }

    pub fn environment(self: *Self, env: []const u8) *Self {
        _ = self.app.setEnvironment(env);
        return self;
    }

    pub fn configure(self: *Self, f: *const fn (*Config) anyerror!void) !*Self {
        _ = try self.app.configure(f);
        return self;
    }

    pub fn use(self: *Self, middleware: MiddlewareFn) !*Self {
        _ = try self.app.use(middleware);
        return self;
    }

    pub fn provider(self: *Self, p: ServiceProvider) !*Self {
        _ = try self.app.provider(p);
        return self;
    }

    pub fn routes(self: *Self, f: *const fn (*Router) anyerror!void) !*Self {
        try f(&self.app.router);
        return self;
    }

    pub fn build(self: *Self) *Application {
        return self.app;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "method from string" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try std.testing.expect(Method.fromString("INVALID") == null);
}

test "status phrases" {
    try std.testing.expectEqualStrings("OK", Status.ok.phrase());
    try std.testing.expectEqualStrings("Not Found", Status.not_found.phrase());
    try std.testing.expectEqualStrings("Internal Server Error", Status.internal_server_error.phrase());
}

test "headers" {
    const allocator = std.testing.allocator;

    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "application/json");
    try headers.set("X-Custom", "value");

    try std.testing.expectEqualStrings("application/json", headers.get("content-type").?);
    try std.testing.expectEqualStrings("value", headers.get("x-custom").?);
    try std.testing.expect(headers.has("Content-Type"));
}

test "request initialization" {
    const allocator = std.testing.allocator;

    var request = Request.init(allocator, .GET, "/users?page=1&limit=10");
    defer request.deinit();

    try std.testing.expectEqual(Method.GET, request.method);
    try std.testing.expectEqualStrings("/users", request.path);
    try std.testing.expectEqualStrings("page=1&limit=10", request.query_string.?);
}

test "response builder" {
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();

    _ = response.setStatus(.created);
    _ = try response.setHeader("Content-Type", "application/json");
    _ = try response.write("{\"id\": 1}");

    try std.testing.expectEqual(Status.created, response.status);

    const built = try response.build();
    defer allocator.free(built);

    try std.testing.expect(std.mem.indexOf(u8, built, "201 Created") != null);
}

test "router matching" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle;

    try router.get("/users", handler);
    try router.get("/users/:id", handler);
    try router.post("/users", handler);

    // Test exact match
    const match1 = router.match(.GET, "/users");
    try std.testing.expect(match1 != null);

    // Test param match
    var match2 = router.match(.GET, "/users/123");
    try std.testing.expect(match2 != null);
    if (match2) |*m| {
        defer m.params.deinit();
        try std.testing.expectEqualStrings("123", m.params.get("id").?);
    }

    // Test method mismatch
    const match3 = router.match(.DELETE, "/users");
    try std.testing.expect(match3 == null);
}

test "route groups" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle;

    const api = try router.group("/api/v1");

    try api.get("/users", handler);
    try api.post("/users", handler);

    const match1 = router.match(.GET, "/api/v1/users");
    try std.testing.expect(match1 != null);

    const match2 = router.match(.GET, "/users");
    try std.testing.expect(match2 == null);
}

test "service container" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const TestService = struct {
        value: i32,
    };

    var service = TestService{ .value = 42 };
    try container.singleton(TestService, &service);

    const resolved = container.resolve(TestService);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqual(@as(i32, 42), resolved.?.value);
}

test "configuration" {
    const allocator = std.testing.allocator;

    var config = Config.init(allocator);
    defer config.deinit();

    try config.set("name", .{ .string = "TestApp" });
    try config.set("debug", .{ .boolean = true });
    try config.set("port", .{ .integer = 8080 });

    try std.testing.expectEqualStrings("TestApp", config.getString("name").?);
    try std.testing.expectEqual(true, config.getBool("debug").?);
    try std.testing.expectEqual(@as(i64, 8080), config.getInt("port").?);
}

test "event emitter" {
    const allocator = std.testing.allocator;

    var emitter = EventEmitter.init(allocator);
    defer emitter.deinit();

    var called: bool = false;

    const listener = struct {
        fn handle(data: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(data));
            ptr.* = true;
        }
    }.handle;

    try emitter.on("test.event", listener);
    emitter.emit("test.event", @ptrCast(&called));

    try std.testing.expect(called);
}

test "application initialization" {
    const allocator = std.testing.allocator;

    var app = Application.init(allocator);
    defer app.deinit();

    _ = app.setName("TestApp");
    _ = app.setVersion("1.0.0");
    _ = app.setEnvironment("development");

    try std.testing.expectEqualStrings("TestApp", app.name);
    try std.testing.expectEqualStrings("1.0.0", app.version);
    try std.testing.expect(app.isDevelopment());
    try std.testing.expect(!app.isProduction());
}

test "application routing" {
    const allocator = std.testing.allocator;

    var app = Application.init(allocator);
    defer app.deinit();

    const handler = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.text("Hello, World!");
        }
    }.handle;

    _ = try app.get("/", handler);
    _ = try app.get("/users/:id", handler);

    // Test request handling
    var request = Request.init(allocator, .GET, "/");
    defer request.deinit();

    var response = Response.init(allocator);
    defer response.deinit();

    app.handleRequest(&request, &response);

    try std.testing.expectEqual(Status.ok, response.status);
}

test "middleware chain" {
    const allocator = std.testing.allocator;

    var app = Application.init(allocator);
    defer app.deinit();

    const middleware1 = struct {
        fn handle(ctx: *Context) anyerror!void {
            _ = try ctx.response.setHeader("X-Middleware-1", "true");
            try ctx.next();
        }
    }.handle;

    const middleware2 = struct {
        fn handle(ctx: *Context) anyerror!void {
            _ = try ctx.response.setHeader("X-Middleware-2", "true");
            try ctx.next();
        }
    }.handle;

    const handler = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.text("Done");
        }
    }.handle;

    _ = try app.use(middleware1);
    _ = try app.use(middleware2);
    _ = try app.get("/test", handler);

    var request = Request.init(allocator, .GET, "/test");
    defer request.deinit();

    var response = Response.init(allocator);
    defer response.deinit();

    app.handleRequest(&request, &response);

    try std.testing.expect(response.headers.has("X-Middleware-1"));
    try std.testing.expect(response.headers.has("X-Middleware-2"));
}

test "app builder" {
    const allocator = std.testing.allocator;

    var builder = try AppBuilder.init(allocator);
    _ = builder.name("MyApp").version("2.0.0").environment("production");

    const app = builder.build();
    defer {
        app.deinit();
        allocator.destroy(app);
    }

    try std.testing.expectEqualStrings("MyApp", app.name);
    try std.testing.expectEqualStrings("2.0.0", app.version);
    try std.testing.expect(app.isProduction());
}

test "cookie options" {
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();

    try response.setCookie("session", "abc123", .{
        .max_age = 3600,
        .path = "/",
        .http_only = true,
        .secure = true,
        .same_site = "Strict",
    });

    const cookie_header = response.headers.get("set-cookie").?;
    try std.testing.expect(std.mem.indexOf(u8, cookie_header, "session=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie_header, "Max-Age=3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie_header, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie_header, "Secure") != null);
}
