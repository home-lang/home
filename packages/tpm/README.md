# TPM (Trusted Platform Module) Package

A comprehensive TPM 2.0 library for Home, providing hardware-backed security operations including PCR management, data sealing, remote attestation, and cryptographic key operations.

## Overview

The TPM package provides a user-space interface to Trusted Platform Module (TPM) 2.0 hardware, enabling:

- **Platform Configuration Registers (PCRs)**: Measure and verify system state
- **Data Sealing**: Bind secrets to specific system configurations
- **Remote Attestation**: Prove system state to remote parties
- **Key Management**: Hardware-backed cryptographic keys
- **Hardware RNG**: True random number generation

## Quick Start

```zig
const std = @import("std");
const tpm = @import("tpm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize TPM context
    const ctx = try tpm.Context.init(allocator);
    defer ctx.deinit();

    // Check capabilities
    if (ctx.capabilities.tpm2_0) {
        std.debug.print("TPM 2.0 detected\n", .{});
    }

    // Get random bytes from hardware RNG
    var random_bytes: [32]u8 = undefined;
    try ctx.getRandomBytes(&random_bytes);
}
```

## Platform Configuration Registers (PCRs)

PCRs are hardware registers that store cryptographic measurements of system state. TPM 2.0 provides 24 PCRs (0-23).

### Standard PCR Allocation

```zig
const pcr = @import("tpm").pcr;

// Standard PCRs for measured boot
const firmware_pcr = pcr.StandardPcrs.FIRMWARE;        // PCR 0
const boot_loader_pcr = pcr.StandardPcrs.BOOT_LOADER;  // PCR 4
const secure_boot_pcr = pcr.StandardPcrs.SECURE_BOOT;  // PCR 7
const kernel_pcr = pcr.StandardPcrs.KERNEL;            // PCR 8
```

### Reading PCR Values

```zig
const pcr_value = try pcr.readPcr(allocator, 0);
defer allocator.free(pcr_value.getValue());

std.debug.print("PCR[0]: {}\n", .{pcr_value});
// Output: PCR[0] = a1b2c3d4e5f6...
```

### Extending PCRs

PCRs use extend operations: `PCR_new = Hash(PCR_old || measurement)`

```zig
const measurement = "bootloader_v1.2.3";
try pcr.extendPcr(allocator, pcr.StandardPcrs.BOOT_LOADER, measurement);
```

### PCR Selection

Select multiple PCRs for operations:

```zig
var selection = pcr.PcrSelection.init();
try selection.select(0);  // Firmware
try selection.select(7);  // Secure boot
try selection.select(8);  // Kernel

// Select range
try selection.selectRange(0, 9);  // PCRs 0-9

// Get selected indices
const indices = try selection.getSelectedIndices(allocator);
defer allocator.free(indices);
```

### Hash Algorithms

TPM supports multiple hash algorithms:

```zig
const pcr_sha256 = pcr.PcrValue.init(0, .sha256);  // 32 bytes
const pcr_sha384 = pcr.PcrValue.init(0, .sha384);  // 48 bytes
const pcr_sha512 = pcr.PcrValue.init(0, .sha512);  // 64 bytes
```

## Data Sealing

Seal (encrypt) data so it can only be unsealed when PCRs match expected values.

### Basic Sealing

```zig
const seal = @import("tpm").seal;

const secret = "my_encryption_key";
const pcr_indices = [_]u8{ 7, 8 };  // Secure boot + Kernel

// Seal data to current PCR state
var sealed = try seal.seal(allocator, secret, &pcr_indices);
defer sealed.deinit();

// Later: unseal (only works if PCRs unchanged)
const unsealed = try seal.unseal(allocator, &sealed);
defer allocator.free(unsealed);

std.debug.print("Secret: {s}\n", .{unsealed});
```

### Sealing with Authorization

Add password protection on top of PCR binding:

```zig
const secret = "database_password";
const pcr_indices = [_]u8{7};
const password = "user_password_123";

// Seal with both PCR state and password
var sealed = try seal.sealWithAuth(
    allocator,
    secret,
    &pcr_indices,
    password,
);
defer sealed.deinit();

// Unseal requires correct password AND matching PCRs
const unsealed = try seal.unsealWithAuth(
    allocator,
    &sealed,
    password,
);
defer allocator.free(unsealed);

// Wrong password fails
const wrong = seal.unsealWithAuth(allocator, &sealed, "wrong");
// Returns error.AuthorizationFailed
```

### Use Cases

- **Disk Encryption Keys**: Seal LUKS keys to boot state
- **Configuration Secrets**: Protect API keys, credentials
- **License Keys**: Bind licenses to specific hardware
- **Secure Boot**: Ensure secrets only accessible in verified state

## Remote Attestation

Prove system state to remote parties using signed PCR quotes.

### Attestation Flow

```zig
const attestation = @import("tpm").attestation;

// 1. Verifier creates challenge
var challenge = attestation.AttestationChallenge.init();
try challenge.withPcrs(&[_]u8{ 0, 7, 8 });  // Request firmware, secure boot, kernel

// 2. Prover generates quote (signed statement of PCR values)
const indices = try challenge.pcr_selection.getSelectedIndices(allocator);
defer allocator.free(indices);

var quote = try attestation.generateQuote(
    allocator,
    &challenge.nonce,
    indices,
);
defer quote.deinit();

// 3. Verifier checks quote
const aik_public_key = loadAttestationKey();
const valid = try attestation.verifyAttestation(
    allocator,
    &challenge,
    &quote,
    aik_public_key,
);

if (valid) {
    std.debug.print("System state verified!\n", .{});
}
```

### Quote Structure

```zig
pub const Quote = struct {
    nonce: [32]u8,              // Prevents replay attacks
    pcr_selection: PcrSelection, // Which PCRs included
    pcr_values: []PcrValue,      // PCR values at quote time
    signature: []u8,             // Signed by AIK
    timestamp: i64,              // When quote was generated
};
```

### Verifying Expected PCR Values

Check if quote matches known-good values:

```zig
var expected = attestation.ExpectedPcrs.init(allocator);
defer expected.deinit();

// Add expected PCR values (from reference system)
const good_firmware = try pcr.readPcr(allocator, 0);
try expected.expect(good_firmware);

const good_kernel = try pcr.readPcr(allocator, 8);
try expected.expect(good_kernel);

// Verify quote matches expectations
const matches = try expected.verify(&quote);
if (!matches) {
    return error.SystemStateMismatch;
}
```

### Attestation Security

- **Nonce**: Prevents replay attacks (each challenge unique)
- **Timestamp**: 5-minute validity window
- **AIK Signature**: Cryptographically binds quote to TPM
- **PCR Values**: Immutable measurement chain from boot

## Key Management

TPM provides hardware-backed cryptographic keys that never leave the chip.

### Key Types

```zig
const keys = @import("tpm").keys;

// Storage keys: encrypt other keys (key hierarchy)
const storage_key = try keys.createPrimary(
    allocator,
    keys.KeyHandle.OWNER,
    .storage,
    .rsa_2048,
);

// Signing keys: digital signatures
const signing_key = try keys.createPrimary(
    allocator,
    keys.KeyHandle.OWNER,
    .signing,
    .ecc_p256,
);

// Encryption keys: data encryption
const encryption_key = try keys.createPrimary(
    allocator,
    keys.KeyHandle.OWNER,
    .encryption,
    .rsa_3072,
);
```

### Algorithms

```zig
// RSA options
.rsa_2048  // 2048-bit RSA
.rsa_3072  // 3072-bit RSA
.rsa_4096  // 4096-bit RSA

// ECC options
.ecc_p256  // NIST P-256 (secp256r1)
.ecc_p384  // NIST P-384 (secp384r1)
.ecc_p521  // NIST P-521 (secp521r1)
```

### Signing Data

```zig
var signing_key = try keys.createPrimary(
    allocator,
    keys.KeyHandle.OWNER,
    .signing,
    .ecc_p256,
);
defer signing_key.deinit();

const message = "Important contract v1.2.3";
const signature = try signing_key.sign(allocator, message);
defer allocator.free(signature);

// Verify signature
const valid = try signing_key.verify(message, signature);
```

### Encrypting Data

```zig
var encryption_key = try keys.createPrimary(
    allocator,
    keys.KeyHandle.OWNER,
    .encryption,
    .rsa_2048,
);
defer encryption_key.deinit();

const plaintext = "secret data";
const ciphertext = try encryption_key.encrypt(allocator, plaintext);
defer allocator.free(ciphertext);

const decrypted = try encryption_key.decrypt(allocator, ciphertext);
defer allocator.free(decrypted);
```

### Key Attributes

```zig
const attrs = keys.KeyAttributes{
    .fixed_tpm = true,           // Key bound to this TPM
    .fixed_parent = true,        // Key bound to parent
    .sensitive_data_origin = true, // TPM generated key
    .user_with_auth = true,      // Requires authorization
    .sign = true,                // Can sign
    .decrypt = false,            // Cannot decrypt
};
```

## Complete Example: Secure Boot Verification

```zig
const std = @import("std");
const tpm = @import("tpm");

pub fn verifySecureBoot(allocator: std.mem.Allocator) !bool {
    // Initialize TPM
    const ctx = try tpm.Context.init(allocator);
    defer ctx.deinit();

    // Read boot-critical PCRs
    const firmware = try tpm.pcr.readPcr(allocator, 0);
    const boot_loader = try tpm.pcr.readPcr(allocator, 4);
    const secure_boot = try tpm.pcr.readPcr(allocator, 7);
    const kernel = try tpm.pcr.readPcr(allocator, 8);

    // Set up expected values
    var expected = tpm.attestation.ExpectedPcrs.init(allocator);
    defer expected.deinit();

    try expected.expect(loadExpectedPcr(allocator, 0));
    try expected.expect(loadExpectedPcr(allocator, 4));
    try expected.expect(loadExpectedPcr(allocator, 7));
    try expected.expect(loadExpectedPcr(allocator, 8));

    // Generate attestation quote
    const pcr_indices = [_]u8{ 0, 4, 7, 8 };
    var quote = try tpm.attestation.generateQuote(
        allocator,
        "nonce_from_verifier",
        &pcr_indices,
    );
    defer quote.deinit();

    // Verify quote matches expected state
    return try expected.verify(&quote);
}

fn loadExpectedPcr(allocator: std.mem.Allocator, index: u8) !tpm.pcr.PcrValue {
    // In production, load from signed reference manifest
    return try tpm.pcr.readPcr(allocator, index);
}
```

## API Reference

### Core Modules

- **tpm.zig**: Context initialization, capabilities, RNG
- **pcr.zig**: PCR read/extend/reset, selection, banks
- **seal.zig**: Data sealing/unsealing with PCR binding
- **attestation.zig**: Quote generation, challenge-response
- **keys.zig**: Key creation, signing, encryption

### Error Types

```zig
error.InvalidPcrIndex       // PCR index >= 24
error.PcrNotResettable      // Tried to reset PCR < 16
error.PcrMismatch           // Unseal failed: PCR changed
error.AuthorizationFailed   // Wrong password
error.NoHardwareRng         // TPM lacks RNG capability
error.InvalidSignature      // Signature verification failed
```

## Best Practices

### Security

1. **Seal sensitive data**: Never store secrets in plaintext
2. **Use attestation**: Verify remote system state before trusting
3. **Bind to multiple PCRs**: Increases security depth
4. **Rotate keys**: Don't reuse signing/encryption keys indefinitely
5. **Validate timestamps**: Reject old quotes (replay protection)

### Performance

1. **Cache PCR reads**: PCRs change infrequently
2. **Batch operations**: Group seal/unseal operations
3. **Choose appropriate algorithms**: ECC P-256 faster than RSA 4096
4. **Minimize quote size**: Only include necessary PCRs

### Integration

```zig
// Early boot: Extend PCRs
try tpm.pcr.extendPcr(allocator, 4, bootloader_hash);
try tpm.pcr.extendPcr(allocator, 8, kernel_hash);

// Application startup: Unseal secrets
const db_key = try tpm.seal.unseal(allocator, &sealed_key);
defer allocator.free(db_key);

// Runtime: Generate attestation on demand
const quote = try tpm.attestation.generateQuote(
    allocator,
    &challenge.nonce,
    &[_]u8{ 0, 7, 8 },
);
```

## Hardware vs Simulation

This implementation provides a simulated TPM for development:

- **PCR values**: Deterministic based on index
- **Signatures**: SHA-256 HMAC instead of RSA/ECC
- **RNG**: Uses `std.crypto.random` instead of hardware

For production, extend with:
- `/dev/tpm0` device communication
- TSS2 ESAPI integration
- Hardware-backed key operations
- Actual TPM command marshalling

## References

- [TCG TPM 2.0 Library Specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/)
- [TPM2 Software Stack (TSS2)](https://github.com/tpm2-software/tpm2-tss)
- [Measured Boot](https://www.kernel.org/doc/html/latest/security/keys/trusted-encrypted.html)
- [Remote Attestation](https://tpm2-software.github.io/tpm2-tss/getting-started/2019/12/18/Remote-Attestation.html)

## License

Part of the Home programming language project.
