// TPM Sealing - Bind data to PCR state

const std = @import("std");
const pcr = @import("pcr.zig");

/// Sealed data structure
pub const SealedData = struct {
    /// PCR selection that must match to unseal
    pcr_selection: pcr.PcrSelection,
    /// Expected PCR values
    expected_pcrs: std.ArrayList(pcr.PcrValue),
    /// Encrypted data
    data: []u8,
    /// Authorization policy digest
    policy_digest: [32]u8,
    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SealedData {
        return .{
            .pcr_selection = pcr.PcrSelection.init(),
            .expected_pcrs = std.ArrayList(pcr.PcrValue){},
            .data = &[_]u8{},
            .policy_digest = [_]u8{0} ** 32,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SealedData) void {
        self.expected_pcrs.deinit();
        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
    }

    pub fn addExpectedPcr(self: *SealedData, pcr_value: pcr.PcrValue) !void {
        try self.expected_pcrs.append(self.allocator, pcr_value);
        try self.pcr_selection.select(pcr_value.index);
    }
};

/// Seal data to TPM PCRs
pub fn seal(
    allocator: std.mem.Allocator,
    data: []const u8,
    pcr_indices: []const pcr.PcrIndex,
) !SealedData {
    var sealed = SealedData.init(allocator);
    errdefer sealed.deinit();

    // Read current PCR values
    for (pcr_indices) |index| {
        const pcr_value = try pcr.readPcr(allocator, index);
        try sealed.addExpectedPcr(pcr_value);
    }

    // Compute policy digest (SHA-256 of PCR values)
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (sealed.expected_pcrs.items) |pcr_val| {
        hasher.update(pcr_val.getValue());
    }
    hasher.final(&sealed.policy_digest);

    // Encrypt data (simplified - real TPM uses AES with storage key)
    sealed.data = try allocator.alloc(u8, data.len);
    @memcpy(sealed.data, data);

    // XOR with policy digest for simple encryption
    for (sealed.data, 0..) |*byte, i| {
        byte.* ^= sealed.policy_digest[i % 32];
    }

    return sealed;
}

/// Unseal data (only if PCRs match)
pub fn unseal(
    allocator: std.mem.Allocator,
    sealed: *const SealedData,
) ![]u8 {
    // Read current PCR values
    const indices = try sealed.pcr_selection.getSelectedIndices(allocator);
    defer allocator.free(indices);

    // Verify PCRs match expected values
    for (indices) |index| {
        const current = try pcr.readPcr(allocator, index);

        // Find expected value for this PCR
        var found = false;
        for (sealed.expected_pcrs.items) |expected| {
            if (expected.index == index) {
                if (!std.mem.eql(u8, current.getValue(), expected.getValue())) {
                    return error.PcrMismatch;
                }
                found = true;
                break;
            }
        }

        if (!found) {
            return error.PcrNotFound;
        }
    }

    // PCRs match - decrypt data
    const unsealed = try allocator.alloc(u8, sealed.data.len);
    @memcpy(unsealed, sealed.data);

    // XOR with policy digest to decrypt
    for (unsealed, 0..) |*byte, i| {
        byte.* ^= sealed.policy_digest[i % 32];
    }

    return unsealed;
}

/// Seal data with authorization
pub fn sealWithAuth(
    allocator: std.mem.Allocator,
    data: []const u8,
    pcr_indices: []const pcr.PcrIndex,
    auth_value: []const u8,
) !SealedData {
    var sealed = try seal(allocator, data, pcr_indices);
    errdefer sealed.deinit();

    // Mix auth value into policy digest
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&sealed.policy_digest);
    hasher.update(auth_value);
    hasher.final(&sealed.policy_digest);

    // Re-encrypt with new policy
    for (sealed.data, 0..) |*byte, i| {
        byte.* ^= sealed.policy_digest[i % 32];
    }

    return sealed;
}

/// Unseal data with authorization
pub fn unsealWithAuth(
    allocator: std.mem.Allocator,
    sealed: *const SealedData,
    auth_value: []const u8,
) ![]u8 {
    // Verify auth value by recomputing policy
    var policy_check: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Hash PCR values
    for (sealed.expected_pcrs.items) |pcr_val| {
        hasher.update(pcr_val.getValue());
    }
    hasher.final(&policy_check);

    // Mix with auth value
    hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&policy_check);
    hasher.update(auth_value);
    hasher.final(&policy_check);

    if (!std.mem.eql(u8, &policy_check, &sealed.policy_digest)) {
        return error.AuthorizationFailed;
    }

    // Auth verified - unseal
    return unseal(allocator, sealed);
}

test "seal and unseal" {
    const testing = std.testing;

    const secret = "my_secret_data";
    const indices = [_]pcr.PcrIndex{ 7, 8 };

    var sealed = try seal(testing.allocator, secret, &indices);
    defer sealed.deinit();

    const unsealed = try unseal(testing.allocator, &sealed);
    defer testing.allocator.free(unsealed);

    try testing.expectEqualStrings(secret, unsealed);
}

test "seal with authorization" {
    const testing = std.testing;

    const secret = "secret_key";
    const indices = [_]pcr.PcrIndex{7};
    const auth = "password123";

    var sealed = try sealWithAuth(testing.allocator, secret, &indices, auth);
    defer sealed.deinit();

    // Correct auth should work
    const unsealed = try unsealWithAuth(testing.allocator, &sealed, auth);
    defer testing.allocator.free(unsealed);

    try testing.expectEqualStrings(secret, unsealed);

    // Wrong auth should fail
    const wrong_result = unsealWithAuth(testing.allocator, &sealed, "wrong");
    try testing.expectError(error.AuthorizationFailed, wrong_result);
}
