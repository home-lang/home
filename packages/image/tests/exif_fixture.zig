//! Test-only independent reader boundary; production Exif has no C dependency.
const std = @import("std");
const exif = @import("exif");
const allocator = std.heap.c_allocator;
fn fixture() ![]u8 {
    var source = exif.ExifData.init(allocator);
    defer source.deinit();
    source.make = try allocator.dupe(u8, "Home Camera Company");
    source.model = try allocator.dupe(u8, "Pi 5 fixture");
    source.software = try allocator.dupe(u8, "Home image Exif test");
    source.lens_model = try allocator.dupe(u8, "Fixture Lens");
    source.date_time_original = try allocator.dupe(u8, "2026:10:21 13:02:03");
    source.gps_timestamp = try allocator.dupe(u8, "13:02:03.125");
    source.gps_datestamp = try allocator.dupe(u8, "2026:10:21");
    source.thumbnail = try allocator.dupe(u8, "\xff\xd8\xff\xd9");
    source.orientation = 6;
    source.width = 4608;
    source.height = 2592;
    source.iso_speed = 102400;
    source.exposure_time = .{ .numerator = 12345, .denominator = 1_000_000 };
    source.exposure_bias = .{ .numerator = -2, .denominator = 3 };
    source.f_number = .{ .numerator = 28, .denominator = 10 };
    source.gps_latitude = .{ .degrees = 40, .minutes = 26, .seconds = 46.125, .ref = 'S' };
    source.gps_longitude = .{ .degrees = 120, .minutes = 2, .seconds = 12, .ref = 'W' };
    source.gps_altitude = -123.4;
    return exif.encode(allocator, &source);
}
pub export fn home_test_exif_fixture(length: *usize) ?[*]u8 {
    length.* = 0;
    const data = fixture() catch return null;
    length.* = data.len;
    return data.ptr;
}
pub export fn home_test_exif_free(bytes: [*]u8, length: usize) void {
    allocator.free(bytes[0..length]);
}
pub export fn home_test_exif_check(bytes: [*]const u8, length: usize) c_int {
    var result = exif.parse(allocator, bytes[0..length]) catch return 1;
    defer result.deinit();
    if (!std.mem.eql(u8, result.make orelse return 2, "Home Camera Company")) return 3;
    if (result.width != 4608 or result.height != 2592 or result.iso_speed != 102400 or result.orientation != 6) return 4;
    if (result.gps_latitude == null or result.gps_latitude.?.ref != 'S' or result.gps_longitude == null or result.gps_longitude.?.ref != 'W') return 5;
    if (result.gps_altitude == null or @abs(result.gps_altitude.? + 123.4) > 0.000001) return 6;
    if (!std.mem.eql(u8, result.thumbnail orelse return 7, "\xff\xd8\xff\xd9")) return 8;
    if (!std.mem.eql(u8, result.gps_timestamp orelse return 9, "13:02:03.125")) return 10;
    return 0;
}
