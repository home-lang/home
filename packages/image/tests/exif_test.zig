const std = @import("std");
const exif = @import("exif");
const layout = exif.layout;
const wire = exif.serialization;
const a = std.testing.allocator;

fn fixture(allocator: std.mem.Allocator) ![]u8 {
    var writer = exif.Builder.init(allocator);
    defer writer.deinit();
    try writer.ascii(.image, 0x010f, "Camera Company");
    try writer.ascii(.exif, 0x010f, "Exif Camera Company"); // same typed slot, distinct IFD
    try writer.ascii(.image, 0x0110, "Pi 5 test");
    try writer.short(.image, 0x0112, 6);
    try writer.long(.exif, 0xa002, 4608);
    try writer.long(.exif, 0xa003, 2592);
    try writer.rational(.exif, 0x829a, 1, 125);
    try writer.rational(.exif, 0x829d, 28, 10);
    try writer.srational(.exif, 0x9204, -1, 3);
    try writer.short(.exif, 0x8827, 800);
    try writer.bytes(.exif, 0x927c, 7, 6, "opaque");
    try writer.bytes(.gps, 1, 2, 2, "S\x00");
    try writer.bytes(.gps, 3, 2, 2, "W\x00");
    var coordinates: [24]u8 = undefined;
    for ([_]u32{ 40, 26, 46 }, 0..) |value, i| {
        std.mem.writeInt(u32, coordinates[i * 8 ..][0..4], value, .little);
        std.mem.writeInt(u32, coordinates[i * 8 + 4 ..][0..4], 1, .little);
    }
    try writer.bytes(.gps, 2, 5, 3, &coordinates);
    try writer.bytes(.gps, 4, 5, 3, &coordinates);
    try writer.bytes(.gps, 5, 1, 1, &.{1});
    try writer.rational(.gps, 6, 1234, 10);
    try writer.ascii(.gps, 29, "2026:10:21");
    try writer.bytes(.interoperability, 1, 2, 4, "R98\x00");
    try writer.long(.thumbnail, 0x0100, 2);
    return writer.finish(.{ .thumbnail = "\xff\xd8\xff\xd9" });
}
fn fieldAt(view: layout.View, kind: layout.Kind, primary: bool, tag: u16) !usize {
    for (view.directories[0..view.count]) |dir| {
        if (dir.kind != kind or dir.primary != primary) continue;
        for (0..dir.count) |i| if (view.entry(dir, i).tag == tag) return dir.offset + 2 + i * 12;
    }
    return error.MissingTestField;
}
fn set32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn set16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

test "typed directories, copied input, GPS signs, primary geometry and thumbnail ownership" {
    const input = try fixture(a);
    defer a.free(input);
    const view = try layout.validate(input);
    try std.testing.expectEqual(@as(usize, 5), view.count);
    for (view.directories[0..view.count]) |dir| {
        try std.testing.expectEqual(@as(usize, 0), dir.offset % 2);
        var old: ?u16 = null;
        for (0..dir.count) |i| {
            const field = view.entry(dir, i);
            if (old) |tag| try std.testing.expect(tag < field.tag);
            old = field.tag;
            if (field.bytes.len > 4) try std.testing.expectEqual(@as(usize, 0), (@intFromPtr(field.bytes.ptr) - @intFromPtr(input.ptr)) % 2);
        }
    }
    var result = try exif.parse(a, input);
    defer result.deinit();
    @memset(input, 0);
    try std.testing.expectEqualStrings("Exif Camera Company", result.make.?);
    try std.testing.expectEqualStrings("Pi 5 test", result.model.?);
    try std.testing.expectEqual(@as(u32, 4608), result.width);
    try std.testing.expectEqual(@as(u32, 2592), result.height);
    try std.testing.expectEqual(@as(u16, 6), result.orientation);
    try std.testing.expectApproxEqAbs(@as(f64, -40.446111111), result.gps_latitude.?.toDecimal(), 0.000001);
    try std.testing.expectEqual(@as(u8, 'W'), result.gps_longitude.?.ref);
    try std.testing.expectEqual(@as(f64, -123.4), result.gps_altitude.?);
    try std.testing.expectEqualStrings("opaque", result.raw_tags.get(0x927c).?);
    try std.testing.expectEqualSlices(u8, "\xff\xd8\xff\xd9", result.thumbnail.?);
}

test "reject every truncated prefix before reading metadata" {
    const input = try fixture(a);
    defer a.free(input);
    for (0..input.len) |length| {
        if (exif.parse(a, input[0..length])) |parsed| {
            var result = parsed;
            result.deinit();
            return error.AcceptedTruncatedExif;
        } else |_| {}
    }
}

test "invalid counts types cycles duplicates offsets and denominators" {
    const input = try fixture(a);
    defer a.free(input);
    const view = try layout.validate(input);
    const row = try fieldAt(view, .image, true, 0x0112);
    const exposure = try fieldAt(view, .exif, true, 0x829a);
    const pointer = try fieldAt(view, .image, true, 0x8769);
    const thumb = try fieldAt(view, .image, false, 0x0201);
    const copy = try a.dupe(u8, input);
    defer a.free(copy);
    for (0..9) |mutation| {
        @memcpy(copy, input);
        switch (mutation) {
            0 => set32(copy, row + 4, 0),
            1 => set16(copy, row + 2, 1),
            2 => set32(copy, pointer + 8, 8),
            3 => set16(copy, row, 0x010f),
            4 => set32(copy, exposure + 8, 0xfffffff0),
            5 => set32(copy, @as(usize, std.mem.readInt(u32, copy[exposure + 8 ..][0..4], .little)) + 4, 0),
            6 => set32(copy, thumb + 8, 8),
            7 => set32(copy, 8 + 2 + view.directories[0].count * 12, 8),
            8 => set32(copy, exposure + 8, @intCast(view.directories[1].offset)),
            else => unreachable,
        }
        if (exif.parse(a, copy)) |parsed| {
            var result = parsed;
            result.deinit();
            return error.AcceptedMalformedExif;
        } else |_| {}
    }
}

test "big endian inline fields and legacy unaligned out-of-line text" {
    const input = [_]u8{ 'M', 'M', 0, 42, 0, 0, 0, 8, 0, 2, 0x01, 0x0f, 0, 2, 0, 0, 0, 6, 0, 0, 0, 39, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0, 0, 'B', 'r', 'a', 'n', 'd', 0 };
    var result = try exif.parse(a, &input);
    defer result.deinit();
    try std.testing.expectEqualStrings("Brand", result.make.?);
    try std.testing.expectEqual(@as(u16, 6), result.orientation);
}

fn ownership(allocator: std.mem.Allocator) !void {
    const input = try fixture(allocator);
    defer allocator.free(input);
    var result = try exif.parse(allocator, input);
    defer result.deinit();
    const output = try exif.encode(allocator, &result);
    defer allocator.free(output);
    var again = try exif.parse(allocator, output);
    defer again.deinit();
    try std.testing.expectEqualStrings(result.make.?, again.make.?);
    try std.testing.expectEqualSlices(u8, result.thumbnail.?, again.thumbnail.?);
}
test "builder parser and legacy writer clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(a, ownership, .{});
}

test "legacy writer serializes extended ISO exposure dates lens and GPS timestamp" {
    var source = exif.ExifData.init(a);
    defer source.deinit();
    source.iso_speed = 102400;
    source.exposure_time = .{ .numerator = 12345, .denominator = 1_000_000 };
    source.exposure_bias = .{ .numerator = -2, .denominator = 3 };
    source.width = 4608;
    source.height = 2592;
    source.lens_model = try a.dupe(u8, "Test Lens");
    source.date_time_original = try a.dupe(u8, "2026:10:21 13:00:00");
    source.gps_timestamp = try a.dupe(u8, "13:02:03.125");
    const input = try exif.encode(a, &source);
    defer a.free(input);
    var result = try exif.parse(a, input);
    defer result.deinit();
    try std.testing.expectEqual(source.iso_speed, result.iso_speed);
    try std.testing.expectEqualStrings(source.lens_model.?, result.lens_model.?);
    try std.testing.expectEqualStrings(source.date_time_original.?, result.date_time_original.?);
    try std.testing.expectEqualStrings(source.gps_timestamp.?, result.gps_timestamp.?);
    try std.testing.expectEqual(source.exposure_time.?, result.exposure_time.?);
    try std.testing.expectEqual(source.exposure_bias.?, result.exposure_bias.?);
}

test "builder rejects duplicate reserved malformed text and invalid rational fields" {
    var writer = exif.Builder.init(a);
    defer writer.deinit();
    try std.testing.expectError(error.InvalidText, writer.ascii(.image, 0x010f, "\xc3\xa9"));
    try std.testing.expectError(error.InvalidText, writer.ascii(.image, 0x010f, "bad\x00text"));
    try writer.short(.image, 0x0112, 1);
    try writer.short(.image, 0x0112, 2);
    try std.testing.expectError(error.DuplicateTag, writer.finish(.{}));
    try std.testing.expectError(error.ReservedTag, wire.encode(a, &.{.{ .group = .image, .tag = 0x8769, .field_type = 4, .count = 1, .data = &.{ 8, 0, 0, 0 } }}, .{}));
    try std.testing.expectError(error.InvalidExif, wire.encode(a, &.{.{ .group = .exif, .tag = 0x829a, .field_type = 5, .count = 1, .data = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } }}, .{}));
}

test "directory count, entry count and alias allocation amplification are bounded" {
    var directories: [8 + 33 * 6]u8 = @splat(0);
    @memcpy(directories[0..8], "II*\x00\x08\x00\x00\x00");
    for (0..32) |i| set32(&directories, 8 + i * 6 + 2, @intCast(8 + (i + 1) * 6));
    try std.testing.expectError(error.MetadataTooLarge, layout.validate(&directories));
    const total = 8 + 6 + layout.max_entries * 12;
    const aliased = try a.alloc(u8, total + 16385);
    defer a.free(aliased);
    @memset(aliased, 0);
    @memcpy(aliased[0..8], "II*\x00\x08\x00\x00\x00");
    set16(aliased, 8, layout.max_entries);
    for (0..layout.max_entries) |i| {
        const at = 10 + i * 12;
        set16(aliased, at, @intCast(0xb000 + i));
        set16(aliased, at + 2, 7);
        set32(aliased, at + 4, 16385);
        set32(aliased, at + 8, total);
    }
    try std.testing.expectError(error.MetadataTooLarge, layout.validate(aliased));
    set16(aliased, 8, layout.max_entries + 1);
    try std.testing.expectError(error.MetadataTooLarge, layout.validate(aliased));
    var writer = exif.Builder.init(a);
    defer writer.deinit();
    for (0..layout.max_entries - 6) |i| try writer.short(.image, @intCast(0xb000 + i), 0);
    try std.testing.expectError(error.MetadataTooLarge, writer.ascii(.image, 0x010f, "limit"));
}

test "malformed ASCII GPS references timestamps and thumbnail pairs fail safely" {
    const input = try fixture(a);
    defer a.free(input);
    const view = try layout.validate(input);
    const make = try fieldAt(view, .image, true, 0x010f);
    const reference = try fieldAt(view, .gps, true, 1);
    const altitude = try fieldAt(view, .gps, true, 5);
    const thumb = try fieldAt(view, .image, false, 0x0202);
    const copy = try a.dupe(u8, input);
    defer a.free(copy);
    for (0..4) |mutation| {
        @memcpy(copy, input);
        switch (mutation) {
            0 => {
                const start = std.mem.readInt(u32, copy[make + 8 ..][0..4], .little);
                const size = std.mem.readInt(u32, copy[make + 4 ..][0..4], .little);
                copy[start + size - 1] = 'x';
            },
            1 => copy[reference + 8] = 'E',
            2 => copy[altitude + 8] = 2,
            3 => set16(copy, thumb, 0x0203),
            else => unreachable,
        }
        if (exif.parse(a, copy)) |parsed| {
            var result = parsed;
            result.deinit();
            return error.AcceptedMalformedExif;
        } else |_| {}
    }
    var source = exif.ExifData.init(a);
    defer source.deinit();
    for ([_][]const u8{ "24:00:00", "12:60:00", "12:00:60", "nan:00:00", "12:00", "12:00:00:00", "12:00:59.99999999" }) |timestamp| {
        source.gps_timestamp = try a.dupe(u8, timestamp);
        try std.testing.expectError(error.InvalidExif, exif.encodeTiff(a, &source));
        a.free(source.gps_timestamp.?);
        source.gps_timestamp = null;
    }
}

test "bounded deterministic mutations never escape parser ownership" {
    const input = try fixture(a);
    defer a.free(input);
    const copy = try a.dupe(u8, input);
    defer a.free(copy);
    var random: u64 = 0xe17f2026;
    for (0..2048) |_| {
        @memcpy(copy, input);
        for (0..4) |_| {
            random = random *% 6364136223846793005 +% 1442695040888963407;
            const index = (random >> 16) % copy.len;
            copy[index] ^= @as(u8, 1) << @as(u3, @truncate(random >> 48));
        }
        if (exif.parse(a, copy)) |parsed| {
            var result = parsed;
            result.deinit();
        } else |_| {}
    }
}

test "extended ISO wins independently of entry order and GPS total angle is bounded" {
    const input = try fixture(a);
    defer a.free(input);
    const view = try layout.validate(input);
    const row = try fieldAt(view, .exif, true, 0x8827);
    const exposure = try fieldAt(view, .exif, true, 0x829a);
    // Reuse the exposure row as a LONG ISO entry and make it precede SHORT ISO.
    set16(input, exposure, 0x8833);
    set16(input, exposure + 2, 4);
    set32(input, exposure + 4, 1);
    set32(input, exposure + 8, 102400);
    try std.testing.expect(exposure < row);
    var result = try exif.parse(a, input);
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 102400), result.iso_speed);
    var source = exif.ExifData.init(a);
    defer source.deinit();
    source.gps_latitude = .{ .degrees = 89.9, .minutes = 59, .seconds = 0, .ref = 'N' };
    try std.testing.expectError(error.InvalidExif, exif.encodeTiff(a, &source));
    source.gps_latitude = .{ .degrees = 89.99999999, .minutes = 0.000000001, .seconds = 0, .ref = 'N' };
    try std.testing.expectError(error.InvalidExif, exif.encodeTiff(a, &source));
}

test "shared decimal GPS and ISO builders carry rounded boundaries and preserve signs" {
    var writer = exif.Builder.init(a);
    defer writer.deinit();
    try exif.appendGpsDecimal(&writer, -89.999999999999, true);
    try exif.appendGpsDecimal(&writer, -179.999999999999, false);
    try exif.appendGpsAltitude(&writer, -123.456);
    try exif.appendIso(&writer, 102400);
    const bytes = try writer.finish(.{});
    defer a.free(bytes);
    var parsed = try exif.parse(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, -90), parsed.gps_latitude.?.toDecimal());
    try std.testing.expectEqual(@as(f64, -180), parsed.gps_longitude.?.toDecimal());
    try std.testing.expectEqual(@as(f64, -123.456), parsed.gps_altitude.?);
    try std.testing.expectEqual(@as(u32, 102400), parsed.iso_speed);
    try std.testing.expectError(error.InvalidExif, exif.GPSCoordinate.fromDecimal(90.00001, true));
    try std.testing.expectError(error.InvalidExif, exif.GPSCoordinate.fromDecimal(std.math.nan(f64), false));
    try std.testing.expectError(error.InvalidExif, exif.appendIso(&writer, 0));
}

test "typed GPS builders reject domain-invalid coordinates times and version shapes" {
    var writer = exif.Builder.init(a);
    defer writer.deinit();
    var data: [24]u8 = @splat(0);
    for (0..3) |i| std.mem.writeInt(u32, data[i * 8 + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, data[0..4], 24, .little);
    try writer.bytes(.gps, 7, 5, 3, &data);
    try std.testing.expectError(error.InvalidExif, writer.finish(.{}));
    var version = exif.Builder.init(a);
    defer version.deinit();
    try version.short(.gps, 0, 1);
    try std.testing.expectError(error.InvalidExif, version.finish(.{}));
}
