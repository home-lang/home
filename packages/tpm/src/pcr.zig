// PCR (Platform Configuration Register) Management

const std = @import("std");

/// PCR index (0-23 for TPM 2.0)
pub const PcrIndex = u8;

/// PCR hash algorithm
pub const HashAlgorithm = enum {
    sha1, // TPM 1.2
    sha256, // TPM 2.0 default
    sha384,
    sha512,

    pub fn hashSize(self: HashAlgorithm) usize {
        return switch (self) {
            .sha1 => 20,
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
    }
};

/// PCR value
pub const PcrValue = struct {
    index: PcrIndex,
    algorithm: HashAlgorithm,
    value: [64]u8, // Max SHA-512 size
    value_len: usize,

    pub fn init(index: PcrIndex, algorithm: HashAlgorithm) PcrValue {
        return .{
            .index = index,
            .algorithm = algorithm,
            .value = [_]u8{0} ** 64,
            .value_len = algorithm.hashSize(),
        };
    }

    pub fn getValue(self: *const PcrValue) []const u8 {
        return self.value[0..self.value_len];
    }

    pub fn format(
        self: PcrValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("PCR[{d}] = ", .{self.index});
        for (self.getValue()) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
    }
};

/// PCR bank (set of PCRs for specific hash algorithm)
pub const PcrBank = struct {
    algorithm: HashAlgorithm,
    pcrs: std.AutoHashMap(PcrIndex, PcrValue),

    pub fn init(allocator: std.mem.Allocator, algorithm: HashAlgorithm) PcrBank {
        return .{
            .algorithm = algorithm,
            .pcrs = std.AutoHashMap(PcrIndex, PcrValue).init(allocator),
        };
    }

    pub fn deinit(self: *PcrBank) void {
        self.pcrs.deinit();
    }

    pub fn setPcr(self: *PcrBank, index: PcrIndex, value: []const u8) !void {
        if (value.len != self.algorithm.hashSize()) {
            return error.InvalidPcrValueLength;
        }

        var pcr = PcrValue.init(index, self.algorithm);
        @memcpy(pcr.value[0..value.len], value);
        try self.pcrs.put(index, pcr);
    }

    pub fn getPcr(self: *PcrBank, index: PcrIndex) ?PcrValue {
        return self.pcrs.get(index);
    }
};

/// Standard PCR allocation for measured boot
pub const StandardPcrs = struct {
    /// PCR 0: BIOS/UEFI firmware
    pub const FIRMWARE: PcrIndex = 0;
    /// PCR 1: Firmware configuration
    pub const FIRMWARE_CONFIG: PcrIndex = 1;
    /// PCR 2: Option ROM code
    pub const OPTION_ROM: PcrIndex = 2;
    /// PCR 3: Option ROM configuration
    pub const OPTION_ROM_CONFIG: PcrIndex = 3;
    /// PCR 4: Boot loader code
    pub const BOOT_LOADER: PcrIndex = 4;
    /// PCR 5: Boot loader configuration
    pub const BOOT_LOADER_CONFIG: PcrIndex = 5;
    /// PCR 6: State transitions
    pub const STATE_TRANSITIONS: PcrIndex = 6;
    /// PCR 7: Secure boot policy
    pub const SECURE_BOOT: PcrIndex = 7;
    /// PCR 8: Kernel/OS loader
    pub const KERNEL: PcrIndex = 8;
    /// PCR 9: Kernel modules/drivers
    pub const KERNEL_MODULES: PcrIndex = 9;
    /// PCR 10: Application-specific
    pub const APPLICATION: PcrIndex = 10;
    /// PCR 11-15: Reserved
    /// PCR 16-23: Debug/resettable
    pub const DEBUG_START: PcrIndex = 16;
};

/// Read PCR value
pub fn readPcr(allocator: std.mem.Allocator, index: PcrIndex) !PcrValue {
    _ = allocator;

    if (index >= 24) {
        return error.InvalidPcrIndex;
    }

    // In production, would communicate with TPM device
    // For now, return simulated value
    var pcr = PcrValue.init(index, .sha256);

    // Generate deterministic "PCR value" based on index
    for (pcr.value[0..pcr.value_len], 0..) |*byte, i| {
        byte.* = @truncate((index *% 17 +% @as(u8, @truncate(i))) *% 0x9e);
    }

    return pcr;
}

/// Extend PCR with measurement
pub fn extendPcr(
    allocator: std.mem.Allocator,
    index: PcrIndex,
    measurement: []const u8,
) !void {
    _ = allocator;

    if (index >= 24) {
        return error.InvalidPcrIndex;
    }

    // In production, would send TPM2_PCR_Extend command
    // PCR_new = Hash(PCR_old || measurement)
    _ = measurement;
}

/// Reset PCR (only allowed for debug PCRs 16-23)
pub fn resetPcr(allocator: std.mem.Allocator, index: PcrIndex) !void {
    _ = allocator;

    if (index < StandardPcrs.DEBUG_START) {
        return error.PcrNotResettable;
    }

    if (index >= 24) {
        return error.InvalidPcrIndex;
    }

    // In production, would send TPM2_PCR_Reset command
}

/// PCR selection (bitmask of PCRs)
pub const PcrSelection = struct {
    mask: [3]u8, // 24 bits for 24 PCRs

    pub fn init() PcrSelection {
        return .{ .mask = [_]u8{0} ** 3 };
    }

    pub fn select(self: *PcrSelection, index: PcrIndex) !void {
        if (index >= 24) {
            return error.InvalidPcrIndex;
        }

        const byte_idx = index / 8;
        const bit_idx = @as(u3, @truncate(index % 8));
        self.mask[byte_idx] |= @as(u8, 1) << bit_idx;
    }

    pub fn isSelected(self: *const PcrSelection, index: PcrIndex) bool {
        if (index >= 24) return false;

        const byte_idx = index / 8;
        const bit_idx = @as(u3, @truncate(index % 8));
        return (self.mask[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    pub fn selectRange(self: *PcrSelection, start: PcrIndex, end: PcrIndex) !void {
        var i = start;
        while (i <= end) : (i += 1) {
            try self.select(i);
        }
    }

    pub fn getSelectedIndices(self: *const PcrSelection, allocator: std.mem.Allocator) ![]PcrIndex {
        var indices = std.ArrayList(PcrIndex){};

        var i: PcrIndex = 0;
        while (i < 24) : (i += 1) {
            if (self.isSelected(i)) {
                try indices.append(allocator, i);
            }
        }

        return indices.toOwnedSlice(allocator);
    }
};

test "pcr value" {
    const testing = std.testing;

    var pcr = PcrValue.init(0, .sha256);
    try testing.expectEqual(@as(usize, 32), pcr.getValue().len);
}

test "pcr bank" {
    const testing = std.testing;

    var bank = PcrBank.init(testing.allocator, .sha256);
    defer bank.deinit();

    const value = [_]u8{0x12} ** 32;
    try bank.setPcr(0, &value);

    const pcr = bank.getPcr(0);
    try testing.expect(pcr != null);
    try testing.expectEqual(@as(PcrIndex, 0), pcr.?.index);
}

test "pcr selection" {
    const testing = std.testing;

    var sel = PcrSelection.init();
    try sel.select(0);
    try sel.select(7);
    try sel.select(16);

    try testing.expect(sel.isSelected(0));
    try testing.expect(sel.isSelected(7));
    try testing.expect(sel.isSelected(16));
    try testing.expect(!sel.isSelected(1));

    const indices = try sel.getSelectedIndices(testing.allocator);
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 3), indices.len);
}
