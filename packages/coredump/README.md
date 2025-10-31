# Core Dump Encryption Package

Protect sensitive data in crash dumps with encrypted core dump generation and analysis. This package prevents information leakage from crash dumps while maintaining debuggability.

## Overview

The `coredump` package provides:

- **Encrypted Core Dumps**: AES-256-GCM and ChaCha20-Poly1305 encryption
- **Key Management**: Secure key generation, storage, and rotation
- **Selective Encryption**: Encrypt stack, heap, and registers independently
- **Sensitive Data Redaction**: Automatically redact passwords, API keys, tokens
- **Dump Analysis**: Inspect encrypted dumps without decryption
- **Compression**: Optional compression before encryption
- **Metadata Protection**: Authenticated encryption with associated data (AEAD)

## Quick Start

### Generate Encryption Key

```zig
const std = @import("std");
const coredump = @import("coredump");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate AES-256-GCM key
    var key = try coredump.keys.EncryptionKey.generate(
        allocator,
        .aes_256_gcm,
    );
    defer key.deinit();

    // Set expiration (30 days)
    key.setExpiration(30);

    // Save to encrypted file
    try key.saveToFile("coredump.key", "secure_password");

    std.debug.print("Generated key: ", .{});
    for (key.key_id) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}
```

### Encrypt Core Dump

```zig
const std = @import("std");
const coredump = @import("coredump");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load encryption key
    var key = try coredump.keys.EncryptionKey.loadFromFile(
        allocator,
        "coredump.key",
        "secure_password",
    );
    defer key.deinit();

    // Read unencrypted core dump
    const dump_data = try std.fs.cwd().readFileAlloc(
        allocator,
        "core.1234",
        100 * 1024 * 1024, // 100MB max
    );
    defer allocator.free(dump_data);

    // Create metadata
    var metadata = try coredump.DumpMetadata.init(1234, "my_app", 11);

    // Encrypt dump
    var encrypted = try coredump.encrypt.encryptDump(
        allocator,
        dump_data,
        metadata,
        &key,
    );
    defer encrypted.deinit();

    // Save encrypted dump
    try coredump.encrypt.saveDump(&encrypted, "core.my_app.1234.ecore");

    std.debug.print("Encrypted dump saved\n", .{});
}
```

### Decrypt Core Dump

```zig
const std = @import("std");
const coredump = @import("coredump");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load key
    var key = try coredump.keys.EncryptionKey.loadFromFile(
        allocator,
        "coredump.key",
        "secure_password",
    );
    defer key.deinit();

    // Load encrypted dump
    var encrypted = try coredump.decrypt.loadDump(
        allocator,
        "core.my_app.1234.ecore",
    );
    defer encrypted.deinit();

    // Decrypt
    const decrypted = try coredump.decrypt.decryptDump(
        allocator,
        &encrypted,
        &key,
    );
    defer allocator.free(decrypted);

    // Save decrypted dump for analysis
    try std.fs.cwd().writeFile("core.decrypted", decrypted);

    std.debug.print("Decrypted {d} bytes\n", .{decrypted.len});
}
```

## Encryption Algorithms

### AES-256-GCM (Default)

Industry-standard authenticated encryption.

```zig
var key = try coredump.keys.EncryptionKey.generate(
    allocator,
    .aes_256_gcm,
);
defer key.deinit();
```

**Properties:**
- Key Size: 32 bytes (256 bits)
- Nonce Size: 12 bytes (96 bits)
- Auth Tag: 16 bytes (128 bits)
- Performance: Hardware-accelerated on modern CPUs
- Security: NIST-approved, FIPS 140-2 compliant

### ChaCha20-Poly1305 (Alternative)

Fast software-based authenticated encryption.

```zig
var key = try coredump.keys.EncryptionKey.generate(
    allocator,
    .chacha20_poly1305,
);
defer key.deinit();
```

**Properties:**
- Key Size: 32 bytes (256 bits)
- Nonce Size: 12 bytes (96 bits)
- Auth Tag: 16 bytes (128 bits)
- Performance: Fast on systems without AES-NI
- Security: Modern, widely used (TLS 1.3, WireGuard)

## Key Management

### Key Ring

Manage multiple encryption keys with automatic rotation:

```zig
var keyring = coredump.keys.KeyRing.init(allocator);
defer keyring.deinit();

// Generate initial key
var key1 = try coredump.keys.EncryptionKey.generate(allocator, .aes_256_gcm);
try keyring.addKey(key1);

// Rotate to new key
try keyring.rotate(.chacha20_poly1305);

// Get active key for encryption
const active_key = keyring.getActiveKey().?;

// Encrypt with active key
var encrypted = try coredump.encrypt.encryptDump(
    allocator,
    dump_data,
    metadata,
    active_key,
);
defer encrypted.deinit();

// Decrypt with any key in ring (auto-selects by key ID)
const decrypted = try coredump.decrypt.decryptWithKeyRing(
    allocator,
    &encrypted,
    &keyring,
);
defer allocator.free(decrypted);
```

### Key Expiration

Set automatic key expiration:

```zig
var key = try coredump.keys.EncryptionKey.generate(allocator, .aes_256_gcm);
defer key.deinit();

// Expire after 90 days
key.setExpiration(90);

if (key.isExpired()) {
    std.debug.print("Key has expired, rotate to new key\n", .{});
}
```

### Key Rotation

Rotate keys periodically for security:

```zig
var keyring = coredump.keys.KeyRing.init(allocator);
defer keyring.deinit();

// Add initial key
var key1 = try coredump.keys.EncryptionKey.generate(allocator, .aes_256_gcm);
key1.setExpiration(30);
try keyring.addKey(key1);

// After 30 days, rotate
try keyring.rotate(.aes_256_gcm);

// Old dumps can still be decrypted with old key
// New dumps use new key
```

## Core Dump Configuration

### Selective Encryption

Control which memory regions to encrypt:

```zig
const config = coredump.DumpConfig{
    .algorithm = .aes_256_gcm,
    .compress = true,
    .max_dump_size = 100 * 1024 * 1024, // 100MB
    .encrypt_stack = true,
    .encrypt_heap = true,
    .encrypt_registers = true,
    .redact_sensitive = true,
};
```

**Options:**
- `encrypt_stack`: Encrypt stack memory (usually contains local variables)
- `encrypt_heap`: Encrypt heap memory (dynamically allocated data)
- `encrypt_registers`: Encrypt CPU register values
- `redact_sensitive`: Automatically redact passwords, API keys, tokens
- `compress`: Compress before encryption (reduces size)

### Process Capture

Capture process memory snapshot:

```zig
const config = coredump.DumpConfig{
    .redact_sensitive = true,
};

var snapshot = try coredump.capture.captureProcess(allocator, pid, config);
defer snapshot.deinit();

// Serialize snapshot
const dump_data = try snapshot.serialize(allocator);
defer allocator.free(dump_data);

// Encrypt snapshot
var encrypted = try coredump.encrypt.encryptDump(
    allocator,
    dump_data,
    metadata,
    &key,
);
defer encrypted.deinit();
```

## Sensitive Data Redaction

Automatically redact sensitive patterns:

```zig
const original_dump = try allocator.dupe(u8,
    "username=admin&password=secret123&api_key=xyz789"
);
defer allocator.free(original_dump);

// Redact sensitive data
const redacted = try coredump.encrypt.redactSensitive(allocator, original_dump);
defer allocator.free(redacted);

// Redacted: "username=admin&password=XXXXX&api_key=XXXXX"
```

**Redacted Patterns:**
- `password=`, `pwd=` - Password fields
- `api_key=`, `token=` - API credentials
- `-----BEGIN` - SSH/TLS private keys
- Credit card patterns (16 consecutive digits)

## Dump Analysis

### Inspect Without Decryption

Analyze encrypted dumps without decrypting:

```zig
const analysis = try coredump.decrypt.analyzeDump(
    allocator,
    "core.app.1234.ecore",
    &keyring,
);

std.debug.print("{}", .{analysis});
// Output:
// Dump Analysis:
//   Core Dump (PID=1234, Process=app, Signal=11, Time=1704067200)
//   Data Size: 524288 bytes
//   Encrypted: true
//   Algorithm: AES-256-GCM
//   Key ID: a1b2c3d4e5f6...
//   Can Decrypt: true
```

### Extract Metadata Only

Get dump metadata without loading full dump:

```zig
const metadata = try coredump.decrypt.extractMetadata("core.app.1234.ecore");

std.debug.print("Process: {s}\n", .{metadata.getProcessName()});
std.debug.print("PID: {d}\n", .{metadata.pid});
std.debug.print("Signal: {d}\n", .{metadata.signal});
std.debug.print("Time: {d}\n", .{metadata.timestamp});
```

### Dump Statistics

Collect statistics across multiple dumps:

```zig
var stats = coredump.format.DumpStatistics.init();

// Scan directory
const dumps = try coredump.format.scanDumpDirectory(allocator, "/var/coredump");
defer {
    for (dumps.items) |path| {
        allocator.free(path);
    }
    dumps.deinit(allocator);
}

// Analyze each dump
for (dumps.items) |path| {
    const metadata = try coredump.decrypt.extractMetadata(path);
    const size = try coredump.format.getDumpSize(path);
    const encrypted = std.mem.endsWith(u8, path, ".ecore");

    stats.update(&metadata, size, encrypted);
}

std.debug.print("{}", .{stats});
// Output:
// Core Dump Statistics:
//   Total Dumps: 15
//   Encrypted: 12
//   Total Size: 157286400 bytes
//   Oldest: 1704000000
//   Newest: 1704067200
```

## File Format

Encrypted core dump file structure:

```
[Magic: "HOMECORE"]              8 bytes
[Version: 1]                      2 bytes
[Algorithm: 0=AES, 1=ChaCha]      1 byte
[Key ID]                          16 bytes
[Nonce]                           12 bytes
[Auth Tag]                        16 bytes
[Metadata]                        variable
[Data Length]                     8 bytes
[Encrypted Data]                  variable
```

### File Extensions

- `.ecore` - Encrypted core dump
- `.core` - Unencrypted core dump

## Integration Example

### Complete Crash Handler

```zig
const std = @import("std");
const coredump = @import("coredump");

var global_keyring: ?*coredump.keys.KeyRing = null;

pub fn initCrashHandler(allocator: std.mem.Allocator) !void {
    // Initialize key ring
    const keyring = try allocator.create(coredump.keys.KeyRing);
    keyring.* = coredump.keys.KeyRing.init(allocator);
    global_keyring = keyring;

    // Load or generate key
    var key = coredump.keys.EncryptionKey.loadFromFile(
        allocator,
        "/etc/coredump/encryption.key",
        std.os.getenv("COREDUMP_PASSWORD") orelse return error.NoPassword,
    ) catch |err| {
        if (err == error.FileNotFound) {
            // Generate new key
            const new_key = try coredump.keys.EncryptionKey.generate(
                allocator,
                .aes_256_gcm,
            );
            try new_key.saveToFile(
                "/etc/coredump/encryption.key",
                std.os.getenv("COREDUMP_PASSWORD").?,
            );
            return new_key;
        }
        return err;
    };

    try keyring.addKey(key);
}

pub fn handleCrash(pid: u32, signal: u32) !void {
    const allocator = std.heap.page_allocator;

    // Get process name
    const process_name = try getProcessName(allocator, pid);
    defer allocator.free(process_name);

    // Create metadata
    var metadata = try coredump.DumpMetadata.init(pid, process_name, signal);

    // Capture process snapshot
    const config = coredump.DumpConfig{
        .redact_sensitive = true,
        .compress = true,
    };

    var snapshot = try coredump.capture.captureProcess(allocator, pid, config);
    defer snapshot.deinit();

    // Serialize
    const dump_data = try snapshot.serialize(allocator);
    defer allocator.free(dump_data);

    // Encrypt
    const active_key = global_keyring.?.getActiveKey().?;
    var encrypted = try coredump.encrypt.compressAndEncrypt(
        allocator,
        dump_data,
        metadata,
        active_key,
    );
    defer encrypted.deinit();

    // Generate filename
    const filename = try coredump.format.generateDumpFilename(
        allocator,
        &metadata,
        true,
    );
    defer allocator.free(filename);

    // Save
    const path = try std.fs.path.join(allocator, &[_][]const u8{
        "/var/coredump",
        filename,
    });
    defer allocator.free(path);

    try coredump.encrypt.saveDump(&encrypted, path);
}

fn getProcessName(allocator: std.mem.Allocator, pid: u32) ![]u8 {
    // Read from /proc/[pid]/comm
    const path = try std.fmt.allocPrint(allocator, "/proc/{d}/comm", .{pid});
    defer allocator.free(path);

    const name = std.fs.cwd().readFileAlloc(allocator, path, 256) catch {
        return try allocator.dupe(u8, "unknown");
    };

    // Trim newline
    if (name.len > 0 and name[name.len - 1] == '\n') {
        return allocator.realloc(name, name.len - 1);
    }

    return name;
}
```

## Command-Line Tools

### Encrypt Tool

```zig
pub fn encryptTool(allocator: std.mem.Allocator, args: [][]const u8) !void {
    if (args.len < 4) {
        std.debug.print("Usage: coredump-encrypt <input.core> <output.ecore> <key.file> <password>\n", .{});
        return error.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];
    const key_path = args[3];
    const password = args[4];

    // Load key
    var key = try coredump.keys.EncryptionKey.loadFromFile(
        allocator,
        key_path,
        password,
    );
    defer key.deinit();

    // Read dump
    const dump_data = try std.fs.cwd().readFileAlloc(allocator, input_path, 1024 * 1024 * 1024);
    defer allocator.free(dump_data);

    // Extract metadata from filename or use defaults
    var metadata = try coredump.DumpMetadata.init(0, "unknown", 0);

    // Encrypt
    var encrypted = try coredump.encrypt.encryptDump(allocator, dump_data, metadata, &key);
    defer encrypted.deinit();

    // Save
    try coredump.encrypt.saveDump(&encrypted, output_path);

    std.debug.print("✓ Encrypted: {s}\n", .{output_path});
}
```

### Decrypt Tool

```zig
pub fn decryptTool(allocator: std.mem.Allocator, args: [][]const u8) !void {
    if (args.len < 4) {
        std.debug.print("Usage: coredump-decrypt <input.ecore> <output.core> <key.file> <password>\n", .{});
        return error.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];
    const key_path = args[3];
    const password = args[4];

    // Load key
    var key = try coredump.keys.EncryptionKey.loadFromFile(
        allocator,
        key_path,
        password,
    );
    defer key.deinit();

    // Load encrypted dump
    var encrypted = try coredump.decrypt.loadDump(allocator, input_path);
    defer encrypted.deinit();

    // Decrypt
    const decrypted = try coredump.decrypt.decryptDump(allocator, &encrypted, &key);
    defer allocator.free(decrypted);

    // Save
    try std.fs.cwd().writeFile(output_path, decrypted);

    std.debug.print("✓ Decrypted: {s} ({d} bytes)\n", .{ output_path, decrypted.len });
}
```

### Key Generation Tool

```zig
pub fn keygenTool(allocator: std.mem.Allocator, args: [][]const u8) !void {
    const algorithm: coredump.EncryptionAlgorithm = if (args.len > 1)
        std.meta.stringToEnum(coredump.EncryptionAlgorithm, args[1]) orelse .aes_256_gcm
    else
        .aes_256_gcm;

    const output_path = if (args.len > 2) args[2] else "coredump.key";
    const password = if (args.len > 3) args[3] else return error.NoPassword;

    // Generate key
    var key = try coredump.keys.EncryptionKey.generate(allocator, algorithm);
    defer key.deinit();

    // Set expiration
    key.setExpiration(365); // 1 year

    // Save
    try key.saveToFile(output_path, password);

    std.debug.print("✓ Generated {s} key\n", .{algorithm.name()});
    std.debug.print("  Saved to: {s}\n", .{output_path});
    std.debug.print("  Key ID: ", .{});
    for (key.key_id) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}
```

## Best Practices

### Security

1. **Protect Encryption Keys**: Store keys in secure locations with restricted permissions
2. **Use Strong Passwords**: Protect key files with strong passwords
3. **Rotate Keys Regularly**: Rotate keys every 30-90 days
4. **Enable Redaction**: Always enable sensitive data redaction
5. **Audit Access**: Log all dump encryption/decryption operations
6. **Limit Dump Size**: Set reasonable max_dump_size to prevent DoS

### Performance

1. **Use ChaCha20 on ARM**: Better performance without AES-NI
2. **Enable Compression**: Reduces encrypted dump size 50-70%
3. **Selective Encryption**: Only encrypt sensitive regions
4. **Batch Operations**: Process multiple dumps in parallel

### Deployment

1. **Automated Key Rotation**: Schedule monthly key rotation
2. **Backup Keys**: Securely backup old keys for historical dumps
3. **Monitor Disk Usage**: Encrypted dumps can accumulate quickly
4. **Test Recovery**: Regularly verify you can decrypt dumps

## License

Part of the Home programming language project.
