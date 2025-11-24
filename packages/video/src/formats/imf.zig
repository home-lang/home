const std = @import("std");

/// IMF (Interoperable Master Format) - SMPTE ST 2067
/// Professional mastering format for content exchange
pub const Imf = struct {
    /// IMF Application identification (SMPTE ST 2067-20/21)
    pub const ApplicationId = enum {
        app_2, // SMPTE ST 2067-20 (App #2)
        app_2e, // SMPTE ST 2067-21 (App #2 Extended)
        app_3, // SMPTE ST 2067-30 (App #3 - JPEG 2000)
        app_4, // SMPTE ST 2067-40 (App #4 - Dolby Atmos)
        app_5, // SMPTE ST 2067-50 (App #5 - ACES)
    };

    /// Composition Playlist (CPL)
    pub const Cpl = struct {
        id: []const u8,
        annotation: ?[]const u8,
        issue_date: []const u8,
        creator: []const u8,
        content_title: []const u8,
        content_kind: ContentKind,
        edit_rate: EditRate,
        segments: []Segment,

        pub const ContentKind = enum {
            feature,
            trailer,
            policy,
            advertisement,
            episode,
            other,
        };
    };

    /// Edit rate (fraction)
    pub const EditRate = struct {
        numerator: u32,
        denominator: u32,

        pub fn toFloat(self: EditRate) f32 {
            return @as(f32, @floatFromInt(self.numerator)) / @as(f32, @floatFromInt(self.denominator));
        }

        pub fn fromFramerate(fps: f32) EditRate {
            // Common frame rates
            if (@abs(fps - 23.976) < 0.001) {
                return .{ .numerator = 24000, .denominator = 1001 };
            } else if (@abs(fps - 24.0) < 0.001) {
                return .{ .numerator = 24, .denominator = 1 };
            } else if (@abs(fps - 25.0) < 0.001) {
                return .{ .numerator = 25, .denominator = 1 };
            } else if (@abs(fps - 29.97) < 0.001) {
                return .{ .numerator = 30000, .denominator = 1001 };
            } else if (@abs(fps - 30.0) < 0.001) {
                return .{ .numerator = 30, .denominator = 1 };
            } else if (@abs(fps - 50.0) < 0.001) {
                return .{ .numerator = 50, .denominator = 1 };
            } else if (@abs(fps - 59.94) < 0.001) {
                return .{ .numerator = 60000, .denominator = 1001 };
            } else if (@abs(fps - 60.0) < 0.001) {
                return .{ .numerator = 60, .denominator = 1 };
            } else {
                // Generic conversion
                return .{ .numerator = @intFromFloat(fps * 1000.0), .denominator = 1000 };
            }
        }
    };

    /// Segment
    pub const Segment = struct {
        id: []const u8,
        annotation: ?[]const u8,
        sequences: []Sequence,
    };

    /// Sequence (track)
    pub const Sequence = struct {
        id: []const u8,
        track_id: []const u8,
        track_type: TrackType,
        resources: []Resource,

        pub const TrackType = enum {
            main_image,
            main_audio,
            main_subtitle,
            auxiliary_image,
            auxiliary_audio,
            auxiliary_data,
        };
    };

    /// Resource (essence reference)
    pub const Resource = struct {
        id: []const u8,
        annotation: ?[]const u8,
        intrinsic_duration: u64,
        entry_point: u64,
        source_duration: u64,
        repeat_count: u32,
        track_file_id: []const u8,
        hash: ?[]const u8,
        hash_algorithm: ?HashAlgorithm,

        pub const HashAlgorithm = enum {
            sha1,
            sha256,
            sha512,
        };
    };

    /// Asset Map (ASSETMAP.xml)
    pub const AssetMap = struct {
        id: []const u8,
        creator: []const u8,
        volume_count: u32,
        issue_date: []const u8,
        issuer: []const u8,
        assets: []Asset,
    };

    /// Asset
    pub const Asset = struct {
        id: []const u8,
        annotation: ?[]const u8,
        packing_list: bool,
        chunks: []Chunk,
    };

    /// Chunk (file reference)
    pub const Chunk = struct {
        path: []const u8,
        volume_index: u32,
        offset: u64,
        length: u64,
    };

    /// Packing List (PKL)
    pub const PackingList = struct {
        id: []const u8,
        annotation: ?[]const u8,
        issue_date: []const u8,
        issuer: []const u8,
        creator: []const u8,
        assets: []PackingAsset,
    };

    pub const PackingAsset = struct {
        id: []const u8,
        annotation: ?[]const u8,
        hash: []const u8,
        hash_algorithm: Resource.HashAlgorithm,
        size: u64,
        asset_type: []const u8,
        original_file_name: ?[]const u8,
    };
};

/// IMF package structure
pub const ImfPackage = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    asset_map: ?Imf.AssetMap,
    packing_lists: std.ArrayList(Imf.PackingList),
    compositions: std.ArrayList(Imf.Cpl),

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) ImfPackage {
        return .{
            .allocator = allocator,
            .root_path = root_path,
            .asset_map = null,
            .packing_lists = std.ArrayList(Imf.PackingList).init(allocator),
            .compositions = std.ArrayList(Imf.Cpl).init(allocator),
        };
    }

    pub fn deinit(self: *ImfPackage) void {
        self.packing_lists.deinit();
        self.compositions.deinit();
    }

    /// Validate IMF package structure
    pub fn validate(self: *ImfPackage) !ValidationResult {
        var result = ValidationResult{
            .valid = true,
            .errors = std.ArrayList([]const u8).init(self.allocator),
            .warnings = std.ArrayList([]const u8).init(self.allocator),
        };

        // Check for required files
        if (self.asset_map == null) {
            try result.errors.append("Missing ASSETMAP.xml");
            result.valid = false;
        }

        if (self.packing_lists.items.len == 0) {
            try result.errors.append("No packing lists found");
            result.valid = false;
        }

        if (self.compositions.items.len == 0) {
            try result.errors.append("No composition playlists found");
            result.valid = false;
        }

        // Validate asset references
        // TODO: Check that all assets in CPL are in AssetMap
        // TODO: Check that all assets in AssetMap have corresponding files
        // TODO: Verify hashes in packing list

        return result;
    }

    pub const ValidationResult = struct {
        valid: bool,
        errors: std.ArrayList([]const u8),
        warnings: std.ArrayList([]const u8),

        pub fn deinit(self: *ValidationResult) void {
            self.errors.deinit();
            self.warnings.deinit();
        }
    };

    /// Get composition by ID
    pub fn getComposition(self: *ImfPackage, id: []const u8) ?*Imf.Cpl {
        for (self.compositions.items) |*cpl| {
            if (std.mem.eql(u8, cpl.id, id)) {
                return cpl;
            }
        }
        return null;
    }

    /// Get total duration of composition
    pub fn getCompositionDuration(self: *ImfPackage, cpl: *const Imf.Cpl) u64 {
        _ = self;
        var total_duration: u64 = 0;

        for (cpl.segments) |segment| {
            for (segment.sequences) |sequence| {
                var sequence_duration: u64 = 0;
                for (sequence.resources) |resource| {
                    sequence_duration += resource.source_duration;
                }
                // Use the longest sequence as segment duration
                if (sequence_duration > total_duration) {
                    total_duration = sequence_duration;
                }
            }
        }

        return total_duration;
    }
};

/// IMF essence types (common codecs)
pub const ImfEssence = struct {
    /// Check if file is IMF-compliant essence
    pub fn isImfEssence(path: []const u8) bool {
        // IMF typically uses MXF containers
        return std.mem.endsWith(u8, path, ".mxf");
    }

    /// Common video codecs in IMF
    pub const VideoCodec = enum {
        jpeg2000, // SMPTE ST 2067-20/21 (most common)
        h264_high, // SMPTE ST 2067-30
        h265_main10, // SMPTE ST 2067-40
        prores, // Apple ProRes (some workflows)
    };

    /// Common audio codecs in IMF
    pub const AudioCodec = enum {
        pcm_24bit, // Most common
        pcm_16bit,
        aac, // Some apps
        dolby_atmos, // SMPTE ST 2067-40
    };

    /// IMF color spaces
    pub const ColorSpace = enum {
        rec709,
        rec2020,
        dci_p3,
        aces_cg,
        aces_cc,
    };
};

/// IMF UUID generator (RFC 4122 compliant)
pub const ImfUuid = struct {
    /// Generate UUID for IMF asset
    pub fn generate() [36]u8 {
        var uuid: [36]u8 = undefined;
        var random_bytes: [16]u8 = undefined;

        // Generate random bytes (simplified - should use crypto random in production)
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        prng.fill(&random_bytes);

        // Set version (4) and variant bits
        random_bytes[6] = (random_bytes[6] & 0x0F) | 0x40; // Version 4
        random_bytes[8] = (random_bytes[8] & 0x3F) | 0x80; // Variant 10

        // Format as string: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
        const hex = "0123456789abcdef";
        var pos: usize = 0;

        for (random_bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                uuid[pos] = '-';
                pos += 1;
            }
            uuid[pos] = hex[byte >> 4];
            uuid[pos + 1] = hex[byte & 0x0F];
            pos += 2;
        }

        return uuid;
    }

    /// Parse UUID string
    pub fn parse(uuid_str: []const u8) ![16]u8 {
        if (uuid_str.len != 36) return error.InvalidUuidLength;

        var bytes: [16]u8 = undefined;
        var byte_idx: usize = 0;

        var i: usize = 0;
        while (i < uuid_str.len) : (i += 1) {
            if (uuid_str[i] == '-') continue;

            const high = try hexCharToByte(uuid_str[i]);
            i += 1;
            const low = try hexCharToByte(uuid_str[i]);

            bytes[byte_idx] = (high << 4) | low;
            byte_idx += 1;
        }

        return bytes;
    }

    fn hexCharToByte(c: u8) !u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidHexChar,
        };
    }
};

/// IMF helper utilities
pub const ImfUtils = struct {
    /// Convert timecode to edit units
    pub fn timecodeToEditUnits(timecode: []const u8, edit_rate: Imf.EditRate) !u64 {
        // Parse timecode (HH:MM:SS:FF)
        var parts = std.mem.split(u8, timecode, ":");
        const hours = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidTimecode, 10);
        const minutes = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidTimecode, 10);
        const seconds = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidTimecode, 10);
        const frames = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidTimecode, 10);

        const fps = edit_rate.toFloat();
        const total_seconds = hours * 3600 + minutes * 60 + seconds;
        const total_frames = @as(u64, total_seconds) * @as(u64, @intFromFloat(fps)) + frames;

        return total_frames;
    }

    /// Convert edit units to timecode
    pub fn editUnitsToTimecode(edit_units: u64, edit_rate: Imf.EditRate, allocator: std.mem.Allocator) ![]u8 {
        const fps = edit_rate.toFloat();
        const fps_int: u64 = @intFromFloat(fps);

        const frames = edit_units % fps_int;
        const total_seconds = edit_units / fps_int;
        const seconds = total_seconds % 60;
        const minutes = (total_seconds / 60) % 60;
        const hours = total_seconds / 3600;

        return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds, frames });
    }
};
