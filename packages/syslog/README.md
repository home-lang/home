# Syslog Security Package

Secure logging with authentication, encryption, access control, and DoS protection for Home OS.

## Overview

The `syslog` package provides enterprise-grade secure logging:

- **Log Authentication**: HMAC-SHA256 signatures prevent tampering
- **Log Encryption**: ChaCha20-Poly1305 for sensitive data
- **Access Control**: Role-based permissions and filtering
- **Rate Limiting**: Token bucket algorithm prevents DoS
- **Remote Logging**: Secure TLS-based log forwarding
- **Integrity Chains**: Blockchain-style tamper detection
- **Auto-Redaction**: Automatic sensitive data masking

## Quick Start

### Basic Logging

```zig
const std = @import("std");
const syslog = @import("syslog");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create log message
    var msg = try syslog.LogMessage.init(
        allocator,
        .daemon,          // Facility
        .info,            // Severity
        "localhost",      // Hostname
        "myapp",          // Application name
        std.os.linux.getpid(), // Process ID
        "Application started successfully",
    );
    defer msg.deinit();

    // Format as RFC 5424
    const formatted = try msg.formatRFC5424(allocator);
    defer allocator.free(formatted);

    std.debug.print("{s}\n", .{formatted});
    // Output: <30>1 1704067200Z localhost myapp 1234 - - Application started successfully
}
```

### Authenticated Logging

```zig
const std = @import("std");
const syslog = @import("syslog");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate authentication key
    const auth_key = syslog.auth.AuthKey.generate();

    // Create log chain for integrity
    var chain = syslog.auth.LogChain.init(allocator);

    var msg = try syslog.LogMessage.init(
        allocator,
        .auth,
        .warning,
        "server1",
        "sshd",
        5678,
        "Failed login attempt from 192.168.1.100",
    );
    defer msg.deinit();

    // Add to authenticated chain
    var auth_log = try chain.addLog(&msg, &auth_key);

    // Verify authenticity
    const valid = try syslog.auth.verifyLog(&auth_log, &auth_key);
    std.debug.print("Log authenticated: {}\n", .{valid});
}
```

### Encrypted Logging

```zig
const std = @import("std");
const syslog = @import("syslog");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate encryption key
    var enc_key = syslog.encrypt.EncryptionKey.generate();

    var msg = try syslog.LogMessage.init(
        allocator,
        .authpriv,
        .info,
        "localhost",
        "app",
        1234,
        "User password changed: newpass=secret123",
    );
    defer msg.deinit();

    // Check if should encrypt
    if (syslog.encrypt.shouldEncrypt(&msg)) {
        // Encrypt sensitive log
        var encrypted = try syslog.encrypt.encryptLog(allocator, &msg, &enc_key);
        defer encrypted.deinit();

        std.debug.print("Encrypted log for {s}\n", .{encrypted.getAppName()});

        // Decrypt when needed
        var decrypted = try syslog.encrypt.decryptLog(allocator, &encrypted, &enc_key);
        defer decrypted.deinit();

        std.debug.print("Decrypted: {s}\n", .{decrypted.message});
    }
}
```

## Features

### Log Authentication

Prevent log tampering with HMAC-SHA256 signatures:

```zig
// Generate key
const key = syslog.auth.AuthKey.generate();

// Authenticate log
var auth_log = try syslog.auth.authenticateLog(&message, &key, sequence_number);

// Verify later
const valid = try syslog.auth.verifyLog(&auth_log, &key);
```

**Log Chain Integrity:**

```zig
var chain = syslog.auth.LogChain.init(allocator);

// Add logs to chain
var log1 = try chain.addLog(&msg1, &key);
var log2 = try chain.addLog(&msg2, &key);
var log3 = try chain.addLog(&msg3, &key);

// Verify entire chain
const logs = [_]syslog.auth.AuthenticatedLog{ log1, log2, log3 };
const valid = try chain.verifyChain(&logs, &key);
```

### Log Encryption

Encrypt sensitive logs with ChaCha20-Poly1305:

```zig
var key = syslog.encrypt.EncryptionKey.generate();

// Encrypt
var encrypted = try syslog.encrypt.encryptLog(allocator, &message, &key);
defer encrypted.deinit();

// Decrypt
var decrypted = try syslog.encrypt.decryptLog(allocator, &encrypted, &key);
defer decrypted.deinit();
```

**Auto-Detection:**

```zig
// Automatically encrypt sensitive logs
if (syslog.encrypt.shouldEncrypt(&message)) {
    // Encrypts if:
    // - Facility is auth or authpriv
    // - Severity is critical or higher
    // - Message contains: password, token, secret, key, credential, auth
}
```

**Sensitive Data Redaction:**

```zig
const original = "Login: user=admin password=secret123 token=xyz";
const redacted = try syslog.encrypt.redactSensitive(allocator, original);
defer allocator.free(redacted);
// Result: "Login: user=admin password=******************** token=********************"
```

### Access Control

Role-based access control for log viewing:

```zig
var ac = syslog.access.AccessControl.init(allocator);
defer ac.deinit();

// Add admin role
try ac.addACL(syslog.access.Role.admin.getACL(1000));

// Add auditor role (read-only)
try ac.addACL(syslog.access.Role.auditor.getACL(2000));

// Add regular user
try ac.addACL(syslog.access.Role.user.getACL(3000));

// Check permissions
if (ac.checkPermission(user_id, .read)) {
    // User can read logs
}

// Filter logs by permission
const filtered = try ac.filterLogs(user_id, all_logs, allocator);
defer allocator.free(filtered);
```

**Pre-defined Roles:**

- `admin`: Full access to all logs and facilities
- `operator`: Read/write access, info level and above
- `auditor`: Read-only access, notice level and above
- `user`: Read-only access to user facility only

**Custom ACLs:**

```zig
const custom_acl = syslog.access.ACL{
    .user_id = 5000,
    .facility = .daemon,  // Only daemon logs
    .min_severity = .warning,  // Warning and above
    .permissions = std.EnumSet(syslog.access.Permission).init(.{
        .read = true,
        .write = false,
        .admin = false,
    }),
};

try ac.addACL(custom_acl);
```

### Rate Limiting

Protect against log flooding and DoS:

```zig
// Global rate limiter (1000 logs/second, burst of 5000)
var limiter = syslog.ratelimit.RateLimiter.init(5000, 1000);

if (limiter.tryAcquire()) {
    // Log allowed
    try writeLog(message);
} else {
    // Rate limit exceeded, drop log
}
```

**Per-Source Rate Limiting:**

```zig
var limiter = syslog.ratelimit.PerSourceLimiter.init(allocator, 100, 10);
defer limiter.deinit();

const source = "192.168.1.100";
if (try limiter.tryAcquire(source)) {
    // Source allowed
} else {
    // Source rate limited
}

// Cleanup inactive limiters
limiter.cleanup();
```

**Rate Limit Statistics:**

```zig
var stats = syslog.ratelimit.RateLimitStats.init();

if (limiter.tryAcquire()) {
    stats.recordAllowed();
} else {
    stats.recordDenied();
}

std.debug.print("Allowed: {d}\n", .{stats.getAllowed()});
std.debug.print("Denied: {d}\n", .{stats.getDenied()});
std.debug.print("Deny rate: {d:.2}%\n", .{stats.getDenyRate() * 100});
```

### Remote Logging

Secure TLS-based log forwarding:

```zig
const config = syslog.remote.RemoteConfig{
    .host = "logs.example.com",
    .port = 6514,  // RFC 5425 (syslog over TLS)
    .use_tls = true,
    .verify_cert = true,
    .timeout_ms = 5000,
};

var client = syslog.remote.RemoteClient.init(allocator, config);

// Optional: Add authentication
const auth_key = syslog.auth.AuthKey.generate();
client.setAuthKey(auth_key);

// Connect
try client.connect();
defer client.disconnect();

// Send log
try client.sendLog(&message);

// Send batch
try client.sendBatch(&[_]syslog.LogMessage{ msg1, msg2, msg3 });
```

**Log Forwarding with Retry:**

```zig
var forwarder = syslog.remote.LogForwarder.init(allocator, config, 1000);
defer forwarder.deinit();

try forwarder.client.connect();

// Forward with automatic retry
forwarder.forwardLog(&message) catch |err| {
    // Queued for later retry
    std.debug.print("Queued: {s}\n", .{@errorName(err)});
};

// Retry queued logs
const sent = try forwarder.retryQueued();
std.debug.print("Sent {d} queued logs\n", .{sent});
```

## Complete Example

Secure logging system with all features:

```zig
const std = @import("std");
const syslog = @import("syslog");

pub const SecureLogger = struct {
    allocator: std.mem.Allocator,
    auth_key: syslog.auth.AuthKey,
    enc_key: syslog.encrypt.EncryptionKey,
    chain: syslog.auth.LogChain,
    rate_limiter: syslog.ratelimit.PerSourceLimiter,
    access_control: syslog.access.AccessControl,
    forwarder: ?*syslog.remote.LogForwarder,

    pub fn init(allocator: std.mem.Allocator) !SecureLogger {
        var logger: SecureLogger = undefined;
        logger.allocator = allocator;
        logger.auth_key = syslog.auth.AuthKey.generate();
        logger.enc_key = syslog.encrypt.EncryptionKey.generate();
        logger.chain = syslog.auth.LogChain.init(allocator);
        logger.rate_limiter = syslog.ratelimit.PerSourceLimiter.init(allocator, 100, 10);
        logger.access_control = syslog.access.AccessControl.init(allocator);
        logger.forwarder = null;

        // Setup default ACLs
        try logger.access_control.addACL(syslog.access.Role.admin.getACL(0));

        return logger;
    }

    pub fn deinit(self: *SecureLogger) void {
        self.rate_limiter.deinit();
        self.access_control.deinit();
        if (self.forwarder) |fwd| {
            fwd.deinit();
            self.allocator.destroy(fwd);
        }
    }

    pub fn log(
        self: *SecureLogger,
        facility: syslog.Facility,
        severity: syslog.Severity,
        source: []const u8,
        message: []const u8,
    ) !void {
        // Rate limiting
        if (!try self.rate_limiter.tryAcquire(source)) {
            return error.RateLimitExceeded;
        }

        // Create log message
        var msg = try syslog.LogMessage.init(
            self.allocator,
            facility,
            severity,
            std.os.gethostname() catch "unknown",
            "secure_logger",
            std.os.linux.getpid(),
            message,
        );
        defer msg.deinit();

        // Authenticate
        var auth_log = try self.chain.addLog(&msg, &self.auth_key);

        // Encrypt if sensitive
        if (syslog.encrypt.shouldEncrypt(&msg)) {
            var encrypted = try syslog.encrypt.encryptLog(self.allocator, &msg, &self.enc_key);
            defer encrypted.deinit();

            // Store encrypted log
            try self.storeEncrypted(&encrypted);
        } else {
            // Store authenticated log
            try self.storeAuthenticated(&auth_log);
        }

        // Forward to remote server
        if (self.forwarder) |fwd| {
            try fwd.forwardLog(&msg);
        }
    }

    fn storeAuthenticated(self: *SecureLogger, log: *const syslog.auth.AuthenticatedLog) !void {
        // Write to log file
        _ = self;
        _ = log;
    }

    fn storeEncrypted(self: *SecureLogger, log: *const syslog.encrypt.EncryptedLog) !void {
        // Write encrypted log to file
        _ = self;
        _ = log;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var logger = try SecureLogger.init(allocator);
    defer logger.deinit();

    // Log various events
    try logger.log(.user, .info, "app", "User logged in");
    try logger.log(.auth, .warning, "ssh", "Failed login attempt");
    try logger.log(.daemon, .err, "system", "Service crashed");
}
```

## Severity Levels (RFC 5424)

| Level | Value | Description |
|-------|-------|-------------|
| emergency | 0 | System unusable |
| alert | 1 | Action required immediately |
| critical | 2 | Critical conditions |
| error | 3 | Error conditions |
| warning | 4 | Warning conditions |
| notice | 5 | Normal but significant |
| info | 6 | Informational |
| debug | 7 | Debug messages |

## Facilities (RFC 5424)

| Facility | Value | Description |
|----------|-------|-------------|
| kernel | 0 | Kernel messages |
| user | 1 | User-level messages |
| mail | 2 | Mail system |
| daemon | 3 | System daemons |
| auth | 4 | Security/auth messages |
| syslog | 5 | Syslog internal |
| authpriv | 10 | Private auth messages |
| local0-7 | 16-23 | Local use |

## Best Practices

### Security

1. **Always authenticate critical logs**: Use HMAC for tamper detection
2. **Encrypt sensitive data**: Auth and authpriv facilities
3. **Enable rate limiting**: Prevent DoS attacks
4. **Use TLS for remote**: Never send logs in plaintext
5. **Rotate keys regularly**: Monthly for auth keys
6. **Implement access control**: Restrict log access by role
7. **Redact before logging**: Never log passwords in plaintext

### Performance

1. **Batch remote sends**: Reduce network overhead
2. **Use appropriate severity**: Don't debug in production
3. **Set reasonable rate limits**: Balance protection vs functionality
4. **Cleanup inactive limiters**: Prevent memory growth
5. **Async forwarding**: Don't block on remote logging

### Deployment

1. **Centralized logging**: Forward to remote syslog server
2. **Log rotation**: Implement size/time-based rotation
3. **Monitor deny rate**: Alert on excessive rate limiting
4. **Verify chain integrity**: Periodically check for tampering
5. **Test failover**: Ensure queue handles network issues

## License

Part of the Home programming language project.
