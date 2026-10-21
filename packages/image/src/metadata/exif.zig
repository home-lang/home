// EXIF Metadata Parser/Writer
// Selected classic-TIFF Exif metadata; not a complete conformance checker
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
    sensitivity_type = 0x8830,
    iso_speed = 0x8833,
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
    /// Owned JPEG bytes, independent of the source TIFF buffer.
    thumbnail: ?[]const u8 = null,

    // Raw tag storage for custom access
    raw_tags: std.AutoHashMap(u16, []const u8),

    pub fn init(allocator: std.mem.Allocator) ExifData {
        return ExifData{
            .allocator = allocator,
            .raw_tags = std.AutoHashMap(u16, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ExifData) void {
        if (self.thumbnail) |value| self.allocator.free(value);
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

pub const layout = @import("exif_layout.zig");
pub const validate = layout.validate;

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !ExifData {
    const checked = try layout.validate(data);
    var exif = ExifData.init(allocator);
    errdefer exif.deinit();
    var extended_iso: ?u32 = null;
    for (checked.directories[0..checked.count]) |dir| {
        if (dir.kind == .image and exif.thumbnail == null) {
            if (checked.find(dir, 0x0201)) |offset| {
                const length = checked.find(dir, 0x0202).?;
                exif.thumbnail_offset = readU32(offset.bytes[0..4], checked.endian == .little);
                exif.thumbnail_length = readU32(length.bytes[0..4], checked.endian == .little);
                const copy = try allocator.dupe(u8, checked.data[exif.thumbnail_offset..][0..exif.thumbnail_length]);
                if (exif.thumbnail) |old| allocator.free(old);
                exif.thumbnail = copy;
            }
        }
        // Thumbnail dimensions/orientation never overwrite primary metadata.
        if (!dir.primary) continue;
        if (dir.kind == .gps) {
            try parseGps(allocator, checked, dir, &exif);
        } else if (dir.kind == .image or dir.kind == .exif) {
            for (0..dir.count) |i| try parseValue(allocator, checked.entry(dir, i), checked.endian == .little, &exif);
            if (checked.find(dir, 0x8833)) |value| extended_iso = readU32(value.bytes[0..4], checked.endian == .little);
        }
    }
    if (extended_iso) |value| exif.iso_speed = value;
    return exif;
}
fn text(allocator: std.mem.Allocator, slot: *?[]const u8, bytes: []const u8) !void {
    const copy = try allocator.dupe(u8, trimNull(bytes));
    if (slot.*) |old| allocator.free(old);
    slot.* = copy;
}
fn parseValue(allocator: std.mem.Allocator, value: layout.Entry, little: bool, exif: *ExifData) !void {
    const bytes = value.bytes;
    const tag: Tag = @enumFromInt(value.tag);
    switch (tag) {
        .make => try text(allocator, &exif.make, bytes),
        .model => try text(allocator, &exif.model, bytes),
        .software => try text(allocator, &exif.software, bytes),
        .artist => try text(allocator, &exif.artist, bytes),
        .copyright => try text(allocator, &exif.copyright, bytes),
        .lens_make => try text(allocator, &exif.lens_make, bytes),
        .lens_model => try text(allocator, &exif.lens_model, bytes),
        .date_time => try text(allocator, &exif.date_time, bytes),
        .date_time_original => try text(allocator, &exif.date_time_original, bytes),
        .date_time_digitized => try text(allocator, &exif.date_time_digitized, bytes),
        .pixel_x_dimension, .image_width => exif.width = if (value.field_type == 3) readU16(bytes[0..2], little) else readU32(bytes[0..4], little),
        .pixel_y_dimension, .image_length => exif.height = if (value.field_type == 3) readU16(bytes[0..2], little) else readU32(bytes[0..4], little),
        .orientation => exif.orientation = readU16(bytes[0..2], little),
        .exposure_time => exif.exposure_time = readRational(bytes[0..8], little),
        .f_number => exif.f_number = readRational(bytes[0..8], little),
        .iso_speed_ratings => exif.iso_speed = if (value.field_type == 3) readU16(bytes[0..2], little) else readU32(bytes[0..4], little),
        .iso_speed => exif.iso_speed = readU32(bytes[0..4], little),
        .exposure_program => exif.exposure_program = readU16(bytes[0..2], little),
        .exposure_mode => exif.exposure_mode = readU16(bytes[0..2], little),
        .exposure_bias_value => exif.exposure_bias = readSRational(bytes[0..8], little),
        .focal_length => exif.focal_length = readRational(bytes[0..8], little),
        .focal_length_in_35mm_film => exif.focal_length_35mm = readU16(bytes[0..2], little),
        .max_aperture_value => exif.max_aperture = readRational(bytes[0..8], little),
        .flash => exif.flash = readU16(bytes[0..2], little),
        .white_balance => exif.white_balance = readU16(bytes[0..2], little),
        .light_source => exif.light_source = readU16(bytes[0..2], little),
        .metering_mode => exif.metering_mode = readU16(bytes[0..2], little),
        .scene_capture_type => exif.scene_capture_type = readU16(bytes[0..2], little),
        .color_space => exif.color_space = readU16(bytes[0..2], little),
        .thumbnail_offset, .thumbnail_length => {}, // image IFD pairs handled together above
        .exif_ifd_pointer, .gps_info_ifd_pointer, .interoperability_ifd_pointer => {},
        else => {
            const copy = try allocator.dupe(u8, bytes);
            const old = exif.raw_tags.fetchPut(value.tag, copy) catch |err| {
                allocator.free(copy);
                return err;
            };
            if (old) |previous| allocator.free(previous.value);
        },
    }
}
fn parseGps(allocator: std.mem.Allocator, checked: layout.View, dir: layout.Directory, exif: *ExifData) !void {
    const little = checked.endian == .little;
    for ([_]u16{ 2, 4 }) |id| if (checked.find(dir, id)) |value| {
        const reference = checked.find(dir, id - 1) orelse return error.InvalidExif;
        const ref = reference.bytes[0];
        if ((id == 2 and ref != 'N' and ref != 'S') or (id == 4 and ref != 'E' and ref != 'W')) return error.InvalidExif;
        const coordinate = GPSCoordinate{
            .degrees = readRational(value.bytes[0..8], little).toFloat(),
            .minutes = readRational(value.bytes[8..16], little).toFloat(),
            .seconds = readRational(value.bytes[16..24], little).toFloat(),
            .ref = ref,
        };
        const maximum: f64 = if (id == 2) 90 else 180;
        if (@abs(coordinate.toDecimal()) > maximum or coordinate.degrees > maximum or coordinate.minutes >= 60 or coordinate.seconds >= 60 or (coordinate.degrees == maximum and (coordinate.minutes != 0 or coordinate.seconds != 0))) return error.InvalidExif;
        if (id == 2) exif.gps_latitude = coordinate else exif.gps_longitude = coordinate;
    };
    if (checked.find(dir, 6)) |value| {
        const sign = if (checked.find(dir, 5)) |v| v.bytes[0] else 0;
        if (sign > 1) return error.InvalidExif;
        const altitude = readRational(value.bytes[0..8], little).toFloat();
        exif.gps_altitude = if (sign == 1) -altitude else altitude;
    }
    if (checked.find(dir, 29)) |value| try text(allocator, &exif.gps_datestamp, value.bytes);
    if (checked.find(dir, 7)) |value| {
        const hours = readRational(value.bytes[0..8], little).toFloat();
        const minutes = readRational(value.bytes[8..16], little).toFloat();
        const seconds = readRational(value.bytes[16..24], little).toFloat();
        if (hours >= 24 or minutes >= 60 or seconds >= 60 or @floor(hours) != hours or @floor(minutes) != minutes) return error.InvalidExif;
        const copy = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{s}{d}", .{ @as(u8, @intFromFloat(hours)), @as(u8, @intFromFloat(minutes)), if (seconds < 10) @as([]const u8, "0") else "", seconds });
        if (exif.gps_timestamp) |old| allocator.free(old);
        exif.gps_timestamp = copy;
    }
}

// ============================================================================
// EXIF Writer
// ============================================================================

pub const serialization = @import("exif_builder.zig");
pub const Builder = serialization.Builder;

/// Serialize the selected typed fields. Zero-valued legacy scalar fields are
/// omitted (their structure has no presence bits). raw_tags is a read-only byte
/// projection without field types/IFD identity; use Builder for custom fields.
pub fn encodeTiff(allocator: std.mem.Allocator, exif: *const ExifData) ![]u8 {
    var writer = Builder.init(allocator);
    defer writer.deinit();
    inline for (.{ .{ "make", Tag.make }, .{ "model", Tag.model }, .{ "software", Tag.software }, .{ "artist", Tag.artist }, .{ "copyright", Tag.copyright }, .{ "date_time", Tag.date_time } }) |field| {
        if (@field(exif, field[0])) |value| try writer.ascii(.image, @intFromEnum(field[1]), value);
    }
    inline for (.{ .{ "lens_make", Tag.lens_make }, .{ "lens_model", Tag.lens_model }, .{ "date_time_original", Tag.date_time_original }, .{ "date_time_digitized", Tag.date_time_digitized } }) |field| {
        if (@field(exif, field[0])) |value| try writer.ascii(.exif, @intFromEnum(field[1]), value);
    }
    if (exif.width != 0) try writer.long(.exif, @intFromEnum(Tag.pixel_x_dimension), exif.width);
    if (exif.height != 0) try writer.long(.exif, @intFromEnum(Tag.pixel_y_dimension), exif.height);
    if (exif.orientation > 8) return error.InvalidExif;
    if (exif.orientation != 0) try writer.short(.image, @intFromEnum(Tag.orientation), exif.orientation);
    inline for (.{ .{ "exposure_time", Tag.exposure_time }, .{ "f_number", Tag.f_number }, .{ "focal_length", Tag.focal_length }, .{ "max_aperture", Tag.max_aperture_value } }) |field| {
        if (@field(exif, field[0])) |value| try writer.rational(.exif, @intFromEnum(field[1]), value.numerator, value.denominator);
    }
    if (exif.exposure_bias) |value| try writer.srational(.exif, @intFromEnum(Tag.exposure_bias_value), value.numerator, value.denominator);
    if (exif.iso_speed != 0) {
        try writer.short(.exif, @intFromEnum(Tag.iso_speed_ratings), @intCast(@min(exif.iso_speed, 65535)));
        try writer.short(.exif, @intFromEnum(Tag.sensitivity_type), 3);
        try writer.long(.exif, @intFromEnum(Tag.iso_speed), exif.iso_speed);
    }
    inline for (.{ .{ "exposure_program", Tag.exposure_program }, .{ "exposure_mode", Tag.exposure_mode }, .{ "focal_length_35mm", Tag.focal_length_in_35mm_film }, .{ "flash", Tag.flash }, .{ "white_balance", Tag.white_balance }, .{ "light_source", Tag.light_source }, .{ "metering_mode", Tag.metering_mode }, .{ "scene_capture_type", Tag.scene_capture_type }, .{ "color_space", Tag.color_space } }) |field| {
        const value = @field(exif, field[0]);
        if (value != 0) try writer.short(.exif, @intFromEnum(field[1]), value);
    }
    if (exif.gps_latitude) |value| try writeCoordinate(&writer, value, 2);
    if (exif.gps_longitude) |value| try writeCoordinate(&writer, value, 4);
    if (exif.gps_altitude) |value| {
        if (!std.math.isFinite(value)) return error.InvalidExif;
        const reference = [_]u8{if (value < 0) 1 else 0};
        try writer.bytes(.gps, 5, 1, 1, &reference);
        const rational = try floatRational(@abs(value));
        try writer.rational(.gps, 6, rational.numerator, rational.denominator);
    }
    if (exif.gps_datestamp) |value| try writer.ascii(.gps, 29, value);
    if (exif.gps_timestamp) |value| {
        var parts = std.mem.splitScalar(u8, value, ':');
        var body: [24]u8 = undefined;
        for (0..3) |i| {
            const token = parts.next() orelse return error.InvalidExif;
            const number = std.fmt.parseFloat(f64, token) catch return error.InvalidExif;
            if (!std.math.isFinite(number) or number < 0 or number >= @as(f64, if (i == 0) 24 else 60) or (i < 2 and @floor(number) != number)) return error.InvalidExif;
            const rational = try floatRational(number);
            if (rational.toFloat() >= @as(f64, if (i == 0) 24 else 60)) return error.InvalidExif;
            std.mem.writeInt(u32, body[i * 8 ..][0..4], rational.numerator, .little);
            std.mem.writeInt(u32, body[i * 8 + 4 ..][0..4], rational.denominator, .little);
        }
        if (parts.next() != null) return error.InvalidExif;
        try writer.bytes(.gps, 7, 5, 3, &body);
    }
    if (exif.gps_latitude != null or exif.gps_longitude != null or exif.gps_altitude != null or exif.gps_datestamp != null or exif.gps_timestamp != null) try writer.bytes(.gps, 0, 1, 4, &.{ 2, 3, 0, 0 });
    if (exif.thumbnail == null and (exif.thumbnail_offset != 0 or exif.thumbnail_length != 0)) return error.InvalidThumbnail;
    return writer.finish(.{ .thumbnail = exif.thumbnail });
}
pub fn encode(allocator: std.mem.Allocator, exif: *const ExifData) ![]u8 {
    const tiff = try encodeTiff(allocator, exif);
    defer allocator.free(tiff);
    const output = try allocator.alloc(u8, EXIF_HEADER.len + tiff.len);
    @memcpy(output[0..EXIF_HEADER.len], EXIF_HEADER);
    @memcpy(output[EXIF_HEADER.len..], tiff);
    return output;
}
fn floatRational(value: f64) !Rational {
    const maximum = std.math.maxInt(u32);
    if (!std.math.isFinite(value) or value < 0 or value > maximum) return error.InvalidExif;
    var denominator: u32 = 1_000_000;
    while (@round(value * @as(f64, @floatFromInt(denominator))) > maximum) denominator /= 10;
    return .{ .numerator = @intFromFloat(@round(value * @as(f64, @floatFromInt(denominator)))), .denominator = denominator };
}
fn writeCoordinate(writer: *Builder, coordinate: GPSCoordinate, tag: u16) !void {
    const maximum: f64 = if (tag == 2) 90 else 180;
    if ((tag == 2 and coordinate.ref != 'N' and coordinate.ref != 'S') or (tag == 4 and coordinate.ref != 'E' and coordinate.ref != 'W')) return error.InvalidExif;
    const values = [_]f64{ coordinate.degrees, coordinate.minutes, coordinate.seconds };
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidExif;
    if (@abs(coordinate.toDecimal()) > maximum or coordinate.degrees > maximum or coordinate.minutes >= 60 or coordinate.seconds >= 60 or (coordinate.degrees == maximum and (coordinate.minutes != 0 or coordinate.seconds != 0))) return error.InvalidExif;
    if ((try floatRational(coordinate.degrees)).toFloat() == maximum and (coordinate.minutes != 0 or coordinate.seconds != 0)) return error.InvalidExif;
    const reference = [_]u8{ coordinate.ref, 0 };
    try writer.bytes(.gps, tag - 1, 2, 2, &reference);
    var body: [24]u8 = undefined;
    for (values, 0..) |value, i| {
        const rational = try floatRational(value);
        if ((i == 0 and rational.toFloat() > maximum) or (i != 0 and rational.toFloat() >= 60)) return error.InvalidExif;
        std.mem.writeInt(u32, body[i * 8 ..][0..4], rational.numerator, .little);
        std.mem.writeInt(u32, body[i * 8 + 4 ..][0..4], rational.denominator, .little);
    }
    try writer.bytes(.gps, tag, 5, 3, &body);
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

test "EXIF encoder round trips strings and orientation" {
    const allocator = std.testing.allocator;
    var source = ExifData.init(allocator);
    defer source.deinit();
    source.make = try allocator.dupe(u8, "Home Camera Company");
    source.model = try allocator.dupe(u8, "Home Model 18");
    source.software = try allocator.dupe(u8, "Home Image");
    source.orientation = 6;

    const encoded = try encode(allocator, &source);
    defer allocator.free(encoded);
    var decoded = try parse(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqualStrings(source.make.?, decoded.make.?);
    try std.testing.expectEqualStrings(source.model.?, decoded.model.?);
    try std.testing.expectEqualStrings(source.software.?, decoded.software.?);
    try std.testing.expectEqual(@as(u16, 6), decoded.orientation);
}
