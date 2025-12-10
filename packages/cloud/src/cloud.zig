const std = @import("std");
const posix = std.posix;

// Re-export AWS services (runtime clients)
pub const sqs = @import("sqs.zig");
pub const ses = @import("ses.zig");
pub const sns = @import("sns.zig");
pub const dynamodb = @import("dynamodb.zig");
pub const s3 = @import("s3.zig");

// Re-export CloudFormation infrastructure-as-code modules
pub const cloudformation = @import("cloudformation.zig");
pub const resources = @import("resources/resources.zig");
pub const presets = @import("presets.zig");

// Convenience re-exports for CloudFormation
pub const Builder = cloudformation.Builder;
pub const Template = cloudformation.Template;
pub const CfValue = cloudformation.CfValue;
pub const Fn = cloudformation.Fn;
pub const Resource = cloudformation.Resource;
pub const Parameter = cloudformation.Parameter;
pub const Output = cloudformation.Output;

// Resource modules
pub const Storage = resources.Storage;
pub const Compute = resources.Compute;
pub const Database = resources.Database;
pub const Network = resources.Network;

// Presets
pub const Presets = presets.Presets;

/// AWS region definitions
pub const Region = enum {
    us_east_1,
    us_east_2,
    us_west_1,
    us_west_2,
    eu_west_1,
    eu_west_2,
    eu_west_3,
    eu_central_1,
    eu_north_1,
    ap_northeast_1,
    ap_northeast_2,
    ap_southeast_1,
    ap_southeast_2,
    ap_south_1,
    sa_east_1,
    ca_central_1,

    pub fn toString(self: Region) []const u8 {
        return switch (self) {
            .us_east_1 => "us-east-1",
            .us_east_2 => "us-east-2",
            .us_west_1 => "us-west-1",
            .us_west_2 => "us-west-2",
            .eu_west_1 => "eu-west-1",
            .eu_west_2 => "eu-west-2",
            .eu_west_3 => "eu-west-3",
            .eu_central_1 => "eu-central-1",
            .eu_north_1 => "eu-north-1",
            .ap_northeast_1 => "ap-northeast-1",
            .ap_northeast_2 => "ap-northeast-2",
            .ap_southeast_1 => "ap-southeast-1",
            .ap_southeast_2 => "ap-southeast-2",
            .ap_south_1 => "ap-south-1",
            .sa_east_1 => "sa-east-1",
            .ca_central_1 => "ca-central-1",
        };
    }

    pub fn fromString(s: []const u8) ?Region {
        const map = std.StaticStringMap(Region).initComptime(.{
            .{ "us-east-1", .us_east_1 },
            .{ "us-east-2", .us_east_2 },
            .{ "us-west-1", .us_west_1 },
            .{ "us-west-2", .us_west_2 },
            .{ "eu-west-1", .eu_west_1 },
            .{ "eu-west-2", .eu_west_2 },
            .{ "eu-west-3", .eu_west_3 },
            .{ "eu-central-1", .eu_central_1 },
            .{ "eu-north-1", .eu_north_1 },
            .{ "ap-northeast-1", .ap_northeast_1 },
            .{ "ap-northeast-2", .ap_northeast_2 },
            .{ "ap-southeast-1", .ap_southeast_1 },
            .{ "ap-southeast-2", .ap_southeast_2 },
            .{ "ap-south-1", .ap_south_1 },
            .{ "sa-east-1", .sa_east_1 },
            .{ "ca-central-1", .ca_central_1 },
        });
        return map.get(s);
    }
};

/// AWS credentials
pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,

    pub fn init(access_key_id: []const u8, secret_access_key: []const u8) Credentials {
        return .{
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
        };
    }

    pub fn withSessionToken(access_key_id: []const u8, secret_access_key: []const u8, session_token: []const u8) Credentials {
        return .{
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
            .session_token = session_token,
        };
    }

    /// Load credentials from environment variables
    pub fn fromEnvironment() ?Credentials {
        const access_key = std.posix.getenv("AWS_ACCESS_KEY_ID") orelse return null;
        const secret_key = std.posix.getenv("AWS_SECRET_ACCESS_KEY") orelse return null;
        const session_token = std.posix.getenv("AWS_SESSION_TOKEN");

        return .{
            .access_key_id = access_key,
            .secret_access_key = secret_key,
            .session_token = session_token,
        };
    }
};

/// AWS client configuration
pub const Config = struct {
    credentials: Credentials,
    region: Region,
    endpoint: ?[]const u8 = null, // Override for local testing

    pub fn init(credentials: Credentials, region: Region) Config {
        return .{
            .credentials = credentials,
            .region = region,
        };
    }

    pub fn withEndpoint(credentials: Credentials, region: Region, endpoint: []const u8) Config {
        return .{
            .credentials = credentials,
            .region = region,
            .endpoint = endpoint,
        };
    }
};

/// AWS Signature Version 4 signing
pub const Signer = struct {
    allocator: std.mem.Allocator,
    credentials: Credentials,
    region: []const u8,
    service: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, credentials: Credentials, region: []const u8, service: []const u8) Self {
        return .{
            .allocator = allocator,
            .credentials = credentials,
            .region = region,
            .service = service,
        };
    }

    /// Sign a request with AWS Signature Version 4
    pub fn sign(
        self: *Self,
        method: []const u8,
        uri: []const u8,
        query: []const u8,
        headers: []const [2][]const u8,
        payload: []const u8,
        timestamp: i64,
    ) !SignedRequest {
        var datetime_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;

        const datetime = formatIso8601(&datetime_buf, timestamp);
        const date = datetime[0..8];
        @memcpy(&date_buf, date);

        // Create canonical request
        var canonical: std.ArrayList(u8) = .empty;
        defer canonical.deinit(self.allocator);
        const cw = canonical.writer(self.allocator);

        // Method
        try cw.writeAll(method);
        try cw.writeAll("\n");

        // URI
        try cw.writeAll(uri);
        try cw.writeAll("\n");

        // Query string
        try cw.writeAll(query);
        try cw.writeAll("\n");

        // Canonical headers (sorted by name)
        var header_names: std.ArrayList([]const u8) = .empty;
        defer header_names.deinit(self.allocator);

        for (headers) |h| {
            try header_names.append(self.allocator, h[0]);
        }

        // Sort headers
        std.mem.sort([]const u8, header_names.items, {}, struct {
            pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.lessThan);

        // Write canonical headers
        for (header_names.items) |name| {
            for (headers) |h| {
                if (std.ascii.eqlIgnoreCase(h[0], name)) {
                    try cw.writeAll(toLower(self.allocator, name) catch name);
                    try cw.writeAll(":");
                    try cw.writeAll(h[1]);
                    try cw.writeAll("\n");
                    break;
                }
            }
        }
        try cw.writeAll("\n");

        // Signed headers
        var signed_headers: std.ArrayList(u8) = .empty;
        defer signed_headers.deinit(self.allocator);
        const shw = signed_headers.writer(self.allocator);

        for (header_names.items, 0..) |name, i| {
            if (i > 0) try shw.writeAll(";");
            try shw.writeAll(toLower(self.allocator, name) catch name);
        }

        try cw.writeAll(signed_headers.items);
        try cw.writeAll("\n");

        // Payload hash
        var payload_hash: [64]u8 = undefined;
        sha256Hex(payload, &payload_hash);
        try cw.writeAll(&payload_hash);

        // Hash the canonical request
        var canonical_hash: [64]u8 = undefined;
        sha256Hex(canonical.items, &canonical_hash);

        // Create string to sign
        var string_to_sign: std.ArrayList(u8) = .empty;
        defer string_to_sign.deinit(self.allocator);
        const stsw = string_to_sign.writer(self.allocator);

        try stsw.writeAll("AWS4-HMAC-SHA256\n");
        try stsw.writeAll(datetime);
        try stsw.writeAll("\n");
        try stsw.print("{s}/{s}/{s}/aws4_request\n", .{ &date_buf, self.region, self.service });
        try stsw.writeAll(&canonical_hash);

        // Calculate signing key
        var k_date: [32]u8 = undefined;
        var k_region: [32]u8 = undefined;
        var k_service: [32]u8 = undefined;
        var k_signing: [32]u8 = undefined;

        var key_buf: [256]u8 = undefined;
        const aws4_key = std.fmt.bufPrint(&key_buf, "AWS4{s}", .{self.credentials.secret_access_key}) catch return error.KeyTooLong;

        hmacSha256(aws4_key, &date_buf, &k_date);
        hmacSha256(&k_date, self.region, &k_region);
        hmacSha256(&k_region, self.service, &k_service);
        hmacSha256(&k_service, "aws4_request", &k_signing);

        // Calculate signature
        var signature: [32]u8 = undefined;
        hmacSha256(&k_signing, string_to_sign.items, &signature);

        var signature_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&signature_hex, "{}", .{std.fmt.fmtSliceHexLower(&signature)}) catch {};

        // Build authorization header
        var auth_header: std.ArrayList(u8) = .empty;
        const ahw = auth_header.writer(self.allocator);

        try ahw.print("AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders={s}, Signature={s}", .{
            self.credentials.access_key_id,
            &date_buf,
            self.region,
            self.service,
            signed_headers.items,
            &signature_hex,
        });

        return SignedRequest{
            .authorization = try auth_header.toOwnedSlice(self.allocator),
            .x_amz_date = try self.allocator.dupe(u8, datetime),
            .x_amz_content_sha256 = try self.allocator.dupe(u8, &payload_hash),
            .allocator = self.allocator,
        };
    }

    fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        var lower = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }
        return lower;
    }

    fn formatIso8601(buf: *[16]u8, timestamp: i64) []const u8 {
        const epoch_secs: u64 = @intCast(timestamp);
        const days_since_epoch = epoch_secs / 86400;
        const time_of_day = epoch_secs % 86400;

        // Calculate date (simplified)
        var year: u32 = 1970;
        var remaining_days = days_since_epoch;

        while (remaining_days >= 365) {
            const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
            const year_days: u32 = if (is_leap) 366 else 365;
            if (remaining_days < year_days) break;
            remaining_days -= year_days;
            year += 1;
        }

        const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
        const days_per_month = if (is_leap)
            [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var month: u32 = 1;
        for (days_per_month) |dm| {
            if (remaining_days < dm) break;
            remaining_days -= dm;
            month += 1;
        }
        const day = @as(u32, @intCast(remaining_days)) + 1;

        const hour = @as(u32, @intCast(time_of_day / 3600));
        const minute = @as(u32, @intCast((time_of_day % 3600) / 60));
        const second = @as(u32, @intCast(time_of_day % 60));

        _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ year, month, day, hour, minute, second }) catch {};
        return buf;
    }

    fn sha256Hex(data: []const u8, out: *[64]u8) void {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
        _ = std.fmt.bufPrint(out, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch {};
    }

    fn hmacSha256(key: []const u8, data: []const u8, out: *[32]u8) void {
        var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
        mac.update(data);
        mac.final(out);
    }
};

/// Result of signing a request
pub const SignedRequest = struct {
    authorization: []const u8,
    x_amz_date: []const u8,
    x_amz_content_sha256: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SignedRequest) void {
        self.allocator.free(self.authorization);
        self.allocator.free(self.x_amz_date);
        self.allocator.free(self.x_amz_content_sha256);
    }
};

/// HTTP client for AWS services
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    socket: ?posix.socket_t = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.socket) |sock| {
            posix.close(sock);
        }
    }

    pub fn request(
        self: *Self,
        method: []const u8,
        host: []const u8,
        port: u16,
        path: []const u8,
        headers: []const [2][]const u8,
        body: []const u8,
    ) !Response {
        // Create socket
        const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return error.SocketError;
        defer posix.close(sock);

        // Connect (simplified - would need DNS resolution for real implementation)
        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0x0100007F, // 127.0.0.1 placeholder
        };

        posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch return error.ConnectionFailed;

        // Build HTTP request
        var req_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        pos += (std.fmt.bufPrint(req_buf[pos..], "{s} {s} HTTP/1.1\r\n", .{ method, path }) catch return error.BufferOverflow).len;
        pos += (std.fmt.bufPrint(req_buf[pos..], "Host: {s}\r\n", .{host}) catch return error.BufferOverflow).len;
        pos += (std.fmt.bufPrint(req_buf[pos..], "Content-Length: {d}\r\n", .{body.len}) catch return error.BufferOverflow).len;

        for (headers) |h| {
            pos += (std.fmt.bufPrint(req_buf[pos..], "{s}: {s}\r\n", .{ h[0], h[1] }) catch return error.BufferOverflow).len;
        }

        pos += (std.fmt.bufPrint(req_buf[pos..], "\r\n", .{}) catch return error.BufferOverflow).len;

        // Send request
        _ = posix.send(sock, req_buf[0..pos], 0) catch return error.SendFailed;

        if (body.len > 0) {
            _ = posix.send(sock, body, 0) catch return error.SendFailed;
        }

        // Read response
        var response_buf: [16384]u8 = undefined;
        const n = posix.recv(sock, &response_buf, 0) catch return error.RecvFailed;

        // Parse response (simplified)
        const response_data = response_buf[0..n];

        // Find status code
        var status: u16 = 0;
        if (std.mem.indexOf(u8, response_data, "HTTP/1.1 ")) |idx| {
            status = std.fmt.parseInt(u16, response_data[idx + 9 .. idx + 12], 10) catch 0;
        }

        // Find body start
        var response_body: []const u8 = "";
        if (std.mem.indexOf(u8, response_data, "\r\n\r\n")) |body_start| {
            response_body = response_data[body_start + 4 ..];
        }

        return Response{
            .status = status,
            .body = try self.allocator.dupe(u8, response_body),
            .allocator = self.allocator,
        };
    }
};

/// HTTP response
pub const Response = struct {
    status: u16,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }

    pub fn isSuccess(self: *const Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

/// AWS error types
pub const AwsError = error{
    AccessDenied,
    InvalidCredentials,
    ResourceNotFound,
    ServiceUnavailable,
    Throttling,
    ValidationError,
    UnknownError,
    ConnectionFailed,
    SocketError,
    SendFailed,
    RecvFailed,
    BufferOverflow,
    KeyTooLong,
    OutOfMemory,
};

// Tests
test "region toString" {
    try std.testing.expectEqualStrings("us-east-1", Region.us_east_1.toString());
    try std.testing.expectEqualStrings("eu-west-1", Region.eu_west_1.toString());
}

test "region fromString" {
    try std.testing.expectEqual(Region.us_east_1, Region.fromString("us-east-1").?);
    try std.testing.expect(Region.fromString("invalid") == null);
}

test "credentials init" {
    const creds = Credentials.init("access_key", "secret_key");
    try std.testing.expectEqualStrings("access_key", creds.access_key_id);
    try std.testing.expect(creds.session_token == null);
}

test "config init" {
    const creds = Credentials.init("key", "secret");
    const config = Config.init(creds, .us_east_1);
    try std.testing.expectEqual(Region.us_east_1, config.region);
}
