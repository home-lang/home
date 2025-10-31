// Log encryption for sensitive data

const std = @import("std");
const syslog = @import("syslog.zig");

/// Encryption key
pub const EncryptionKey = struct {
    key_data: [32]u8,
    nonce_counter: std.atomic.Value(u64),

    pub fn generate() EncryptionKey {
        var key: EncryptionKey = undefined;
        std.crypto.random.bytes(&key.key_data);
        key.nonce_counter = std.atomic.Value(u64).init(0);
        return key;
    }

    fn nextNonce(self: *EncryptionKey) [12]u8 {
        const counter = self.nonce_counter.fetchAdd(1, .monotonic);
        var nonce: [12]u8 = undefined;
        std.crypto.random.bytes(nonce[0..4]); // Random prefix
        std.mem.writeInt(u64, nonce[4..12], counter, .little);
        return nonce;
    }
};

/// Encrypted log message
pub const EncryptedLog = struct {
    facility: syslog.Facility,
    severity: syslog.Severity,
    timestamp: i64,
    hostname: [256]u8,
    hostname_len: usize,
    app_name: [48]u8,
    app_name_len: usize,
    process_id: u32,
    encrypted_message: []u8,
    nonce: [12]u8,
    tag: [16]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncryptedLog) void {
        self.allocator.free(self.encrypted_message);
    }

    pub fn getHostname(self: *const EncryptedLog) []const u8 {
        return self.hostname[0..self.hostname_len];
    }

    pub fn getAppName(self: *const EncryptedLog) []const u8 {
        return self.app_name[0..self.app_name_len];
    }
};

/// Encrypt log message
pub fn encryptLog(
    allocator: std.mem.Allocator,
    message: *const syslog.LogMessage,
    key: *EncryptionKey,
) !EncryptedLog {
    const nonce = key.nextNonce();

    // Encrypt message content
    const encrypted = try allocator.alloc(u8, message.message.len);
    errdefer allocator.free(encrypted);

    var tag: [16]u8 = undefined;

    // Build associated data (unencrypted metadata)
    var ad_buf: [512]u8 = undefined;
    var ad_stream = std.io.fixedBufferStream(&ad_buf);
    const ad_writer = ad_stream.writer();

    try ad_writer.writeByte(@intFromEnum(message.facility));
    try ad_writer.writeByte(@intFromEnum(message.severity));
    try ad_writer.writeInt(i64, message.timestamp, .little);
    try ad_writer.writeAll(message.getHostname());
    try ad_writer.writeAll(message.getAppName());
    try ad_writer.writeInt(u32, message.process_id, .little);

    const ad = ad_stream.getWritten();

    // Encrypt with ChaCha20-Poly1305
    std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(
        encrypted,
        &tag,
        message.message,
        ad,
        nonce,
        key.key_data,
    );

    var encrypted_log: EncryptedLog = undefined;
    encrypted_log.facility = message.facility;
    encrypted_log.severity = message.severity;
    encrypted_log.timestamp = message.timestamp;
    encrypted_log.hostname = message.hostname;
    encrypted_log.hostname_len = message.hostname_len;
    encrypted_log.app_name = message.app_name;
    encrypted_log.app_name_len = message.app_name_len;
    encrypted_log.process_id = message.process_id;
    encrypted_log.encrypted_message = encrypted;
    encrypted_log.nonce = nonce;
    encrypted_log.tag = tag;
    encrypted_log.allocator = allocator;

    return encrypted_log;
}

/// Decrypt log message
pub fn decryptLog(
    allocator: std.mem.Allocator,
    encrypted: *const EncryptedLog,
    key: *const EncryptionKey,
) !syslog.LogMessage {
    // Rebuild associated data
    var ad_buf: [512]u8 = undefined;
    var ad_stream = std.io.fixedBufferStream(&ad_buf);
    const ad_writer = ad_stream.writer();

    try ad_writer.writeByte(@intFromEnum(encrypted.facility));
    try ad_writer.writeByte(@intFromEnum(encrypted.severity));
    try ad_writer.writeInt(i64, encrypted.timestamp, .little);
    try ad_writer.writeAll(encrypted.getHostname());
    try ad_writer.writeAll(encrypted.getAppName());
    try ad_writer.writeInt(u32, encrypted.process_id, .little);

    const ad = ad_stream.getWritten();

    // Decrypt message
    const decrypted = try allocator.alloc(u8, encrypted.encrypted_message.len);
    errdefer allocator.free(decrypted);

    try std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(
        decrypted,
        encrypted.encrypted_message,
        encrypted.tag,
        ad,
        encrypted.nonce,
        key.key_data,
    );

    var message: syslog.LogMessage = undefined;
    message.facility = encrypted.facility;
    message.severity = encrypted.severity;
    message.timestamp = encrypted.timestamp;
    message.hostname = encrypted.hostname;
    message.hostname_len = encrypted.hostname_len;
    message.app_name = encrypted.app_name;
    message.app_name_len = encrypted.app_name_len;
    message.process_id = encrypted.process_id;
    message.message = decrypted;
    message.allocator = allocator;

    return message;
}

/// Redact sensitive data from log message
pub fn redactSensitive(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const redacted = try allocator.dupe(u8, message);

    // Redact common sensitive patterns
    var i: usize = 0;
    while (i < redacted.len) : (i += 1) {
        // Redact "password="
        if (i + 9 <= redacted.len and std.mem.eql(u8, redacted[i..][0..9], "password=")) {
            const end = @min(i + 9 + 20, redacted.len);
            @memset(redacted[i + 9 .. end], '*');
        }

        // Redact "token="
        if (i + 6 <= redacted.len and std.mem.eql(u8, redacted[i..][0..6], "token=")) {
            const end = @min(i + 6 + 20, redacted.len);
            @memset(redacted[i + 6 .. end], '*');
        }

        // Redact "api_key="
        if (i + 8 <= redacted.len and std.mem.eql(u8, redacted[i..][0..8], "api_key=")) {
            const end = @min(i + 8 + 20, redacted.len);
            @memset(redacted[i + 8 .. end], '*');
        }

        // Redact credit card patterns (16 consecutive digits)
        if (i + 16 <= redacted.len) {
            var is_cc = true;
            for (redacted[i..][0..16]) |byte| {
                if (byte < '0' or byte > '9') {
                    is_cc = false;
                    break;
                }
            }
            if (is_cc) {
                @memset(redacted[i..][0..16], '*');
            }
        }
    }

    return redacted;
}

/// Check if log should be encrypted based on content
pub fn shouldEncrypt(message: *const syslog.LogMessage) bool {
    // Encrypt auth and authpriv facilities
    if (message.facility == .auth or message.facility == .authpriv) {
        return true;
    }

    // Encrypt critical and higher severity
    if (@intFromEnum(message.severity) <= @intFromEnum(syslog.Severity.critical)) {
        return true;
    }

    // Check for sensitive keywords
    const sensitive_keywords = [_][]const u8{
        "password",
        "token",
        "secret",
        "key",
        "credential",
        "auth",
    };

    const lower_msg = std.ascii.allocLowerString(message.allocator, message.message) catch return false;
    defer message.allocator.free(lower_msg);

    for (sensitive_keywords) |keyword| {
        if (std.mem.indexOf(u8, lower_msg, keyword) != null) {
            return true;
        }
    }

    return false;
}

test "encrypt and decrypt log" {
    const testing = std.testing;

    var key = EncryptionKey.generate();

    var message = try syslog.LogMessage.init(
        testing.allocator,
        .authpriv,
        .info,
        "localhost",
        "sshd",
        1234,
        "User login: password=secret123",
    );
    defer message.deinit();

    // Encrypt
    var encrypted = try encryptLog(testing.allocator, &message, &key);
    defer encrypted.deinit();

    // Verify encrypted message differs
    try testing.expect(!std.mem.eql(u8, encrypted.encrypted_message, message.message));

    // Decrypt
    var decrypted = try decryptLog(testing.allocator, &encrypted, &key);
    defer decrypted.deinit();

    // Verify decrypted matches original
    try testing.expectEqualStrings(message.message, decrypted.message);
}

test "redact sensitive data" {
    const testing = std.testing;

    const message = "Login user=admin password=secret123 token=abc123";
    const redacted = try redactSensitive(testing.allocator, message);
    defer testing.allocator.free(redacted);

    // Should not contain original sensitive values
    try testing.expect(std.mem.indexOf(u8, redacted, "secret123") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "abc123") == null);
}

test "should encrypt detection" {
    const testing = std.testing;

    // Auth facility should encrypt
    var auth_msg = try syslog.LogMessage.init(
        testing.allocator,
        .auth,
        .info,
        "host",
        "app",
        1,
        "Normal message",
    );
    defer auth_msg.deinit();

    try testing.expect(shouldEncrypt(&auth_msg));

    // Message with password keyword should encrypt
    var pwd_msg = try syslog.LogMessage.init(
        testing.allocator,
        .user,
        .info,
        "host",
        "app",
        1,
        "Changed password for user",
    );
    defer pwd_msg.deinit();

    try testing.expect(shouldEncrypt(&pwd_msg));
}
