const std = @import("std");
const posix = std.posix;

/// Helper to get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// JWT Token structure
pub const Token = struct {
    header: Header,
    payload: Payload,
    signature: []const u8,

    pub const Header = struct {
        alg: Algorithm = .HS256,
        typ: []const u8 = "JWT",
    };

    pub const Payload = struct {
        // Standard claims
        iss: ?[]const u8 = null, // Issuer
        sub: ?[]const u8 = null, // Subject (usually user ID)
        aud: ?[]const u8 = null, // Audience
        exp: ?i64 = null, // Expiration time
        nbf: ?i64 = null, // Not before
        iat: ?i64 = null, // Issued at
        jti: ?[]const u8 = null, // JWT ID

        // Custom claims stored separately
        custom: ?std.StringHashMap([]const u8) = null,
    };

    pub const Algorithm = enum {
        HS256,
        HS384,
        HS512,

        pub fn toString(self: Algorithm) []const u8 {
            return switch (self) {
                .HS256 => "HS256",
                .HS384 => "HS384",
                .HS512 => "HS512",
            };
        }

        pub fn fromString(s: []const u8) ?Algorithm {
            if (std.mem.eql(u8, s, "HS256")) return .HS256;
            if (std.mem.eql(u8, s, "HS384")) return .HS384;
            if (std.mem.eql(u8, s, "HS512")) return .HS512;
            return null;
        }
    };
};

/// JWT Manager for creating and verifying tokens
pub const Jwt = struct {
    allocator: std.mem.Allocator,
    secret: []const u8,
    issuer: ?[]const u8,
    default_ttl: i64, // seconds

    const Self = @This();

    pub const Config = struct {
        secret: []const u8,
        issuer: ?[]const u8 = null,
        default_ttl: i64 = 3600, // 1 hour
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return .{
            .allocator = allocator,
            .secret = config.secret,
            .issuer = config.issuer,
            .default_ttl = config.default_ttl,
        };
    }

    /// Create a JWT token for a subject (usually user ID)
    pub fn create(self: *Self, subject: []const u8) ![]const u8 {
        return self.createWithClaims(subject, null);
    }

    /// Create a JWT token with custom claims
    pub fn createWithClaims(self: *Self, subject: []const u8, custom_claims: ?std.StringHashMap([]const u8)) ![]const u8 {
        const now = getTimestamp();

        // Build header JSON
        const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

        // Build payload JSON
        var payload_buf: [4096]u8 = undefined;
        var pos: usize = 0;

        // Start object
        payload_buf[pos] = '{';
        pos += 1;

        // Subject
        const sub_part = try std.fmt.bufPrint(payload_buf[pos..], "\"sub\":\"{s}\"", .{subject});
        pos += sub_part.len;

        // Issued at
        const iat_part = try std.fmt.bufPrint(payload_buf[pos..], ",\"iat\":{d}", .{now});
        pos += iat_part.len;

        // Expiration
        const exp_part = try std.fmt.bufPrint(payload_buf[pos..], ",\"exp\":{d}", .{now + self.default_ttl});
        pos += exp_part.len;

        // Issuer
        if (self.issuer) |iss| {
            const iss_part = try std.fmt.bufPrint(payload_buf[pos..], ",\"iss\":\"{s}\"", .{iss});
            pos += iss_part.len;
        }

        // Custom claims
        if (custom_claims) |claims| {
            var iter = claims.iterator();
            while (iter.next()) |entry| {
                const claim_part = try std.fmt.bufPrint(payload_buf[pos..], ",\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
                pos += claim_part.len;
            }
        }

        // End object
        payload_buf[pos] = '}';
        pos += 1;

        const payload_json = payload_buf[0..pos];

        // Base64url encode header and payload
        const header_b64 = try base64UrlEncode(self.allocator, header_json);
        defer self.allocator.free(header_b64);

        const payload_b64 = try base64UrlEncode(self.allocator, payload_json);
        defer self.allocator.free(payload_b64);

        // Create signing input
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        // Sign with HMAC-SHA256
        const signature = try self.sign(signing_input);
        defer self.allocator.free(signature);

        // Combine into final token
        return std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature });
    }

    /// Verify and decode a JWT token
    pub fn verify(self: *Self, token: []const u8) !VerifyResult {
        // Split token into parts
        var parts = std.mem.splitScalar(u8, token, '.');

        const header_b64 = parts.next() orelse return error.InvalidToken;
        const payload_b64 = parts.next() orelse return error.InvalidToken;
        const signature_b64 = parts.next() orelse return error.InvalidToken;

        // Verify no extra parts
        if (parts.next() != null) return error.InvalidToken;

        // Verify signature
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        const expected_sig = try self.sign(signing_input);
        defer self.allocator.free(expected_sig);

        if (!std.mem.eql(u8, signature_b64, expected_sig)) {
            return error.InvalidSignature;
        }

        // Decode payload
        const payload_json = try base64UrlDecode(self.allocator, payload_b64);
        defer self.allocator.free(payload_json);

        // Parse payload (simple parsing)
        var result = VerifyResult{
            .valid = true,
            .subject = null,
            .expires_at = null,
            .issued_at = null,
        };

        // Extract subject
        if (extractJsonString(payload_json, "sub")) |sub| {
            result.subject = try self.allocator.dupe(u8, sub);
        }

        // Extract expiration
        if (extractJsonNumber(payload_json, "exp")) |exp| {
            result.expires_at = exp;

            // Check if expired
            const now = getTimestamp();
            if (exp < now) {
                return error.TokenExpired;
            }
        }

        // Extract issued at
        if (extractJsonNumber(payload_json, "iat")) |iat| {
            result.issued_at = iat;
        }

        return result;
    }

    /// Refresh a token (create new one with same subject)
    pub fn refresh(self: *Self, token: []const u8) ![]const u8 {
        const result = try self.verify(token);
        defer if (result.subject) |s| self.allocator.free(s);

        if (result.subject) |subject| {
            return self.create(subject);
        }
        return error.InvalidToken;
    }

    fn sign(self: *Self, data: []const u8) ![]const u8 {
        var mac: [32]u8 = undefined;
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(self.secret);
        hmac.update(data);
        hmac.final(&mac);

        return base64UrlEncode(self.allocator, &mac);
    }
};

pub const VerifyResult = struct {
    valid: bool,
    subject: ?[]const u8,
    expires_at: ?i64,
    issued_at: ?i64,
};

/// Base64url encode (no padding)
fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);

    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, data);
    return encoded;
}

/// Base64url decode
fn base64UrlDecode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(data) catch return error.InvalidEncoding;
    const decoded = try allocator.alloc(u8, decoded_len);

    std.base64.url_safe_no_pad.Decoder.decode(decoded, data) catch return error.InvalidEncoding;
    return decoded;
}

/// Extract a string value from simple JSON
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value"
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;

    const start_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const value_start = start_pos + search.len;

    const value_end = std.mem.indexOfScalarPos(u8, json, value_start, '"') orelse return null;

    return json[value_start..value_end];
}

/// Extract a number value from simple JSON
fn extractJsonNumber(json: []const u8, key: []const u8) ?i64 {
    // Look for "key":number
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const start_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const value_start = start_pos + search.len;

    // Find end of number
    var value_end = value_start;
    while (value_end < json.len) : (value_end += 1) {
        const c = json[value_end];
        if (c != '-' and (c < '0' or c > '9')) break;
    }

    if (value_end == value_start) return null;

    return std.fmt.parseInt(i64, json[value_start..value_end], 10) catch null;
}

// Tests
test "jwt create and verify" {
    const allocator = std.testing.allocator;

    var jwt = Jwt.init(allocator, .{
        .secret = "super-secret-key",
        .issuer = "test-app",
        .default_ttl = 3600,
    });

    // Create token
    const token = try jwt.create("user-123");
    defer allocator.free(token);

    // Verify it has three parts
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next(); // header
    _ = parts.next(); // payload
    _ = parts.next(); // signature
    try std.testing.expect(parts.next() == null);

    // Verify token
    const result = try jwt.verify(token);
    defer if (result.subject) |s| allocator.free(s);

    try std.testing.expect(result.valid);
    try std.testing.expectEqualStrings("user-123", result.subject.?);
    try std.testing.expect(result.expires_at != null);
}

test "jwt invalid signature" {
    const allocator = std.testing.allocator;

    var jwt = Jwt.init(allocator, .{
        .secret = "secret-1",
    });

    var jwt2 = Jwt.init(allocator, .{
        .secret = "secret-2",
    });

    const token = try jwt.create("user-123");
    defer allocator.free(token);

    // Should fail with different secret
    const result = jwt2.verify(token);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "base64url encoding" {
    const allocator = std.testing.allocator;

    const original = "Hello, World!";
    const encoded = try base64UrlEncode(allocator, original);
    defer allocator.free(encoded);

    const decoded = try base64UrlDecode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}
