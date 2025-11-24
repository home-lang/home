// Home Video Library - DRM/Encryption Parsing (Read-Only)
// Common Encryption (CENC), Widevine, PlayReady, FairPlay metadata

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// DRM System Identifiers
// ============================================================================

pub const DrmSystem = enum {
    widevine,
    playready,
    fairplay,
    clearkey,
    primetime,
    unknown,

    /// Get system ID (UUID) for this DRM system
    pub fn systemId(self: DrmSystem) [16]u8 {
        return switch (self) {
            .widevine => .{ 0xED, 0xEF, 0x8B, 0xA9, 0x79, 0xD6, 0x4A, 0xCE, 0xA3, 0xC8, 0x27, 0xDC, 0xD5, 0x1D, 0x21, 0xED },
            .playready => .{ 0x9A, 0x04, 0xF0, 0x79, 0x98, 0x40, 0x42, 0x86, 0xAB, 0x92, 0xE6, 0x5B, 0xE0, 0x88, 0x5F, 0x95 },
            .fairplay => .{ 0x94, 0xCE, 0x86, 0xFB, 0x07, 0xFF, 0x4F, 0x43, 0xAD, 0xB8, 0x93, 0xD2, 0xFA, 0x96, 0x8C, 0xA2 },
            .clearkey => .{ 0x10, 0x77, 0xEF, 0xEC, 0xC0, 0xB2, 0x4D, 0x02, 0xAC, 0xE3, 0x3C, 0x1E, 0x52, 0xE2, 0xFB, 0x4B },
            .primetime => .{ 0xF2, 0x39, 0xE7, 0x69, 0xEF, 0xA3, 0x48, 0x50, 0x9C, 0x16, 0xA9, 0x03, 0xC6, 0x93, 0x2E, 0xFB },
            .unknown => .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        };
    }

    /// Get DRM system from UUID
    pub fn fromSystemId(uuid: [16]u8) DrmSystem {
        if (std.mem.eql(u8, &uuid, &DrmSystem.widevine.systemId())) return .widevine;
        if (std.mem.eql(u8, &uuid, &DrmSystem.playready.systemId())) return .playready;
        if (std.mem.eql(u8, &uuid, &DrmSystem.fairplay.systemId())) return .fairplay;
        if (std.mem.eql(u8, &uuid, &DrmSystem.clearkey.systemId())) return .clearkey;
        if (std.mem.eql(u8, &uuid, &DrmSystem.primetime.systemId())) return .primetime;
        return .unknown;
    }

    pub fn name(self: DrmSystem) []const u8 {
        return switch (self) {
            .widevine => "Widevine",
            .playready => "PlayReady",
            .fairplay => "FairPlay",
            .clearkey => "ClearKey",
            .primetime => "PrimeTime",
            .unknown => "Unknown",
        };
    }
};

// ============================================================================
// CENC (Common Encryption) - ISO/IEC 23001-7
// ============================================================================

pub const EncryptionScheme = enum {
    cenc, // AES-CTR (full sample)
    cbc1, // AES-CBC (full sample)
    cens, // AES-CTR (pattern)
    cbcs, // AES-CBC (pattern, with constant IV)
    none,

    pub fn fromFourCC(fourcc: [4]u8) EncryptionScheme {
        if (std.mem.eql(u8, &fourcc, "cenc")) return .cenc;
        if (std.mem.eql(u8, &fourcc, "cbc1")) return .cbc1;
        if (std.mem.eql(u8, &fourcc, "cens")) return .cens;
        if (std.mem.eql(u8, &fourcc, "cbcs")) return .cbcs;
        return .none;
    }
};

/// Protection System Specific Header (PSSH)
pub const PsshBox = struct {
    version: u8,
    flags: u24,
    system_id: [16]u8,
    key_ids: std.ArrayListUnmanaged([16]u8) = .empty, // v1 only
    data: []const u8,

    pub fn getDrmSystem(self: *const PsshBox) DrmSystem {
        return DrmSystem.fromSystemId(self.system_id);
    }

    pub fn deinit(self: *PsshBox, allocator: Allocator) void {
        self.key_ids.deinit(allocator);
    }
};

/// Track Encryption Box (tenc)
pub const TrackEncryption = struct {
    is_encrypted: bool,
    default_iv_size: u8,
    default_kid: [16]u8,
    default_constant_iv: ?[16]u8 = null,
    crypt_byte_block: u8 = 0, // For pattern encryption
    skip_byte_block: u8 = 0,
};

/// Sample Encryption Box (senc) entry
pub const SampleEncryptionEntry = struct {
    iv: [16]u8,
    subsample_count: u16 = 0,
    subsamples: []const Subsample = &.{},
};

pub const Subsample = struct {
    clear_bytes: u16,
    encrypted_bytes: u32,
};

// ============================================================================
// CENC Parser
// ============================================================================

pub const CencParser = struct {
    data: []const u8,
    offset: usize,
    allocator: Allocator,

    pub fn init(data: []const u8, allocator: Allocator) CencParser {
        return .{ .data = data, .offset = 0, .allocator = allocator };
    }

    /// Parse PSSH box
    pub fn parsePssh(self: *CencParser, box_data: []const u8) !PsshBox {
        if (box_data.len < 24) return error.InvalidPssh;

        const version = box_data[0];
        const flags: u24 = (@as(u24, box_data[1]) << 16) | (@as(u24, box_data[2]) << 8) | box_data[3];

        var pssh = PsshBox{
            .version = version,
            .flags = flags,
            .system_id = undefined,
            .data = &.{},
        };

        @memcpy(&pssh.system_id, box_data[4..20]);

        var offset: usize = 20;

        // Version 1: key IDs
        if (version == 1) {
            if (offset + 4 > box_data.len) return error.InvalidPssh;
            const key_id_count = std.mem.readInt(u32, box_data[offset..][0..4], .big);
            offset += 4;

            var i: u32 = 0;
            while (i < key_id_count) : (i += 1) {
                if (offset + 16 > box_data.len) break;
                var kid: [16]u8 = undefined;
                @memcpy(&kid, box_data[offset..][0..16]);
                try pssh.key_ids.append(self.allocator, kid);
                offset += 16;
            }
        }

        // Data
        if (offset + 4 <= box_data.len) {
            const data_size = std.mem.readInt(u32, box_data[offset..][0..4], .big);
            offset += 4;
            if (offset + data_size <= box_data.len) {
                pssh.data = box_data[offset..][0..data_size];
            }
        }

        return pssh;
    }

    /// Parse tenc (Track Encryption) box
    pub fn parseTenc(self: *CencParser, box_data: []const u8) !TrackEncryption {
        _ = self;
        if (box_data.len < 24) return error.InvalidTenc;

        const version = box_data[0];
        // const flags = box_data[1..4];

        var tenc = TrackEncryption{
            .is_encrypted = false,
            .default_iv_size = 0,
            .default_kid = undefined,
        };

        var offset: usize = 4;

        if (version == 0) {
            offset += 2; // Reserved
            tenc.is_encrypted = box_data[offset] != 0;
            offset += 1;
            tenc.default_iv_size = box_data[offset];
            offset += 1;
        } else {
            offset += 1; // Reserved
            tenc.crypt_byte_block = (box_data[offset] >> 4) & 0x0F;
            tenc.skip_byte_block = box_data[offset] & 0x0F;
            offset += 1;
            tenc.is_encrypted = box_data[offset] != 0;
            offset += 1;
            tenc.default_iv_size = box_data[offset];
            offset += 1;
        }

        if (offset + 16 <= box_data.len) {
            @memcpy(&tenc.default_kid, box_data[offset..][0..16]);
            offset += 16;
        }

        // Constant IV (for cbcs with 0 IV size)
        if (tenc.is_encrypted and tenc.default_iv_size == 0 and offset + 1 <= box_data.len) {
            const const_iv_size = box_data[offset];
            offset += 1;
            if (const_iv_size == 16 and offset + 16 <= box_data.len) {
                var iv: [16]u8 = undefined;
                @memcpy(&iv, box_data[offset..][0..16]);
                tenc.default_constant_iv = iv;
            }
        }

        return tenc;
    }

    /// Find all PSSH boxes in MP4 data
    pub fn findPsshBoxes(self: *CencParser) !std.ArrayListUnmanaged(PsshBox) {
        var boxes: std.ArrayListUnmanaged(PsshBox) = .empty;
        errdefer {
            for (boxes.items) |*b| b.deinit(self.allocator);
            boxes.deinit(self.allocator);
        }

        self.offset = 0;

        while (self.offset + 8 <= self.data.len) {
            const size = std.mem.readInt(u32, self.data[self.offset..][0..4], .big);
            const box_type = self.data[self.offset + 4 ..][0..4];

            if (size < 8) break;

            if (std.mem.eql(u8, box_type, "pssh")) {
                const box_data = self.data[self.offset + 8 ..][0 .. size - 8];
                const pssh = try self.parsePssh(box_data);
                try boxes.append(self.allocator, pssh);
            } else if (std.mem.eql(u8, box_type, "moov") or
                std.mem.eql(u8, box_type, "moof"))
            {
                // Recurse into container boxes
                self.offset += 8;
                continue;
            }

            self.offset += size;
        }

        return boxes;
    }
};

// ============================================================================
// Widevine-specific
// ============================================================================

pub const WidevineContentId = struct {
    content_id: []const u8,
    policy: ?[]const u8 = null,
    license_url: ?[]const u8 = null,
};

/// Parse Widevine PSSH data (protobuf format - simplified)
pub fn parseWidevineData(data: []const u8) ?WidevineContentId {
    // Widevine uses protobuf encoding
    // Field 2 = content_id (bytes)
    // Field 3 = policy (bytes)

    var result = WidevineContentId{ .content_id = &.{} };
    var offset: usize = 0;

    while (offset < data.len) {
        const tag = data[offset];
        offset += 1;

        const field_num = tag >> 3;
        const wire_type = tag & 0x07;

        if (wire_type == 2) {
            // Length-delimited
            if (offset >= data.len) break;
            const length = data[offset];
            offset += 1;

            if (offset + length > data.len) break;

            if (field_num == 2) {
                result.content_id = data[offset..][0..length];
            } else if (field_num == 3) {
                result.policy = data[offset..][0..length];
            }

            offset += length;
        } else if (wire_type == 0) {
            // Varint - skip
            while (offset < data.len and (data[offset] & 0x80) != 0) {
                offset += 1;
            }
            offset += 1;
        } else {
            break;
        }
    }

    return result;
}

// ============================================================================
// PlayReady-specific
// ============================================================================

pub const PlayReadyHeader = struct {
    version: []const u8,
    license_url: ?[]const u8 = null,
    key_ids: std.ArrayListUnmanaged([16]u8) = .empty,
};

/// Parse PlayReady PSSH data (XML in UTF-16LE)
pub fn parsePlayReadyData(data: []const u8, allocator: Allocator) !?PlayReadyHeader {
    // PlayReady uses UTF-16LE XML wrapped in a binary header
    if (data.len < 10) return null;

    // Skip PlayReady object header
    var offset: usize = 0;
    const obj_size = std.mem.readInt(u32, data[0..4], .little);
    if (obj_size > data.len) return null;

    offset = 4;
    const record_count = std.mem.readInt(u16, data[offset..][0..2], .little);
    offset += 2;
    _ = record_count;

    // Parse records
    while (offset + 4 <= data.len) {
        const rec_type = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;
        const rec_size = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        if (rec_type == 1 and rec_size > 0) {
            // XML data - would need UTF-16LE decoding
            _ = allocator;
            // Simplified: return placeholder
            return PlayReadyHeader{ .version = "4.0.0.0" };
        }

        offset += rec_size;
    }

    return null;
}

// ============================================================================
// Content Protection Info
// ============================================================================

/// Aggregated content protection information
pub const ContentProtection = struct {
    is_encrypted: bool = false,
    scheme: EncryptionScheme = .none,
    default_kid: ?[16]u8 = null,
    drm_systems: std.ArrayListUnmanaged(DrmSystem) = .empty,
    pssh_boxes: std.ArrayListUnmanaged(PsshBox) = .empty,
    track_encryption: ?TrackEncryption = null,

    pub fn deinit(self: *ContentProtection, allocator: Allocator) void {
        self.drm_systems.deinit(allocator);
        for (self.pssh_boxes.items) |*pssh| {
            pssh.deinit(allocator);
        }
        self.pssh_boxes.deinit(allocator);
    }

    /// Get license server URL if available
    pub fn getLicenseUrl(self: *const ContentProtection, system: DrmSystem) ?[]const u8 {
        for (self.pssh_boxes.items) |pssh| {
            if (pssh.getDrmSystem() == system) {
                if (system == .widevine) {
                    if (parseWidevineData(pssh.data)) |wv| {
                        return wv.license_url;
                    }
                }
            }
        }
        return null;
    }

    /// Format default KID as UUID string
    pub fn getDefaultKidString(self: *const ContentProtection, buf: []u8) ?[]u8 {
        if (self.default_kid) |kid| {
            const len = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
                kid[0],  kid[1],  kid[2],  kid[3],
                kid[4],  kid[5],  kid[6],  kid[7],
                kid[8],  kid[9],  kid[10], kid[11],
                kid[12], kid[13], kid[14], kid[15],
            }) catch return null;
            return buf[0..len.len];
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DRM system identification" {
    const testing = std.testing;

    const widevine_id = DrmSystem.widevine.systemId();
    try testing.expectEqual(DrmSystem.widevine, DrmSystem.fromSystemId(widevine_id));

    const playready_id = DrmSystem.playready.systemId();
    try testing.expectEqual(DrmSystem.playready, DrmSystem.fromSystemId(playready_id));

    try testing.expectEqualStrings("Widevine", DrmSystem.widevine.name());
}

test "Encryption scheme" {
    const testing = std.testing;

    try testing.expectEqual(EncryptionScheme.cenc, EncryptionScheme.fromFourCC(.{ 'c', 'e', 'n', 'c' }));
    try testing.expectEqual(EncryptionScheme.cbcs, EncryptionScheme.fromFourCC(.{ 'c', 'b', 'c', 's' }));
    try testing.expectEqual(EncryptionScheme.none, EncryptionScheme.fromFourCC(.{ 'x', 'x', 'x', 'x' }));
}

test "Content protection default KID formatting" {
    const testing = std.testing;

    var cp = ContentProtection{
        .is_encrypted = true,
        .default_kid = .{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 },
    };

    var buf: [40]u8 = undefined;
    const kid_str = cp.getDefaultKidString(&buf);
    try testing.expect(kid_str != null);
    try testing.expectEqualStrings("01020304-0506-0708-090a-0b0c0d0e0f10", kid_str.?);
}
