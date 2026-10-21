//! Independent profile ownership, malformed-input and exact-transfer regressions.
const std = @import("std");
const icc = @import("icc");
const t = std.testing;
fn parseWithAllocator(allocator: std.mem.Allocator, data: []const u8) !void {
    var parsed = try icc.parse(allocator, data);
    defer parsed.deinit();
    if (!parsed.isSRGB()) return error.InvalidSRGB;
}
test "shared wire tags cannot amplify owned allocations past the parser budget" {
    const size = 4 * 1024 * 1024;
    const count = 9;
    const offset = 132 + count * 12;
    const bytes = try t.allocator.alloc(u8, offset + size);
    defer t.allocator.free(bytes);
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], @intCast(bytes.len), .big);
    bytes[8] = 2;
    @memcpy(bytes[36..40], "acsp");
    std.mem.writeInt(u32, bytes[128..132], count, .big);
    for (0..count) |i| {
        const at = 132 + i * 12;
        std.mem.writeInt(u32, bytes[at..][0..4], @as(u32, 0x74616700) + @as(u32, @intCast(i)), .big);
        std.mem.writeInt(u32, bytes[at + 4 ..][0..4], offset, .big);
        std.mem.writeInt(u32, bytes[at + 8 ..][0..4], size, .big);
    }
    @memcpy(bytes[offset..][0..4], "data");
    _ = try icc.validate(bytes); // Shared bodies are structurally legal.
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.MetadataTooLarge, icc.parse(failing.allocator(), bytes));
    try t.expectEqual(@as(usize, 0), failing.allocations);
}
test "parsed sRGB owns real curves after source mutation and recognizes neither missing tags nor gamma 2.2" {
    var empty = icc.ICCProfile.init(t.allocator);
    defer empty.deinit();
    try t.expect(!empty.isSRGB());
    const bytes = try icc.createSRGBProfile(t.allocator);
    defer t.allocator.free(bytes);
    try t.expect(bytes.len < 16384); // One shared curve, not three duplicate tables.
    const view = try icc.validateRgb(bytes);
    try t.expectEqual(view.find("rTRC").?.ptr, view.find("gTRC").?.ptr);
    try t.expectEqual(view.find("gTRC").?.ptr, view.find("bTRC").?.ptr);
    var profile = try icc.parse(t.allocator, bytes);
    defer profile.deinit();
    @memset(bytes, 0);
    try t.expect(profile.isSRGB());
    for ([_]icc.Channel{ .red, .green, .blue }) |channel| {
        const curve = try profile.curve(channel);
        try t.expectApproxEqAbs(@as(f64, 0.00313080495356037), try curve.evaluate(0.04045), 0.00002);
        try t.expectApproxEqAbs(@as(f64, 0.214041140482233), try curve.evaluate(0.5), 0.00002);
        try t.expectApproxEqAbs(@as(f64, 0.735356983052449), try curve.inverse(0.5), 0.00002);
    }
    const replacement = try t.allocator.dupe(u8, "curv\x00\x00\x00\x00\x00\x00\x00\x01\x02\x33");
    const previous = try profile.tags.fetchPut(std.mem.readInt(u32, "rTRC", .big), replacement);
    t.allocator.free(previous.?.value);
    try t.expect(!profile.isSRGB());
}
test "strict ICC parsing rejects every truncated prefix and impossible tag table before publishing a partial profile" {
    const bytes = try icc.createSRGBProfile(t.allocator);
    defer t.allocator.free(bytes);
    for (0..bytes.len) |length| try t.expectError(error.InvalidProfile, icc.parse(t.allocator, bytes[0..length]));
    const original = try t.allocator.dupe(u8, bytes);
    defer t.allocator.free(original);
    for ([_]usize{ 132 + 4, 132 + 8, 128 }) |at| {
        @memcpy(bytes, original);
        std.mem.writeInt(u32, bytes[at..][0..4], std.math.maxInt(u32), .big);
        try t.expectError(error.InvalidProfile, icc.parse(t.allocator, bytes));
    }
    @memcpy(bytes, original);
    try t.checkAllAllocationFailures(t.allocator, parseWithAllocator, .{bytes});
}
fn unicodeProfile() [180]u8 {
    var bytes: [180]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], bytes.len, .big);
    bytes[8] = 4;
    @memcpy(bytes[12..16], "mntr");
    @memcpy(bytes[16..20], "RGB ");
    @memcpy(bytes[20..24], "XYZ ");
    @memcpy(bytes[36..40], "acsp");
    std.mem.writeInt(u32, bytes[128..132], 1, .big);
    @memcpy(bytes[132..136], "desc");
    std.mem.writeInt(u32, bytes[136..140], 144, .big);
    std.mem.writeInt(u32, bytes[140..144], 36, .big);
    @memcpy(bytes[144..148], "mluc");
    std.mem.writeInt(u32, bytes[152..156], 1, .big);
    std.mem.writeInt(u32, bytes[156..160], 12, .big);
    @memcpy(bytes[160..164], "enUS");
    std.mem.writeInt(u32, bytes[164..168], 8, .big);
    std.mem.writeInt(u32, bytes[168..172], 28, .big);
    @memcpy(bytes[172..180], &[_]u8{ 0, 65, 0, 0xE9, 0xD8, 0x3D, 0xDC, 0x15 });
    return bytes;
}
test "ICC localized descriptions preserve Unicode and reject corrupt offsets or surrogate pairs" {
    var bytes = unicodeProfile();
    var profile = try icc.parse(t.allocator, &bytes);
    defer profile.deinit();
    try t.expectEqualStrings("Aé🐕", profile.description.?);
    bytes[178] = 0;
    try t.expectError(error.InvalidText, icc.parse(t.allocator, &bytes));
    bytes = unicodeProfile();
    std.mem.writeInt(u32, bytes[168..172], std.math.maxInt(u32), .big);
    try t.expectError(error.InvalidProfile, icc.parse(t.allocator, &bytes));
    bytes = unicodeProfile();
    std.mem.writeInt(u32, bytes[156..160], std.math.maxInt(u32), .big);
    try t.expectError(error.InvalidProfile, icc.parse(t.allocator, &bytes));
}
test "sampled flat endpoints use the first code and parametric sRGB retains its toe" {
    const flat = try icc.Curve.init("curv\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\xff\xff\xff\xff");
    try t.expectApproxEqAbs(@as(f64, 0.5), try flat.inverse(1), 1e-12);
    var para: [40]u8 = @splat(0);
    @memcpy(para[0..4], "para");
    std.mem.writeInt(u16, para[8..10], 4, .big);
    const values = [_]f64{ 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045, 0, 0 };
    for (values, 0..) |value, i| std.mem.writeInt(i32, para[12 + i * 4 ..][0..4], @intFromFloat(@round(value * 65536)), .big);
    const curve = try icc.Curve.init(&para);
    try t.expectApproxEqAbs(@as(f64, 0.00313080495356037), try curve.evaluate(0.04045), 0.00002);
    try t.expectApproxEqAbs(@as(f64, 0.214041140482233), try curve.evaluate(0.5), 0.00002);
    std.mem.writeInt(i32, para[12..16], std.math.maxInt(i32), .big);
    std.mem.writeInt(i32, para[16..20], std.math.maxInt(i32), .big);
    try t.expectError(error.InvalidCurve, icc.Curve.init(&para));
}
