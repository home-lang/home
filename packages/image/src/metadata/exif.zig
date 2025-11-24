// EXIF Metadata Parser/Writer
// Implements EXIF 2.32 specification
// Based on: https://www.exif.org/Exif2-2.PDF

const std = @import("std");

// ============================================================================
// EXIF Constants
// ============================================================================

const EXIF_MARKER = [_]u8{ 0xFF, 0xE1 }; // APP1 marker
const EXIF_HEADER = "Exif\x00\x00";
const TIFF_LITTLE_ENDIAN = [_]u8{ 'I', 'I', 0x2A, 0x00 };
const TIFF_BIG_ENDIAN = [_]u8{ 'M', 'M', 0x00, 0x2A };

// EXIF Tag IDs
pub const Tag = enum(u16) {
    // Image tags
    image_width = 0x0100,
    image_length = 0x0101,
    bits_per_sample = 0x0102,
    compression = 0x0103,
    photometric_interpretation = 0x0106,
    orientation = 0x0112,
    samples_per_pixel = 0x0115,
    planar_configuration = 0x011C,
    ycbcr_sub_sampling = 0x0212,
    ycbcr_positioning = 0x0213,
    x_resolution = 0x011A,
    y_resolution = 0x011B,
    resolution_unit = 0x0128,

    // Date/Time tags
    date_time = 0x0132,
    date_time_original = 0x9003,
    date_time_digitized = 0x9004,

    // Camera tags
    make = 0x010F,
    model = 0x0110,
    software = 0x0131,
    artist = 0x013B,
    copyright = 0x8298,

    // EXIF IFD pointer
    exif_ifd_pointer = 0x8769,
    gps_info_ifd_pointer = 0x8825,
    interoperability_ifd_pointer = 0xA005,

    // EXIF tags
    exposure_time = 0x829A,
    f_number = 0x829D,
    exposure_program = 0x8822,
    iso_speed_ratings = 0x8827,
    exif_version = 0x9000,
    shutter_speed_value = 0x9201,
    aperture_value = 0x9202,
    brightness_value = 0x9203,
    exposure_bias_value = 0x9204,
    max_aperture_value = 0x9205,
    subject_distance = 0x9206,
    metering_mode = 0x9207,
    light_source = 0x9208,
    flash = 0x9209,
    focal_length = 0x920A,
    maker_note = 0x927C,
    user_comment = 0x9286,
    color_space = 0xA001,
    pixel_x_dimension = 0xA002,
    pixel_y_dimension = 0xA003,
    focal_plane_x_resolution = 0xA20E,
    focal_plane_y_resolution = 0xA20F,
    focal_plane_resolution_unit = 0xA210,
    sensing_method = 0xA217,
    file_source = 0xA300,
    scene_type = 0xA301,
    custom_rendered = 0xA401,
    exposure_mode = 0xA402,
    white_balance = 0xA403,
    digital_zoom_ratio = 0xA404,
    focal_length_in_35mm_film = 0xA405,
    scene_capture_type = 0xA406,
    gain_control = 0xA407,
    contrast = 0xA408,
    saturation = 0xA409,
    sharpness = 0xA40A,
    lens_make = 0xA433,
    lens_model = 0xA434,

    // GPS tags
    gps_version_id = 0x0000,
    gps_latitude_ref = 0x0001,
    gps_latitude = 0x0002,
    gps_longitude_ref = 0x0003,
    gps_longitude = 0x0004,
    gps_altitude_ref = 0x0005,
    gps_altitude = 0x0006,
    gps_timestamp = 0x0007,
    gps_satellites = 0x0008,
    gps_status = 0x0009,
    gps_measure_mode = 0x000A,
    gps_dop = 0x000B,
    gps_speed_ref = 0x000C,
    gps_speed = 0x000D,
    gps_track_ref = 0x000E,
    gps_track = 0x000F,
    gps_img_direction_ref = 0x0010,
    gps_img_direction = 0x0011,
    gps_map_datum = 0x0012,
    gps_dest_latitude_ref = 0x0013,
    gps_dest_latitude = 0x0014,
    gps_dest_longitude_ref = 0x0015,
    gps_dest_longitude = 0x0016,
    gps_date_stamp = 0x001D,

    // Thumbnail tags
    thumbnail_offset = 0x0201,
    thumbnail_length = 0x0202,

    _,
};

// Field types
const FieldType = enum(u16) {
    byte = 1,
    ascii = 2,
    short = 3,
    long = 4,
    rational = 5,
    undefined = 7,
    slong = 9,
    srational = 10,
    _,

    fn size(self: FieldType) usize {
        return switch (self) {
            .byte, .ascii, .undefined => 1,
            .short => 2,
            .long, .slong => 4,
            .rational, .srational => 8,
            else => 1,
        };
    }
};

// ============================================================================
// EXIF Data Types
// ============================================================================

pub const Rational = struct {
    numerator: u32,
    denominator: u32,

    pub fn toFloat(self: Rational) f64 {
        if (self.denominator == 0) return 0;
        return @as(f64, @floatFromInt(self.numerator)) / @as(f64, @floatFromInt(self.denominator));
    }
};

pub const SRational = struct {
    numerator: i32,
    denominator: i32,

    pub fn toFloat(self: SRational) f64 {
        if (self.denominator == 0) return 0;
        return @as(f64, @floatFromInt(self.numerator)) / @as(f64, @floatFromInt(self.denominator));
    }
};

pub const GPSCoordinate = struct {
    degrees: f64,
    minutes: f64,
    seconds: f64,
    ref: u8, // 'N', 'S', 'E', 'W'

    pub fn toDecimal(self: GPSCoordinate) f64 {
        var decimal = self.degrees + self.minutes / 60.0 + self.seconds / 3600.0;
        if (self.ref == 'S' or self.ref == 'W') {
            decimal = -decimal;
        }
        return decimal;
    }
};

// ============================================================================
// EXIF Metadata Structure
// ============================================================================

pub const ExifData = struct {
    allocator: std.mem.Allocator,

    // Camera info
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    software: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    lens_make: ?[]const u8 = null,
    lens_model: ?[]const u8 = null,

    // Date/Time
    date_time: ?[]const u8 = null,
    date_time_original: ?[]const u8 = null,
    date_time_digitized: ?[]const u8 = null,

    // Image dimensions
    width: u32 = 0,
    height: u32 = 0,

    // Orientation (1-8)
    orientation: u16 = 1,

    // Exposure info
    exposure_time: ?Rational = null,
    f_number: ?Rational = null,
    iso_speed: u32 = 0,
    exposure_program: u16 = 0,
    exposure_mode: u16 = 0,
    exposure_bias: ?SRational = null,

    // Focus/Lens
    focal_length: ?Rational = null,
    focal_length_35mm: u16 = 0,
    max_aperture: ?Rational = null,

    // Flash
    flash: u16 = 0,

    // White balance
    white_balance: u16 = 0,
    light_source: u16 = 0,

    // Metering
    metering_mode: u16 = 0,

    // Scene
    scene_capture_type: u16 = 0,

    // GPS
    gps_latitude: ?GPSCoordinate = null,
    gps_longitude: ?GPSCoordinate = null,
    gps_altitude: ?f64 = null,
    gps_timestamp: ?[]const u8 = null,
    gps_datestamp: ?[]const u8 = null,

    // Color
    color_space: u16 = 0,

    // Thumbnail
    thumbnail_offset: u32 = 0,
    thumbnail_length: u32 = 0,

    // Raw tag storage for custom access
    raw_tags: std.AutoHashMap(u16, []const u8),

    pub fn init(allocator: std.mem.Allocator) ExifData {
        return ExifData{
            .allocator = allocator,
            .raw_tags = std.AutoHashMap(u16, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ExifData) void {
        if (self.make) |m| self.allocator.free(m);
        if (self.model) |m| self.allocator.free(m);
        if (self.software) |s| self.allocator.free(s);
        if (self.artist) |a| self.allocator.free(a);
        if (self.copyright) |c| self.allocator.free(c);
        if (self.lens_make) |l| self.allocator.free(l);
        if (self.lens_model) |l| self.allocator.free(l);
        if (self.date_time) |d| self.allocator.free(d);
        if (self.date_time_original) |d| self.allocator.free(d);
        if (self.date_time_digitized) |d| self.allocator.free(d);
        if (self.gps_timestamp) |g| self.allocator.free(g);
        if (self.gps_datestamp) |g| self.allocator.free(g);

        var iter = self.raw_tags.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.raw_tags.deinit();
    }

    pub fn getExposureString(self: *const ExifData) ?[]const u8 {
        if (self.exposure_time) |et| {
            if (et.numerator == 1) {
                // Format as "1/X" for short exposures
                _ = et.denominator;
            }
        }
        return null;
    }
};

// ============================================================================
// EXIF Parser
// ============================================================================

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !ExifData {
    var exif = ExifData.init(allocator);
    errdefer exif.deinit();

    if (data.len < 8) return exif;

    // Check for EXIF header
    var offset: usize = 0;
    if (std.mem.eql(u8, data[0..6], EXIF_HEADER)) {
        offset = 6;
    }

    // Determine byte order
    const is_little_endian = std.mem.eql(u8, data[offset..][0..4], &TIFF_LITTLE_ENDIAN);
    const is_big_endian = std.mem.eql(u8, data[offset..][0..4], &TIFF_BIG_ENDIAN);

    if (!is_little_endian and !is_big_endian) {
        return exif;
    }

    const tiff_start = offset;
    offset += 4;

    // Read IFD0 offset
    if (offset + 4 > data.len) return exif;
    const ifd0_offset = readU32(data[offset..][0..4], is_little_endian);
    offset = tiff_start + ifd0_offset;

    // Parse IFD0
    try parseIFD(allocator, data, tiff_start, &offset, is_little_endian, &exif, false);

    return exif;
}

fn parseIFD(allocator: std.mem.Allocator, data: []const u8, tiff_start: usize, offset: *usize, little_endian: bool, exif: *ExifData, is_gps: bool) !void {
    if (offset.* + 2 > data.len) return;

    const num_entries = readU16(data[offset.*..][0..2], little_endian);
    offset.* += 2;

    var i: usize = 0;
    while (i < num_entries and offset.* + 12 <= data.len) : (i += 1) {
        const tag_id = readU16(data[offset.*..][0..2], little_endian);
        const field_type: FieldType = @enumFromInt(readU16(data[offset.* + 2 ..][0..2], little_endian));
        const count = readU32(data[offset.* + 4 ..][0..4], little_endian);
        const value_offset_raw = data[offset.* + 8 ..][0..4];

        const value_size = field_type.size() * count;
        var value_data: []const u8 = undefined;

        if (value_size <= 4) {
            value_data = value_offset_raw[0..@min(4, value_size)];
        } else {
            const value_offset = readU32(value_offset_raw, little_endian);
            const abs_offset = tiff_start + value_offset;
            if (abs_offset + value_size <= data.len) {
                value_data = data[abs_offset..][0..value_size];
            } else {
                offset.* += 12;
                continue;
            }
        }

        // Parse specific tags
        const tag: Tag = @enumFromInt(tag_id);

        if (is_gps) {
            try parseGPSTag(allocator, tag, field_type, count, value_data, little_endian, exif);
        } else {
            try parseExifTag(allocator, tag, field_type, count, value_data, little_endian, exif, data, tiff_start);
        }

        offset.* += 12;
    }
}

fn parseExifTag(allocator: std.mem.Allocator, tag: Tag, field_type: FieldType, count: u32, value_data: []const u8, little_endian: bool, exif: *ExifData, data: []const u8, tiff_start: usize) !void {
    switch (tag) {
        .make => {
            exif.make = try allocator.dupe(u8, trimNull(value_data));
        },
        .model => {
            exif.model = try allocator.dupe(u8, trimNull(value_data));
        },
        .software => {
            exif.software = try allocator.dupe(u8, trimNull(value_data));
        },
        .artist => {
            exif.artist = try allocator.dupe(u8, trimNull(value_data));
        },
        .copyright => {
            exif.copyright = try allocator.dupe(u8, trimNull(value_data));
        },
        .lens_make => {
            exif.lens_make = try allocator.dupe(u8, trimNull(value_data));
        },
        .lens_model => {
            exif.lens_model = try allocator.dupe(u8, trimNull(value_data));
        },
        .date_time => {
            exif.date_time = try allocator.dupe(u8, trimNull(value_data));
        },
        .date_time_original => {
            exif.date_time_original = try allocator.dupe(u8, trimNull(value_data));
        },
        .date_time_digitized => {
            exif.date_time_digitized = try allocator.dupe(u8, trimNull(value_data));
        },
        .pixel_x_dimension, .image_width => {
            exif.width = if (field_type == .short) readU16(value_data[0..2], little_endian) else readU32(value_data[0..4], little_endian);
        },
        .pixel_y_dimension, .image_length => {
            exif.height = if (field_type == .short) readU16(value_data[0..2], little_endian) else readU32(value_data[0..4], little_endian);
        },
        .orientation => {
            exif.orientation = readU16(value_data[0..2], little_endian);
        },
        .exposure_time => {
            exif.exposure_time = readRational(value_data[0..8], little_endian);
        },
        .f_number => {
            exif.f_number = readRational(value_data[0..8], little_endian);
        },
        .iso_speed_ratings => {
            exif.iso_speed = if (field_type == .short) readU16(value_data[0..2], little_endian) else readU32(value_data[0..4], little_endian);
        },
        .exposure_program => {
            exif.exposure_program = readU16(value_data[0..2], little_endian);
        },
        .exposure_mode => {
            exif.exposure_mode = readU16(value_data[0..2], little_endian);
        },
        .exposure_bias_value => {
            exif.exposure_bias = readSRational(value_data[0..8], little_endian);
        },
        .focal_length => {
            exif.focal_length = readRational(value_data[0..8], little_endian);
        },
        .focal_length_in_35mm_film => {
            exif.focal_length_35mm = readU16(value_data[0..2], little_endian);
        },
        .max_aperture_value => {
            exif.max_aperture = readRational(value_data[0..8], little_endian);
        },
        .flash => {
            exif.flash = readU16(value_data[0..2], little_endian);
        },
        .white_balance => {
            exif.white_balance = readU16(value_data[0..2], little_endian);
        },
        .light_source => {
            exif.light_source = readU16(value_data[0..2], little_endian);
        },
        .metering_mode => {
            exif.metering_mode = readU16(value_data[0..2], little_endian);
        },
        .scene_capture_type => {
            exif.scene_capture_type = readU16(value_data[0..2], little_endian);
        },
        .color_space => {
            exif.color_space = readU16(value_data[0..2], little_endian);
        },
        .thumbnail_offset => {
            exif.thumbnail_offset = readU32(value_data[0..4], little_endian);
        },
        .thumbnail_length => {
            exif.thumbnail_length = readU32(value_data[0..4], little_endian);
        },
        .exif_ifd_pointer => {
            // Parse EXIF sub-IFD
            const sub_offset = readU32(value_data[0..4], little_endian);
            var new_offset = tiff_start + sub_offset;
            try parseIFD(allocator, data, tiff_start, &new_offset, little_endian, exif, false);
        },
        .gps_info_ifd_pointer => {
            // Parse GPS IFD
            const gps_offset = readU32(value_data[0..4], little_endian);
            var new_offset = tiff_start + gps_offset;
            try parseIFD(allocator, data, tiff_start, &new_offset, little_endian, exif, true);
        },
        else => {
            _ = count;
        },
    }
}

fn parseGPSTag(allocator: std.mem.Allocator, tag: Tag, field_type: FieldType, count: u32, value_data: []const u8, little_endian: bool, exif: *ExifData) !void {
    _ = field_type;
    _ = count;

    switch (tag) {
        .gps_latitude_ref => {
            if (exif.gps_latitude) |*lat| {
                lat.ref = value_data[0];
            }
        },
        .gps_latitude => {
            if (value_data.len >= 24) {
                exif.gps_latitude = GPSCoordinate{
                    .degrees = readRational(value_data[0..8], little_endian).toFloat(),
                    .minutes = readRational(value_data[8..16], little_endian).toFloat(),
                    .seconds = readRational(value_data[16..24], little_endian).toFloat(),
                    .ref = 'N',
                };
            }
        },
        .gps_longitude_ref => {
            if (exif.gps_longitude) |*lon| {
                lon.ref = value_data[0];
            }
        },
        .gps_longitude => {
            if (value_data.len >= 24) {
                exif.gps_longitude = GPSCoordinate{
                    .degrees = readRational(value_data[0..8], little_endian).toFloat(),
                    .minutes = readRational(value_data[8..16], little_endian).toFloat(),
                    .seconds = readRational(value_data[16..24], little_endian).toFloat(),
                    .ref = 'E',
                };
            }
        },
        .gps_altitude => {
            if (value_data.len >= 8) {
                exif.gps_altitude = readRational(value_data[0..8], little_endian).toFloat();
            }
        },
        .gps_date_stamp => {
            exif.gps_datestamp = try allocator.dupe(u8, trimNull(value_data));
        },
        else => {},
    }
}

// ============================================================================
// EXIF Writer
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, exif: *const ExifData) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // EXIF header
    try output.appendSlice(EXIF_HEADER);

    // TIFF header (little endian)
    try output.appendSlice(&TIFF_LITTLE_ENDIAN);

    // IFD0 offset (8 bytes from TIFF start)
    try output.appendSlice(&[_]u8{ 0x08, 0x00, 0x00, 0x00 });

    // Build IFD0 entries
    var entries = std.ArrayList([12]u8).init(allocator);
    defer entries.deinit();

    var extra_data = std.ArrayList(u8).init(allocator);
    defer extra_data.deinit();

    // Add entries for non-null fields
    if (exif.make) |make| {
        try addStringEntry(&entries, &extra_data, .make, make);
    }
    if (exif.model) |model| {
        try addStringEntry(&entries, &extra_data, .model, model);
    }
    if (exif.software) |software| {
        try addStringEntry(&entries, &extra_data, .software, software);
    }

    // Orientation
    if (exif.orientation != 0) {
        try addShortEntry(&entries, .orientation, exif.orientation);
    }

    // Write IFD0
    const num_entries: u16 = @intCast(entries.items.len);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, num_entries)));

    for (entries.items) |entry| {
        try output.appendSlice(&entry);
    }

    // Next IFD offset (0 = no more)
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 });

    // Extra data
    try output.appendSlice(extra_data.items);

    return output.toOwnedSlice();
}

fn addStringEntry(entries: *std.ArrayList([12]u8), extra_data: *std.ArrayList(u8), tag: Tag, value: []const u8) !void {
    var entry: [12]u8 = undefined;

    // Tag
    std.mem.writeInt(u16, entry[0..2], @intFromEnum(tag), .little);
    // Type (ASCII)
    std.mem.writeInt(u16, entry[2..4], 2, .little);
    // Count
    std.mem.writeInt(u32, entry[4..8], @intCast(value.len + 1), .little);

    if (value.len + 1 <= 4) {
        // Value fits in entry
        @memset(entry[8..12], 0);
        @memcpy(entry[8..][0..@min(4, value.len)], value[0..@min(4, value.len)]);
    } else {
        // Value offset
        const offset: u32 = @intCast(8 + entries.items.len * 12 + 4 + extra_data.items.len);
        std.mem.writeInt(u32, entry[8..12], offset, .little);
        try extra_data.appendSlice(value);
        try extra_data.append(0); // Null terminator
    }

    try entries.append(entry);
}

fn addShortEntry(entries: *std.ArrayList([12]u8), tag: Tag, value: u16) !void {
    var entry: [12]u8 = undefined;

    // Tag
    std.mem.writeInt(u16, entry[0..2], @intFromEnum(tag), .little);
    // Type (SHORT)
    std.mem.writeInt(u16, entry[2..4], 3, .little);
    // Count
    std.mem.writeInt(u32, entry[4..8], 1, .little);
    // Value
    std.mem.writeInt(u16, entry[8..10], value, .little);
    entry[10] = 0;
    entry[11] = 0;

    try entries.append(entry);
}

// ============================================================================
// Helper Functions
// ============================================================================

fn readU16(bytes: *const [2]u8, little_endian: bool) u16 {
    return if (little_endian)
        std.mem.readInt(u16, bytes, .little)
    else
        std.mem.readInt(u16, bytes, .big);
}

fn readU32(bytes: *const [4]u8, little_endian: bool) u32 {
    return if (little_endian)
        std.mem.readInt(u32, bytes, .little)
    else
        std.mem.readInt(u32, bytes, .big);
}

fn readI32(bytes: *const [4]u8, little_endian: bool) i32 {
    return if (little_endian)
        std.mem.readInt(i32, bytes, .little)
    else
        std.mem.readInt(i32, bytes, .big);
}

fn readRational(bytes: []const u8, little_endian: bool) Rational {
    return Rational{
        .numerator = readU32(bytes[0..4], little_endian),
        .denominator = readU32(bytes[4..8], little_endian),
    };
}

fn readSRational(bytes: []const u8, little_endian: bool) SRational {
    return SRational{
        .numerator = readI32(bytes[0..4], little_endian),
        .denominator = readI32(bytes[4..8], little_endian),
    };
}

fn trimNull(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and data[end - 1] == 0) {
        end -= 1;
    }
    return data[0..end];
}

// ============================================================================
// Tests
// ============================================================================

test "EXIF header constants" {
    try std.testing.expectEqualSlices(u8, "Exif\x00\x00", EXIF_HEADER);
}

test "Rational to float" {
    const r = Rational{ .numerator = 1, .denominator = 100 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), r.toFloat(), 0.0001);
}

test "GPS coordinate to decimal" {
    const coord = GPSCoordinate{
        .degrees = 40,
        .minutes = 26,
        .seconds = 46.8,
        .ref = 'N',
    };
    try std.testing.expectApproxEqAbs(@as(f64, 40.4463), coord.toDecimal(), 0.001);
}
