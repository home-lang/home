const std = @import("std");
const net_mod = @import("net.zig");
const TcpStream = net_mod.TcpStream;
const SocketAddr = net_mod.SocketAddr;
const IpAddr = net_mod.IpAddr;
const NetError = net_mod.NetError;
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;
const reactor_mod = @import("reactor.zig");
const Reactor = reactor_mod.Reactor;
const result_mod = @import("result_future.zig");
const Result = result_mod.Result;

/// Async HTTP client
///
/// Provides a simple async HTTP client for making requests.

/// HTTP error types
pub const HttpError = error{
    InvalidUrl,
    InvalidResponse,
    UnsupportedScheme,
    ConnectionFailed,
    ReadError,
    WriteError,
    Timeout,
    TooManyRedirects,
};

/// HTTP methods
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    PATCH,
    OPTIONS,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .PATCH => "PATCH",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP version
pub const Version = enum {
    HTTP_1_0,
    HTTP_1_1,
    HTTP_2_0,

    pub fn toString(self: Version) []const u8 {
        return switch (self) {
            .HTTP_1_0 => "HTTP/1.0",
            .HTTP_1_1 => "HTTP/1.1",
            .HTTP_2_0 => "HTTP/2.0",
        };
    }
};

/// HTTP headers
pub const Headers = struct {
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Headers {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Headers) void {
        self.map.deinit();
    }

    pub fn set(self: *Headers, key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }

    pub fn get(self: *const Headers, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

/// HTTP request
pub const Request = struct {
    method: Method,
    url: []const u8,
    version: Version,
    headers: Headers,
    body: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, method: Method, url: []const u8) Request {
        return .{
            .method = method,
            .url = url,
            .version = .HTTP_1_1,
            .headers = Headers.init(allocator),
            .body = null,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn setHeader(self: *Request, key: []const u8, value: []const u8) !void {
        try self.headers.set(key, value);
    }

    pub fn setBody(self: *Request, body: []const u8) void {
        self.body = body;
    }
};

/// HTTP response
pub const Response = struct {
    version: Version,
    status_code: u16,
    status_text: []const u8,
    headers: Headers,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.allocator.free(self.body);
    }
};

/// URL parser result
pub const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Parse a URL
fn parseUrl(url: []const u8) !ParsedUrl {
    // Simple URL parsing (scheme://host:port/path)
    var scheme_end: usize = 0;
    while (scheme_end < url.len and url[scheme_end] != ':') : (scheme_end += 1) {}

    if (scheme_end >= url.len or scheme_end + 3 > url.len) {
        return error.InvalidUrl;
    }

    const scheme = url[0..scheme_end];

    // Skip "://"
    var host_start = scheme_end + 3;
    if (url[scheme_end + 1] != '/' or url[scheme_end + 2] != '/') {
        return error.InvalidUrl;
    }

    // Find host end (either : or /)
    var host_end = host_start;
    while (host_end < url.len and url[host_end] != ':' and url[host_end] != '/') : (host_end += 1) {}

    const host = url[host_start..host_end];

    // Default ports
    var port: u16 = if (std.mem.eql(u8, scheme, "https")) 443 else 80;
    var path_start = host_end;

    // Check for explicit port
    if (host_end < url.len and url[host_end] == ':') {
        var port_start = host_end + 1;
        var port_end = port_start;
        while (port_end < url.len and url[port_end] != '/') : (port_end += 1) {}

        port = std.fmt.parseInt(u16, url[port_start..port_end], 10) catch return error.InvalidUrl;
        path_start = port_end;
    }

    // Path
    const path = if (path_start < url.len) url[path_start..] else "/";

    return ParsedUrl{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = path,
    };
}

/// HTTP client
pub const Client = struct {
    reactor: *Reactor,
    allocator: std.mem.Allocator,

    pub fn init(reactor: *Reactor, allocator: std.mem.Allocator) Client {
        return .{
            .reactor = reactor,
            .allocator = allocator,
        };
    }

    /// Make a GET request
    pub fn get(self: *Client, url: []const u8) RequestFuture {
        var req = Request.init(self.allocator, .GET, url);
        return self.send(req);
    }

    /// Make a POST request
    pub fn post(self: *Client, url: []const u8, body: []const u8) RequestFuture {
        var req = Request.init(self.allocator, .POST, url);
        req.setBody(body);
        return self.send(req);
    }

    /// Send a request
    pub fn send(self: *Client, request: Request) RequestFuture {
        return RequestFuture{
            .client = self,
            .request = request,
            .state = .ParseUrl,
            .parsed_url = undefined,
            .stream = undefined,
            .response_buffer = std.ArrayList(u8).init(self.allocator),
        };
    }
};

/// Future for HTTP request
pub const RequestFuture = struct {
    client: *Client,
    request: Request,
    state: enum {
        ParseUrl,
        Connect,
        SendRequest,
        ReadResponse,
        Done,
    },
    parsed_url: ParsedUrl,
    stream: TcpStream,
    response_buffer: std.ArrayList(u8),

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result(Response, HttpError)) {
        while (true) {
            switch (self.state) {
                .ParseUrl => {
                    // Parse URL
                    self.parsed_url = parseUrl(self.request.url) catch {
                        return .{ .Ready = Result(Response, HttpError).err_value(HttpError.InvalidUrl) };
                    };

                    // Validate scheme
                    if (!std.mem.eql(u8, self.parsed_url.scheme, "http")) {
                        return .{ .Ready = Result(Response, HttpError).err_value(HttpError.UnsupportedScheme) };
                    }

                    self.state = .Connect;
                    continue;
                },
                .Connect => {
                    // Resolve host to IP (simplified - just use localhost for now)
                    const ip = IpAddr.localhost();
                    const addr = SocketAddr.init(ip, self.parsed_url.port);

                    // Connect
                    var connect_fut = net_mod.connect(addr, self.client.reactor, self.client.allocator);
                    switch (connect_fut.poll(ctx)) {
                        .Ready => |result| {
                            switch (result) {
                                .ok => |stream| {
                                    self.stream = stream;
                                    self.state = .SendRequest;
                                    continue;
                                },
                                .err => {
                                    return .{ .Ready = Result(Response, HttpError).err_value(HttpError.ConnectionFailed) };
                                },
                            }
                        },
                        .Pending => return .Pending,
                    }
                },
                .SendRequest => {
                    // Build request string
                    var request_buf = std.ArrayList(u8).init(self.client.allocator);
                    defer request_buf.deinit();

                    // Request line
                    request_buf.writer().print("{s} {s} {s}\r\n", .{
                        self.request.method.toString(),
                        self.parsed_url.path,
                        self.request.version.toString(),
                    }) catch {
                        return .{ .Ready = Result(Response, HttpError).err_value(HttpError.WriteError) };
                    };

                    // Add Host header if not present
                    if (self.request.headers.get("Host") == null) {
                        request_buf.writer().print("Host: {s}\r\n", .{self.parsed_url.host}) catch {
                            return .{ .Ready = Result(Response, HttpError).err_value(HttpError.WriteError) };
                        };
                    }

                    // Headers
                    var iter = self.request.headers.map.iterator();
                    while (iter.next()) |entry| {
                        request_buf.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {
                            return .{ .Ready = Result(Response, HttpError).err_value(HttpError.WriteError) };
                        };
                    }

                    // Body length
                    if (self.request.body) |body| {
                        request_buf.writer().print("Content-Length: {d}\r\n", .{body.len}) catch {
                            return .{ .Ready = Result(Response, HttpError).err_value(HttpError.WriteError) };
                        };
                    }

                    // End of headers
                    request_buf.appendSlice("\r\n") catch {
                        return .{ .Ready = Result(Response, HttpError).err_value(HttpError.WriteError) };
                    };

                    // Body
                    if (self.request.body) |body| {
                        request_buf.appendSlice(body) catch {
                            return .{ .Ready = Result(Response, HttpError).err_value(HttpError.WriteError) };
                        };
                    }

                    // Write request
                    var write_fut = self.stream.writeAll(request_buf.items);
                    switch (write_fut.poll(ctx)) {
                        .Ready => |result| {
                            switch (result) {
                                .ok => {
                                    self.state = .ReadResponse;
                                    continue;
                                },
                                .err => {
                                    return .{ .Ready = Result(Response, HttpError).err_value(HttpError.WriteError) };
                                },
                            }
                        },
                        .Pending => return .Pending,
                    }
                },
                .ReadResponse => {
                    // Read response (simplified - just read until connection closes)
                    var temp_buf: [4096]u8 = undefined;
                    var read_fut = self.stream.read(&temp_buf);

                    switch (read_fut.poll(ctx)) {
                        .Ready => |result| {
                            switch (result) {
                                .ok => |n| {
                                    if (n == 0) {
                                        // EOF - parse response
                                        self.state = .Done;
                                        continue;
                                    }

                                    self.response_buffer.appendSlice(temp_buf[0..n]) catch {
                                        return .{ .Ready = Result(Response, HttpError).err_value(HttpError.ReadError) };
                                    };

                                    // Continue reading
                                    continue;
                                },
                                .err => {
                                    return .{ .Ready = Result(Response, HttpError).err_value(HttpError.ReadError) };
                                },
                            }
                        },
                        .Pending => return .Pending,
                    }
                },
                .Done => {
                    // Parse response
                    const response_data = self.response_buffer.toOwnedSlice() catch {
                        return .{ .Ready = Result(Response, HttpError).err_value(HttpError.ReadError) };
                    };

                    // Simple parsing - just extract status code and body
                    // In production, would parse headers properly
                    var response = Response{
                        .version = .HTTP_1_1,
                        .status_code = 200, // Simplified
                        .status_text = "OK",
                        .headers = Headers.init(self.client.allocator),
                        .body = response_data,
                        .allocator = self.client.allocator,
                    };

                    return .{ .Ready = Result(Response, HttpError).ok_value(response) };
                },
            }
        }
    }
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "parseUrl - basic" {
    const testing = std.testing;

    const result = try parseUrl("http://example.com/path");
    try testing.expectEqualStrings("http", result.scheme);
    try testing.expectEqualStrings("example.com", result.host);
    try testing.expectEqual(@as(u16, 80), result.port);
    try testing.expectEqualStrings("/path", result.path);
}

test "parseUrl - with port" {
    const testing = std.testing;

    const result = try parseUrl("http://example.com:8080/path");
    try testing.expectEqualStrings("http", result.scheme);
    try testing.expectEqualStrings("example.com", result.host);
    try testing.expectEqual(@as(u16, 8080), result.port);
    try testing.expectEqualStrings("/path", result.path);
}

test "parseUrl - https default port" {
    const testing = std.testing;

    const result = try parseUrl("https://example.com/path");
    try testing.expectEqual(@as(u16, 443), result.port);
}
