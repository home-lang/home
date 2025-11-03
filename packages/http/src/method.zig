const std = @import("std");

/// HTTP request methods as defined in RFC 7231
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,

    /// Parse an HTTP method from a string
    pub fn fromString(str: []const u8) ?Method {
        if (std.mem.eql(u8, str, "GET")) return .GET;
        if (std.mem.eql(u8, str, "POST")) return .POST;
        if (std.mem.eql(u8, str, "PUT")) return .PUT;
        if (std.mem.eql(u8, str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, str, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, str, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, str, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, str, "TRACE")) return .TRACE;
        if (std.mem.eql(u8, str, "CONNECT")) return .CONNECT;
        return null;
    }

    /// Convert HTTP method to string
    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
        };
    }

    /// Check if method is safe (read-only, cacheable)
    pub fn isSafe(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .OPTIONS, .TRACE => true,
            else => false,
        };
    }

    /// Check if method is idempotent (same effect when repeated)
    pub fn isIdempotent(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE => true,
            else => false,
        };
    }
};

/// HTTP status codes
pub const Status = enum(u16) {
    // 1xx Informational
    Continue = 100,
    SwitchingProtocols = 101,
    Processing = 102,

    // 2xx Success
    OK = 200,
    Created = 201,
    Accepted = 202,
    NoContent = 204,
    ResetContent = 205,
    PartialContent = 206,

    // 3xx Redirection
    MultipleChoices = 300,
    MovedPermanently = 301,
    Found = 302,
    SeeOther = 303,
    NotModified = 304,
    TemporaryRedirect = 307,
    PermanentRedirect = 308,

    // 4xx Client Errors
    BadRequest = 400,
    Unauthorized = 401,
    PaymentRequired = 402,
    Forbidden = 403,
    NotFound = 404,
    MethodNotAllowed = 405,
    NotAcceptable = 406,
    RequestTimeout = 408,
    Conflict = 409,
    Gone = 410,
    LengthRequired = 411,
    PreconditionFailed = 412,
    PayloadTooLarge = 413,
    URITooLong = 414,
    UnsupportedMediaType = 415,
    RangeNotSatisfiable = 416,
    ExpectationFailed = 417,
    ImATeapot = 418,
    UnprocessableEntity = 422,
    TooManyRequests = 429,

    // 5xx Server Errors
    InternalServerError = 500,
    NotImplemented = 501,
    BadGateway = 502,
    ServiceUnavailable = 503,
    GatewayTimeout = 504,
    HTTPVersionNotSupported = 505,

    /// Get the reason phrase for this status code
    pub fn reasonPhrase(self: Status) []const u8 {
        return switch (self) {
            .Continue => "Continue",
            .SwitchingProtocols => "Switching Protocols",
            .Processing => "Processing",
            .OK => "OK",
            .Created => "Created",
            .Accepted => "Accepted",
            .NoContent => "No Content",
            .ResetContent => "Reset Content",
            .PartialContent => "Partial Content",
            .MultipleChoices => "Multiple Choices",
            .MovedPermanently => "Moved Permanently",
            .Found => "Found",
            .SeeOther => "See Other",
            .NotModified => "Not Modified",
            .TemporaryRedirect => "Temporary Redirect",
            .PermanentRedirect => "Permanent Redirect",
            .BadRequest => "Bad Request",
            .Unauthorized => "Unauthorized",
            .PaymentRequired => "Payment Required",
            .Forbidden => "Forbidden",
            .NotFound => "Not Found",
            .MethodNotAllowed => "Method Not Allowed",
            .NotAcceptable => "Not Acceptable",
            .RequestTimeout => "Request Timeout",
            .Conflict => "Conflict",
            .Gone => "Gone",
            .LengthRequired => "Length Required",
            .PreconditionFailed => "Precondition Failed",
            .PayloadTooLarge => "Payload Too Large",
            .URITooLong => "URI Too Long",
            .UnsupportedMediaType => "Unsupported Media Type",
            .RangeNotSatisfiable => "Range Not Satisfiable",
            .ExpectationFailed => "Expectation Failed",
            .ImATeapot => "I'm a teapot",
            .UnprocessableEntity => "Unprocessable Entity",
            .TooManyRequests => "Too Many Requests",
            .InternalServerError => "Internal Server Error",
            .NotImplemented => "Not Implemented",
            .BadGateway => "Bad Gateway",
            .ServiceUnavailable => "Service Unavailable",
            .GatewayTimeout => "Gateway Timeout",
            .HTTPVersionNotSupported => "HTTP Version Not Supported",
        };
    }

    /// Check if status code indicates success (2xx)
    pub fn isSuccess(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 200 and code < 300;
    }

    /// Check if status code indicates redirection (3xx)
    pub fn isRedirect(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 300 and code < 400;
    }

    /// Check if status code indicates client error (4xx)
    pub fn isClientError(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 400 and code < 500;
    }

    /// Check if status code indicates server error (5xx)
    pub fn isServerError(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 500 and code < 600;
    }
};

/// HTTP version
pub const Version = enum {
    HTTP_1_0,
    HTTP_1_1,
    HTTP_2_0,
    HTTP_3_0,

    pub fn fromString(str: []const u8) ?Version {
        if (std.mem.eql(u8, str, "HTTP/1.0")) return .HTTP_1_0;
        if (std.mem.eql(u8, str, "HTTP/1.1")) return .HTTP_1_1;
        if (std.mem.eql(u8, str, "HTTP/2.0") or std.mem.eql(u8, str, "HTTP/2")) return .HTTP_2_0;
        if (std.mem.eql(u8, str, "HTTP/3.0") or std.mem.eql(u8, str, "HTTP/3")) return .HTTP_3_0;
        return null;
    }

    pub fn toString(self: Version) []const u8 {
        return switch (self) {
            .HTTP_1_0 => "HTTP/1.0",
            .HTTP_1_1 => "HTTP/1.1",
            .HTTP_2_0 => "HTTP/2.0",
            .HTTP_3_0 => "HTTP/3.0",
        };
    }
};

test "Method from string" {
    const testing = std.testing;
    try testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try testing.expectEqual(@as(?Method, null), Method.fromString("INVALID"));
}

test "Method properties" {
    const testing = std.testing;
    try testing.expect(Method.GET.isSafe());
    try testing.expect(!Method.POST.isSafe());
    try testing.expect(Method.PUT.isIdempotent());
    try testing.expect(!Method.POST.isIdempotent());
}

test "Status code helpers" {
    const testing = std.testing;
    try testing.expect(Status.OK.isSuccess());
    try testing.expect(Status.Found.isRedirect());
    try testing.expect(Status.NotFound.isClientError());
    try testing.expect(Status.InternalServerError.isServerError());
}
