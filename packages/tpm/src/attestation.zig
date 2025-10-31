// TPM Attestation - Remote attestation and quotes

const std = @import("std");
const pcr = @import("pcr.zig");

/// TPM Quote - signed statement of PCR values
pub const Quote = struct {
    /// Nonce from challenger (prevents replay)
    nonce: [32]u8,
    /// PCR selection
    pcr_selection: pcr.PcrSelection,
    /// PCR values at quote time
    pcr_values: std.ArrayList(pcr.PcrValue),
    /// Quote signature (signed by AIK)
    signature: []u8,
    /// Timestamp
    timestamp: i64,
    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Quote {
        return .{
            .nonce = [_]u8{0} ** 32,
            .pcr_selection = pcr.PcrSelection.init(),
            .pcr_values = std.ArrayList(pcr.PcrValue){},
            .signature = &[_]u8{},
            .timestamp = std.time.timestamp(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Quote) void {
        self.pcr_values.deinit();
        if (self.signature.len > 0) {
            self.allocator.free(self.signature);
        }
    }

    /// Verify quote signature
    pub fn verify(self: *const Quote, public_key: []const u8) !bool {
        _ = public_key;

        // In production, would verify RSA/ECC signature
        // For now, just check signature is non-zero
        if (self.signature.len == 0) {
            return false;
        }

        for (self.signature) |byte| {
            if (byte != 0) return true;
        }

        return false;
    }

    pub fn format(
        self: Quote,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Quote(timestamp={d}, pcrs={d}, signature_len={d})\n", .{
            self.timestamp,
            self.pcr_values.items.len,
            self.signature.len,
        });

        for (self.pcr_values.items) |pcr_val| {
            try writer.print("  {}\n", .{pcr_val});
        }
    }
};

/// Generate TPM quote
pub fn generateQuote(
    allocator: std.mem.Allocator,
    nonce: []const u8,
    pcr_indices: []const pcr.PcrIndex,
) !Quote {
    var quote = Quote.init(allocator);
    errdefer quote.deinit();

    // Copy nonce
    const nonce_len = @min(nonce.len, 32);
    @memcpy(quote.nonce[0..nonce_len], nonce[0..nonce_len]);

    // Read current PCR values
    for (pcr_indices) |index| {
        const pcr_value = try pcr.readPcr(allocator, index);
        try quote.pcr_values.append(allocator, pcr_value);
        try quote.pcr_selection.select(index);
    }

    // Generate signature (in production, TPM would sign with AIK)
    // For now, create a simple hash-based signature
    quote.signature = try allocator.alloc(u8, 32);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&quote.nonce);

    for (quote.pcr_values.items) |pcr_val| {
        hasher.update(pcr_val.getValue());
    }

    hasher.final(quote.signature[0..32]);

    return quote;
}

/// Attestation challenge-response
pub const AttestationChallenge = struct {
    nonce: [32]u8,
    pcr_selection: pcr.PcrSelection,
    timestamp: i64,

    pub fn init() AttestationChallenge {
        var challenge: AttestationChallenge = undefined;
        std.crypto.random.bytes(&challenge.nonce);
        challenge.pcr_selection = pcr.PcrSelection.init();
        challenge.timestamp = std.time.timestamp();
        return challenge;
    }

    pub fn withPcrs(self: *AttestationChallenge, indices: []const pcr.PcrIndex) !void {
        for (indices) |index| {
            try self.pcr_selection.select(index);
        }
    }
};

/// Verify attestation quote matches challenge
pub fn verifyAttestation(
    allocator: std.mem.Allocator,
    challenge: *const AttestationChallenge,
    quote: *const Quote,
    public_key: []const u8,
) !bool {

    // Verify nonce matches
    if (!std.mem.eql(u8, &challenge.nonce, &quote.nonce)) {
        return false;
    }

    // Verify timestamp (quote should be recent)
    const now = std.time.timestamp();
    const age = now - quote.timestamp;
    if (age < 0 or age > 300) { // 5 minute window
        return false;
    }

    // Verify signature
    if (!try quote.verify(public_key)) {
        return false;
    }

    // Verify all requested PCRs are present
    const requested_indices = try challenge.pcr_selection.getSelectedIndices(allocator);
    defer allocator.free(requested_indices);

    for (requested_indices) |index| {
        var found = false;
        for (quote.pcr_values.items) |pcr_val| {
            if (pcr_val.index == index) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    return true;
}

/// Expected PCR values for attestation
pub const ExpectedPcrs = struct {
    values: std.AutoHashMap(pcr.PcrIndex, pcr.PcrValue),

    pub fn init(allocator: std.mem.Allocator) ExpectedPcrs {
        return .{
            .values = std.AutoHashMap(pcr.PcrIndex, pcr.PcrValue).init(allocator),
        };
    }

    pub fn deinit(self: *ExpectedPcrs) void {
        self.values.deinit();
    }

    pub fn expect(self: *ExpectedPcrs, pcr_value: pcr.PcrValue) !void {
        try self.values.put(pcr_value.index, pcr_value);
    }

    /// Verify quote PCRs match expected values
    pub fn verify(self: *const ExpectedPcrs, quote: *const Quote) !bool {
        for (quote.pcr_values.items) |pcr_val| {
            if (self.values.get(pcr_val.index)) |expected| {
                if (!std.mem.eql(u8, expected.getValue(), pcr_val.getValue())) {
                    return false;
                }
            }
        }
        return true;
    }
};

test "generate quote" {
    const testing = std.testing;

    const nonce = "challenge_nonce_12345";
    const indices = [_]pcr.PcrIndex{ 0, 7, 8 };

    var quote = try generateQuote(testing.allocator, nonce, &indices);
    defer quote.deinit();

    try testing.expectEqual(@as(usize, 3), quote.pcr_values.items.len);
    try testing.expect(quote.signature.len > 0);
}

test "attestation challenge-response" {
    const testing = std.testing;

    // Create challenge
    var challenge = AttestationChallenge.init();
    try challenge.withPcrs(&[_]pcr.PcrIndex{ 0, 7 });

    // Generate quote
    const indices = try challenge.pcr_selection.getSelectedIndices(testing.allocator);
    defer testing.allocator.free(indices);

    var quote = try generateQuote(testing.allocator, &challenge.nonce, indices);
    defer quote.deinit();

    // Verify attestation
    const public_key = "fake_public_key";
    const valid = try verifyAttestation(testing.allocator, &challenge, &quote, public_key);
    try testing.expect(valid);
}

test "expected pcrs" {
    const testing = std.testing;

    var expected = ExpectedPcrs.init(testing.allocator);
    defer expected.deinit();

    const pcr_val = try pcr.readPcr(testing.allocator, 0);
    try expected.expect(pcr_val);

    var quote = try generateQuote(testing.allocator, "nonce", &[_]pcr.PcrIndex{0});
    defer quote.deinit();

    const matches = try expected.verify(&quote);
    try testing.expect(matches);
}
