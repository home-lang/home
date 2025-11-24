const std = @import("std");

/// DCP (Digital Cinema Package) - SMPTE and Interop standards
/// Format for theatrical digital cinema distribution
pub const Dcp = struct {
    /// DCP standard type
    pub const Standard = enum {
        interop, // Legacy (2005)
        smpte, // SMPTE ST 429 series
    };

    /// DCP kind (content type)
    pub const ContentKind = enum {
        feature,
        trailer,
        advertisement,
        policy,
        psa, // Public service announcement
        rating,
        short,
        test,
    };

    /// Composition Playlist (CPL)
    pub const Cpl = struct {
        id: []const u8,
        annotation: ?[]const u8,
        issue_date: []const u8,
        issuer: []const u8,
        creator: []const u8,
        content_title: []const u8,
        content_kind: ContentKind,
        edit_rate: EditRate,
        reels: []Reel,
        standard: Standard,

        /// Get total duration
        pub fn getTotalDuration(self: *const Cpl) u64 {
            var total: u64 = 0;
            for (self.reels) |reel| {
                total += reel.duration;
            }
            return total;
        }
    };

    /// Edit rate
    pub const EditRate = struct {
        numerator: u32,
        denominator: u32,

        pub fn toFloat(self: EditRate) f32 {
            return @as(f32, @floatFromInt(self.numerator)) / @as(f32, @floatFromInt(self.denominator));
        }

        /// DCP uses 24 fps or 48 fps typically
        pub fn isDcpStandard(self: EditRate) bool {
            const fps = self.toFloat();
            return @abs(fps - 24.0) < 0.001 or @abs(fps - 48.0) < 0.001;
        }
    };

    /// Reel (acts like a segment)
    pub const Reel = struct {
        id: []const u8,
        annotation: ?[]const u8,
        duration: u64,
        picture: ?PictureAsset,
        sound: ?SoundAsset,
        subtitles: ?SubtitleAsset,
    };

    /// Picture asset reference
    pub const PictureAsset = struct {
        id: []const u8,
        annotation: ?[]const u8,
        edit_rate: EditRate,
        intrinsic_duration: u64,
        entry_point: u64,
        duration: u64,
        frame_rate: f32,
        screen_aspect_ratio: AspectRatio,
        encrypted: bool,
        key_id: ?[]const u8,
    };

    /// Sound asset reference
    pub const SoundAsset = struct {
        id: []const u8,
        annotation: ?[]const u8,
        edit_rate: EditRate,
        intrinsic_duration: u64,
        entry_point: u64,
        duration: u64,
        encrypted: bool,
        key_id: ?[]const u8,
    };

    /// Subtitle asset reference
    pub const SubtitleAsset = struct {
        id: []const u8,
        annotation: ?[]const u8,
        edit_rate: EditRate,
        intrinsic_duration: u64,
        entry_point: u64,
        duration: u64,
        language: []const u8,
        encrypted: bool,
        key_id: ?[]const u8,
    };

    /// Screen aspect ratio
    pub const AspectRatio = struct {
        width: u32,
        height: u32,

        pub fn toFloat(self: AspectRatio) f32 {
            return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
        }

        /// Common DCI aspect ratios
        pub const flat = AspectRatio{ .width = 1998, .height = 1080 }; // 1.85:1
        pub const scope = AspectRatio{ .width = 2048, .height = 858 }; // 2.39:1
        pub const full = AspectRatio{ .width = 4096, .height = 2160 }; // 4K
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
        size: u64,
        asset_type: []const u8,
        original_file_name: ?[]const u8,
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

    pub const Asset = struct {
        id: []const u8,
        annotation: ?[]const u8,
        packing_list: bool,
        chunks: []Chunk,
    };

    pub const Chunk = struct {
        path: []const u8,
        volume_index: u32,
        offset: u64,
        length: u64,
    };

    /// Volume Index (VOLINDEX.xml)
    pub const VolumeIndex = struct {
        index: u32,
    };
};

/// DCP package structure
pub const DcpPackage = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    standard: Dcp.Standard,
    asset_map: ?Dcp.AssetMap,
    packing_lists: std.ArrayList(Dcp.PackingList),
    compositions: std.ArrayList(Dcp.Cpl),
    volume_index: ?Dcp.VolumeIndex,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8, standard: Dcp.Standard) DcpPackage {
        return .{
            .allocator = allocator,
            .root_path = root_path,
            .standard = standard,
            .asset_map = null,
            .packing_lists = std.ArrayList(Dcp.PackingList).init(allocator),
            .compositions = std.ArrayList(Dcp.Cpl).init(allocator),
            .volume_index = null,
        };
    }

    pub fn deinit(self: *DcpPackage) void {
        self.packing_lists.deinit();
        self.compositions.deinit();
    }

    /// Validate DCP package
    pub fn validate(self: *DcpPackage) !ValidationResult {
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
            try result.errors.append("No packing lists found (PKL)");
            result.valid = false;
        }

        if (self.compositions.items.len == 0) {
            try result.errors.append("No composition playlists found (CPL)");
            result.valid = false;
        }

        // Validate SMPTE requirements
        if (self.standard == .smpte) {
            if (self.volume_index == null) {
                try result.warnings.append("SMPTE DCP should have VOLINDEX.xml");
            }
        }

        // Validate frame rates
        for (self.compositions.items) |*cpl| {
            if (!cpl.edit_rate.isDcpStandard()) {
                try result.warnings.append("Non-standard DCP frame rate");
            }

            // Check for encrypted content
            var has_encrypted = false;
            for (cpl.reels) |reel| {
                if (reel.picture) |pic| {
                    if (pic.encrypted) has_encrypted = true;
                }
                if (reel.sound) |snd| {
                    if (snd.encrypted) has_encrypted = true;
                }
            }

            if (has_encrypted) {
                // Should have KDM available
                try result.warnings.append("Encrypted content requires KDM (Key Delivery Message)");
            }
        }

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
    pub fn getComposition(self: *DcpPackage, id: []const u8) ?*Dcp.Cpl {
        for (self.compositions.items) |*cpl| {
            if (std.mem.eql(u8, cpl.id, id)) {
                return cpl;
            }
        }
        return null;
    }

    /// Check if DCP is encrypted
    pub fn isEncrypted(self: *DcpPackage) bool {
        for (self.compositions.items) |*cpl| {
            for (cpl.reels) |reel| {
                if (reel.picture) |pic| {
                    if (pic.encrypted) return true;
                }
                if (reel.sound) |snd| {
                    if (snd.encrypted) return true;
                }
                if (reel.subtitles) |sub| {
                    if (sub.encrypted) return true;
                }
            }
        }
        return false;
    }
};

/// DCP essence specifications
pub const DcpEssence = struct {
    /// DCP picture specifications (SMPTE ST 428-1)
    pub const PictureSpec = struct {
        /// DCP resolutions
        pub const Resolution = enum {
            @"2k", // 2048x1080
            @"4k", // 4096x2160
        };

        /// DCP uses JPEG 2000 for picture
        codec: Codec = .jpeg2000,
        resolution: Resolution,
        frame_rate: FrameRate,
        bit_depth: u8 = 12,
        color_space: ColorSpace = .xyz,
        encrypted: bool = false,

        pub const Codec = enum {
            jpeg2000,
        };

        pub const FrameRate = enum(u8) {
            fps_24 = 24,
            fps_48 = 48,
        };

        pub const ColorSpace = enum {
            xyz, // DCI XYZ color space
        };

        /// Get pixel dimensions
        pub fn getDimensions(self: PictureSpec) struct { width: u32, height: u32 } {
            return switch (self.resolution) {
                .@"2k" => .{ .width = 2048, .height = 1080 },
                .@"4k" => .{ .width = 4096, .height = 2160 },
            };
        }
    };

    /// DCP sound specifications (SMPTE ST 428-2)
    pub const SoundSpec = struct {
        /// DCP uses uncompressed PCM audio
        sample_rate: SampleRate = .@"48khz",
        bit_depth: u8 = 24,
        channels: u8,
        encrypted: bool = false,

        pub const SampleRate = enum(u32) {
            @"48khz" = 48000,
            @"96khz" = 96000,
        };

        /// Common channel configurations
        pub const ChannelConfig = enum(u8) {
            stereo = 2,
            @"5.1" = 6,
            @"7.1" = 8,
            @"5.1_hoh" = 8, // 5.1 + Hearing impaired
            @"7.1_ds" = 16, // Dolby Atmos
        };
    };

    /// DCP subtitle specifications (SMPTE ST 428-7)
    pub const SubtitleSpec = struct {
        format: Format = .smpte_timed_text,
        language: []const u8,
        encrypted: bool = false,

        pub const Format = enum {
            smpte_timed_text, // XML-based
            interop_subtitle,
        };
    };
};

/// DCP encryption/KDM (Key Delivery Message)
pub const DcpEncryption = struct {
    /// CipherData info
    pub const CipherData = struct {
        key_id: []const u8,
        algorithm: Algorithm,

        pub const Algorithm = enum {
            aes_128_cbc,
        };
    };

    /// KDM (Key Delivery Message) structure
    pub const Kdm = struct {
        id: []const u8,
        annotation: ?[]const u8,
        issue_date: []const u8,
        cpl_id: []const u8,
        content_title: []const u8,
        keys: []Key,
        not_valid_before: []const u8,
        not_valid_after: []const u8,

        pub fn isValid(self: *const Kdm, current_time: i64) bool {
            // Would need to parse dates and compare
            _ = self;
            _ = current_time;
            return true; // Simplified
        }
    };

    pub const Key = struct {
        key_id: []const u8,
        key_value: []const u8, // Encrypted
        plaintext_key_value: ?[]const u8, // Decrypted
    };
};

/// DCP utilities
pub const DcpUtils = struct {
    /// Generate DCP UUID (RFC 4122 URN format)
    pub fn generateUuid() [45]u8 {
        var uuid: [45]u8 = undefined;
        var random_bytes: [16]u8 = undefined;

        // Generate random bytes
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        prng.fill(&random_bytes);

        // Set version and variant
        random_bytes[6] = (random_bytes[6] & 0x0F) | 0x40;
        random_bytes[8] = (random_bytes[8] & 0x3F) | 0x80;

        // Format as URN: urn:uuid:xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
        const prefix = "urn:uuid:";
        @memcpy(uuid[0..9], prefix);

        const hex = "0123456789abcdef";
        var pos: usize = 9;

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

    /// Calculate DCP bitrate for resolution
    pub fn calculateBitrate(resolution: DcpEssence.PictureSpec.Resolution, frame_rate: DcpEssence.PictureSpec.FrameRate) u64 {
        // DCP JPEG 2000 typical bitrates
        const bitrate_per_frame: u64 = switch (resolution) {
            .@"2k" => 20_000_000, // ~20 Mbps per frame
            .@"4k" => 50_000_000, // ~50 Mbps per frame
        };

        return bitrate_per_frame * @intFromEnum(frame_rate);
    }

    /// Validate DCP filename conventions
    pub fn isValidDcpFilename(filename: []const u8) bool {
        // DCP filenames should follow specific patterns
        // MXF files should have UUID-like names
        if (std.mem.endsWith(u8, filename, ".mxf")) {
            return filename.len >= 40; // UUID length check
        }
        return true;
    }
};
