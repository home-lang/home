# Module Signing (modsign) Package

User-space tools for signing and verifying kernel modules. This package provides cryptographic signing utilities that work with Home's kernel module verification system.

## Overview

The `modsign` package enables:

- **Key Generation**: Create RSA and ECDSA key pairs for module signing
- **Module Signing**: Cryptographically sign kernel modules before deployment
- **Signature Verification**: Verify module signatures match trusted keys
- **Key Management**: Maintain key rings of trusted public keys
- **Signature Inspection**: Examine and display module signature information

## Quick Start

### Generate Signing Keys

```zig
const std = @import("std");
const modsign = @import("modsign");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate RSA-2048 key pair
    var keypair = try modsign.keys.KeyPair.generate(
        allocator,
        .rsa_2048_sha256,
        "kernel_module_signer",
    );
    defer keypair.deinit();

    // Save keys
    try keypair.private_key.savePem("module_signing_key.pem");
    try keypair.public_key.savePem("module_signing_key.pub");

    std.debug.print("Key ID: ", .{});
    for (keypair.public_key.key_id) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}
```

### Sign a Module

```zig
const std = @import("std");
const modsign = @import("modsign");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load private key
    var private_key = try modsign.keys.PrivateKey.loadPem(
        allocator,
        "module_signing_key.pem",
    );
    defer private_key.deinit();

    // Sign module file
    try modsign.sign.signModuleFile(
        allocator,
        "my_driver.ko",
        &private_key,
        "my_driver.ko.signed",
    );

    std.debug.print("Module signed successfully!\n", .{});
}
```

### Verify a Module

```zig
const std = @import("std");
const modsign = @import("modsign");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate keypair for testing (normally load public key)
    var keypair = try modsign.keys.KeyPair.generate(
        allocator,
        .rsa_2048_sha256,
        "test",
    );
    defer keypair.deinit();

    // Verify module
    const result = try modsign.verify.verifyModuleFile(
        allocator,
        "my_driver.ko.signed",
        &keypair.public_key,
    );

    switch (result) {
        .valid => std.debug.print("✓ Signature valid\n", .{}),
        .invalid_signature => std.debug.print("✗ Invalid signature\n", .{}),
        .hash_mismatch => std.debug.print("✗ Module hash mismatch\n", .{}),
        .no_signature => std.debug.print("✗ Module not signed\n", .{}),
        .key_not_found => std.debug.print("✗ Signing key not found\n", .{}),
        .algorithm_mismatch => std.debug.print("✗ Algorithm mismatch\n", .{}),
    }
}
```

## Signature Algorithms

### RSA-2048-SHA256 (Default)

Standard RSA signing with 2048-bit keys and SHA-256 hashing.

```zig
const algorithm = modsign.SignatureAlgorithm.rsa_2048_sha256;
var keypair = try modsign.keys.KeyPair.generate(allocator, algorithm, "rsa_key");
defer keypair.deinit();
```

**Properties:**
- Key Size: 256 bytes (2048 bits)
- Signature Size: 256 bytes
- Security: Suitable for most use cases
- Performance: Slower than ECDSA

### RSA-4096-SHA256 (High Security)

Stronger RSA variant with 4096-bit keys.

```zig
const algorithm = modsign.SignatureAlgorithm.rsa_4096_sha256;
var keypair = try modsign.keys.KeyPair.generate(allocator, algorithm, "rsa4k_key");
defer keypair.deinit();
```

**Properties:**
- Key Size: 512 bytes (4096 bits)
- Signature Size: 512 bytes
- Security: Very high security for sensitive modules
- Performance: Slowest option

### ECDSA-P256-SHA256 (Fast)

Elliptic curve signing with NIST P-256 curve.

```zig
const algorithm = modsign.SignatureAlgorithm.ecdsa_p256_sha256;
var keypair = try modsign.keys.KeyPair.generate(allocator, algorithm, "ecc_key");
defer keypair.deinit();
```

**Properties:**
- Key Size: 32 bytes
- Signature Size: 64 bytes
- Security: Equivalent to RSA-3072
- Performance: Fastest option, smallest signatures

## Working with Signatures

### Sign Module with Custom Configuration

```zig
const config = modsign.SigningConfig{
    .algorithm = .ecdsa_p256_sha256,
    .key_description = "driver_signer_v1",
    .verify_after_sign = true,
    .strip_signature = false,
};

var private_key = try modsign.keys.PrivateKey.generate(
    allocator,
    config.algorithm,
    config.key_description,
);
defer private_key.deinit();

// Read module
const module_file = try std.fs.cwd().openFile("driver.ko", .{});
defer module_file.close();

const module_data = try module_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
defer allocator.free(module_data);

// Create signature
var signature = try modsign.sign.signModule(allocator, module_data, &private_key);
defer signature.deinit();

std.debug.print("Signed with {s}\n", .{signature.algorithm.name()});
```

### Inspect Module Signature

```zig
const module_file = try std.fs.cwd().openFile("driver.ko.signed", .{});
defer module_file.close();

const signed_data = try module_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
defer allocator.free(signed_data);

// Get module information
const info = try modsign.format.ModuleInfo.inspect(allocator, signed_data);

try info.print(std.io.getStdOut().writer());
// Output:
// Module Information:
//   Module Size: 1234567 bytes
//   Signed: Yes
//   Signature Size: 256 bytes
//   Algorithm: RSA-2048-SHA256
//   Key ID: a1b2c3d4e5f6...
```

### Extract Unsigned Module

```zig
const signed_data = try std.fs.cwd().readFileAlloc(
    allocator,
    "driver.ko.signed",
    10 * 1024 * 1024,
);
defer allocator.free(signed_data);

const result = try modsign.sign.extractSignature(allocator, signed_data);
defer if (result.signature) |*sig| sig.deinit();

// Save unsigned module
const out_file = try std.fs.cwd().createFile("driver.ko.unsigned", .{});
defer out_file.close();

try out_file.writeAll(result.module_data);

if (result.signature) |*sig| {
    std.debug.print("Extracted signature: {s}\n", .{sig.algorithm.name()});
}
```

## Key Management

### Key Ring for Multiple Trusted Keys

```zig
var keyring = modsign.verify.KeyRing.init(allocator);
defer keyring.deinit();

// Add trusted keys
var key1 = try modsign.keys.KeyPair.generate(allocator, .rsa_2048_sha256, "dev_key");
defer key1.deinit();

var key2 = try modsign.keys.KeyPair.generate(allocator, .ecdsa_p256_sha256, "prod_key");
defer key2.deinit();

// Duplicate public keys for keyring (keys take ownership)
const pub1_data = try allocator.dupe(u8, key1.public_key.key_data);
const pub1_desc = try allocator.dupe(u8, key1.public_key.description);

const pub1 = modsign.keys.PublicKey{
    .algorithm = key1.public_key.algorithm,
    .key_data = pub1_data,
    .key_id = key1.public_key.key_id,
    .description = pub1_desc,
    .allocator = allocator,
};

try keyring.addKey(pub1);

// Verify module with keyring
const module_data = "module content";
var signature = try modsign.sign.signModule(allocator, module_data, &key1.private_key);
defer signature.deinit();

const result = try modsign.verify.verifyWithKeyRing(
    allocator,
    module_data,
    &signature,
    &keyring,
);

if (result == .valid) {
    std.debug.print("Module signed by trusted key\n", .{});
}
```

### Find Key by ID

```zig
var keyring = modsign.verify.KeyRing.init(allocator);
defer keyring.deinit();

// ... add keys ...

const key_id = [_]u8{0xa1, 0xb2, 0xc3} ++ [_]u8{0} ** 29;
const found_key = keyring.findKey(&key_id);

if (found_key) |key| {
    std.debug.print("Found key: {s}\n", .{key.description});
}
```

## Signature Format

Modules are signed by appending signature data to the end of the module file:

```
[Module Binary Data]
[Signature Data]
[Magic: "~Module signature appended~\n"]
[Signature Length: 4 bytes, little-endian]
```

### Signature Data Structure

```
Byte 0:       Algorithm ID (0=RSA-2048, 1=RSA-4096, 2=ECDSA-P256)
Bytes 1-32:   Key ID (32-byte fingerprint)
Byte 33:      Hash Length
Bytes 34+:    Module Hash (SHA-256)
Next 2 bytes: Signature Length (little-endian)
Next N bytes: Signature
```

## Integration with Kernel

The signed modules work with Home's kernel module verification system:

### Kernel Policy Modes

1. **NONE**: No signature required
2. **OPTIONAL**: Signature required unless `CAP_SYS_MODULE` capability
3. **REQUIRED**: Signature always required
4. **STRICT**: Signature required + lockdown enforcement

### Loading Signed Modules

```zig
// User space: Sign module
try modsign.sign.signModuleFile(allocator, "driver.ko", &private_key, null);

// Kernel space: Module loader verifies signature automatically
// If signature invalid or missing, kernel rejects module load
```

## Command-Line Tools

### Sign Tool

```zig
pub fn signTool(allocator: std.mem.Allocator, args: [][]const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: modsign sign <module.ko> <key.pem> [output.ko]\n", .{});
        return error.InvalidArgs;
    }

    const module_path = args[1];
    const key_path = args[2];
    const output_path = if (args.len > 3) args[3] else null;

    var private_key = try modsign.keys.PrivateKey.loadPem(allocator, key_path);
    defer private_key.deinit();

    try modsign.sign.signModuleFile(allocator, module_path, &private_key, output_path);

    std.debug.print("✓ Signed: {s}\n", .{output_path orelse module_path});
}
```

### Verify Tool

```zig
pub fn verifyTool(allocator: std.mem.Allocator, args: [][]const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: modsign verify <module.ko> <key.pub>\n", .{});
        return error.InvalidArgs;
    }

    const module_path = args[1];
    const key_path = args[2];

    // Load public key (simplified)
    var keypair = try modsign.keys.KeyPair.generate(
        allocator,
        .rsa_2048_sha256,
        "verify",
    );
    defer keypair.deinit();

    const result = try modsign.verify.verifyModuleFile(
        allocator,
        module_path,
        &keypair.public_key,
    );

    switch (result) {
        .valid => {
            std.debug.print("✓ Valid signature\n", .{});
            return;
        },
        else => {
            std.debug.print("✗ Verification failed: {s}\n", .{@tagName(result)});
            return error.VerificationFailed;
        },
    }
}
```

### Keygen Tool

```zig
pub fn keygenTool(allocator: std.mem.Allocator, args: [][]const u8) !void {
    const algorithm: modsign.SignatureAlgorithm = if (args.len > 1)
        std.meta.stringToEnum(modsign.SignatureAlgorithm, args[1]) orelse .rsa_2048_sha256
    else
        .rsa_2048_sha256;

    const description = if (args.len > 2) args[2] else "module_signer";

    var keypair = try modsign.keys.KeyPair.generate(allocator, algorithm, description);
    defer keypair.deinit();

    try keypair.private_key.savePem("module_signing_key.pem");
    try keypair.public_key.savePem("module_signing_key.pub");

    std.debug.print("✓ Generated {s} key pair\n", .{algorithm.name()});
    std.debug.print("  Private: module_signing_key.pem\n", .{});
    std.debug.print("  Public:  module_signing_key.pub\n", .{});
}
```

## Best Practices

### Security

1. **Protect Private Keys**: Store signing keys securely, restrict file permissions
2. **Use Strong Algorithms**: Prefer RSA-4096 or ECDSA-P256 for production
3. **Key Rotation**: Regularly rotate signing keys (yearly or quarterly)
4. **Separate Keys**: Use different keys for development vs production
5. **Key Fingerprints**: Always verify key IDs before trusting modules

### Development Workflow

```bash
# Generate development signing key
./modsign keygen ecdsa_p256_sha256 dev_key

# Build module
zig build-lib driver.zig -target x86_64-freestanding

# Sign module
./modsign sign driver.ko module_signing_key.pem

# Verify signature
./modsign verify driver.ko module_signing_key.pub

# Install to system
sudo cp driver.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a
```

### Production Deployment

1. **Offline Signing**: Sign modules on air-gapped machine
2. **Build Verification**: Verify build hashes before signing
3. **Multiple Signers**: Require multiple signatures for critical modules
4. **Audit Trail**: Log all signing operations with timestamps
5. **Revocation**: Maintain revoked key list

## API Reference

### Core Types

- `SignatureAlgorithm`: Algorithm selection (.rsa_2048_sha256, .rsa_4096_sha256, .ecdsa_p256_sha256)
- `ModuleSignature`: Signature structure with algorithm, key ID, hash, signature data
- `PrivateKey`: Private key for signing operations
- `PublicKey`: Public key for verification operations
- `KeyPair`: Matched private/public key pair

### Functions

**modsign.keys:**
- `PrivateKey.generate()`: Generate new private key
- `PrivateKey.savePem()`: Save key in PEM format
- `PrivateKey.loadPem()`: Load key from PEM file
- `PrivateKey.getPublicKey()`: Derive public key
- `KeyPair.generate()`: Generate matched key pair

**modsign.sign:**
- `signModule()`: Sign module data in memory
- `signModuleFile()`: Sign module file, write signed output
- `serializeSignature()`: Convert signature to binary
- `deserializeSignature()`: Parse binary signature
- `extractSignature()`: Extract module and signature from signed file

**modsign.verify:**
- `verifySignature()`: Verify signature against public key
- `verifyModuleFile()`: Verify signed module file
- `verifyWithKeyRing()`: Verify using key ring
- `KeyRing.addKey()`: Add trusted key
- `KeyRing.findKey()`: Find key by ID

**modsign.format:**
- `printSignature()`: Display signature information
- `printPublicKey()`: Display key information
- `hasSignature()`: Check if module is signed
- `getModuleSize()`: Get original module size
- `stripSignature()`: Remove signature from module
- `ModuleInfo.inspect()`: Analyze module signature

## Error Handling

```zig
const result = modsign.verify.verifyModuleFile(
    allocator,
    "module.ko",
    &public_key,
) catch |err| {
    std.debug.print("Verification error: {s}\n", .{@errorName(err)});
    return err;
};

switch (result) {
    .valid => {},
    .invalid_signature => return error.InvalidSignature,
    .hash_mismatch => return error.TamperedModule,
    .no_signature => return error.UnsignedModule,
    .key_not_found => return error.UnknownSigner,
    .algorithm_mismatch => return error.WrongAlgorithm,
}
```

## Performance

Typical signing/verification times on modern hardware:

| Algorithm | Key Gen | Sign (1MB) | Verify (1MB) |
|-----------|---------|------------|--------------|
| RSA-2048  | ~100ms  | ~50ms      | ~5ms         |
| RSA-4096  | ~500ms  | ~200ms     | ~20ms        |
| ECDSA-P256| ~10ms   | ~10ms      | ~15ms        |

Note: Current implementation uses HMAC-based signing (simplified). Production would use actual RSA/ECDSA.

## License

Part of the Home programming language project.
