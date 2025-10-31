// Module signature format utilities

const std = @import("std");
const modsign = @import("modsign.zig");

/// Signature file format magic
pub const MAGIC = "MODSIG\x00\x01";

/// Format version
pub const VERSION: u8 = 1;

/// Display signature information
pub fn printSignature(
    sig: *const modsign.ModuleSignature,
    writer: anytype,
) !void {
    try writer.print("Module Signature:\n", .{});
    try writer.print("  Algorithm: {s}\n", .{sig.algorithm.name()});
    try writer.print("  Key ID: ", .{});
    for (sig.key_id) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.print("\n", .{});

    try writer.print("  Hash: ", .{});
    for (sig.module_hash[0..sig.hash_len]) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.print("\n", .{});

    try writer.print("  Signature Length: {d} bytes\n", .{sig.signature.len});
}

/// Display key information
pub fn printPublicKey(
    key: anytype,
    writer: anytype,
) !void {
    try writer.print("Public Key:\n", .{});
    try writer.print("  Algorithm: {s}\n", .{key.algorithm.name()});
    try writer.print("  Description: {s}\n", .{key.description});
    try writer.print("  Key ID: ", .{});
    for (key.key_id) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.print("\n", .{});
    try writer.print("  Key Size: {d} bytes\n", .{key.key_data.len});
}

/// Get signature summary string
pub fn signatureSummary(
    allocator: std.mem.Allocator,
    sig: *const modsign.ModuleSignature,
) ![]u8 {
    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);

    const writer = list.writer(allocator);

    // Key ID (first 8 bytes in hex)
    try writer.print("{s} key:", .{sig.algorithm.name()});
    for (sig.key_id[0..8]) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }

    return list.toOwnedSlice(allocator);
}

/// Check if data has module signature appended
pub fn hasSignature(data: []const u8) bool {
    const magic = "~Module signature appended~\n";

    if (data.len < magic.len + 4) {
        return false;
    }

    const magic_start = data.len - magic.len - 4;
    const found_magic = data[magic_start..][0..magic.len];

    return std.mem.eql(u8, found_magic, magic);
}

/// Get module size without signature
pub fn getModuleSize(signed_data: []const u8) usize {
    if (!hasSignature(signed_data)) {
        return signed_data.len;
    }

    const magic = "~Module signature appended~\n";
    const sig_len = std.mem.readInt(
        u32,
        signed_data[signed_data.len - 4 ..][0..4],
        .little,
    );

    const magic_start = signed_data.len - magic.len - 4;
    return magic_start - sig_len;
}

/// Strip signature from signed module
pub fn stripSignature(
    allocator: std.mem.Allocator,
    signed_data: []const u8,
) ![]u8 {
    const module_size = getModuleSize(signed_data);
    const unsigned = try allocator.alloc(u8, module_size);
    @memcpy(unsigned, signed_data[0..module_size]);
    return unsigned;
}

/// Format module info
pub const ModuleInfo = struct {
    has_signature: bool,
    module_size: usize,
    signature_size: ?usize,
    algorithm: ?modsign.SignatureAlgorithm,
    key_id: ?[32]u8,

    pub fn inspect(allocator: std.mem.Allocator, data: []const u8) !ModuleInfo {
        var info = ModuleInfo{
            .has_signature = hasSignature(data),
            .module_size = 0,
            .signature_size = null,
            .algorithm = null,
            .key_id = null,
        };

        if (!info.has_signature) {
            info.module_size = data.len;
            return info;
        }

        const magic = "~Module signature appended~\n";
        const sig_len = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);

        const magic_start = data.len - magic.len - 4;
        info.module_size = magic_start - sig_len;
        info.signature_size = sig_len;

        // Try to parse signature to get algorithm and key ID
        const sig_start = magic_start - sig_len;
        const sig_bytes = data[sig_start..magic_start];

        if (sig_bytes.len > 33) {
            info.algorithm = @enumFromInt(sig_bytes[0]);
            var key_id: [32]u8 = undefined;
            @memcpy(&key_id, sig_bytes[1..33]);
            info.key_id = key_id;
        }

        _ = allocator;
        return info;
    }

    pub fn print(self: *const ModuleInfo, writer: anytype) !void {
        try writer.print("Module Information:\n", .{});
        try writer.print("  Module Size: {d} bytes\n", .{self.module_size});
        try writer.print("  Signed: {s}\n", .{if (self.has_signature) "Yes" else "No"});

        if (self.signature_size) |size| {
            try writer.print("  Signature Size: {d} bytes\n", .{size});
        }

        if (self.algorithm) |algo| {
            try writer.print("  Algorithm: {s}\n", .{algo.name()});
        }

        if (self.key_id) |key_id| {
            try writer.print("  Key ID: ", .{});
            for (key_id[0..16]) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.print("...\n", .{});
        }
    }
};

test "signature detection" {
    const testing = std.testing;

    const unsigned = "module data";
    try testing.expect(!hasSignature(unsigned));

    const magic = "~Module signature appended~\n";
    var sig_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &sig_len_buf, 10, .little);

    const signed = try std.mem.concat(testing.allocator, u8, &[_][]const u8{
        unsigned,
        "fake_sig\x00\x00",
        magic,
        &sig_len_buf,
    });
    defer testing.allocator.free(signed);

    try testing.expect(hasSignature(signed));
    try testing.expectEqual(@as(usize, unsigned.len), getModuleSize(signed));
}

test "module info" {
    const testing = std.testing;

    const data = "simple module";
    const info = try ModuleInfo.inspect(testing.allocator, data);

    try testing.expect(!info.has_signature);
    try testing.expectEqual(@as(usize, data.len), info.module_size);
}
