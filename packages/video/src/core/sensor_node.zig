//! Exact Linux device-tree sensor association over borrowed sysfs link bytes.
//! No filesystem access, path normalization, prefix matching or allocation.
const std = @import("std");
pub const max_path = 4096;
pub const max_subdevice = 65535;
pub fn subdeviceIndex(name: []const u8) ?u32 {
    const prefix = "v4l-subdev";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const digits = name[prefix.len..];
    if (digits.len == 0 or digits.len > 5 or (digits.len > 1 and digits[0] == '0')) return null;
    var number: u32 = 0;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        number = number * 10 + (byte - '0');
    }
    return if (number <= max_subdevice) number else null;
}
fn bounded(bytes: []const u8) bool {
    return bytes.len != 0 and bytes.len < max_path and std.mem.indexOfScalar(u8, bytes, 0) == null and std.unicode.utf8ValidateSlice(bytes);
}
pub fn validCameraId(id: []const u8) bool {
    if (!bounded(id) or !std.mem.startsWith(u8, id, "/base/")) return false;
    var parts = std.mem.splitScalar(u8, id[6..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '\\') != null) return false;
    }
    return true;
}
/// `driver` is the /device/driver symlink target, supporting built-in drivers
/// without requiring a /driver/module link. `node` is /device/of_node's target.
pub fn matches(camera_id: []const u8, driver: []const u8, node: []const u8, expected_driver: []const u8) bool {
    if (!validCameraId(camera_id) or !bounded(driver) or !bounded(node) or !bounded(expected_driver) or std.mem.indexOfScalar(u8, expected_driver, '/') != null) return false;
    const tail = if (std.mem.lastIndexOfScalar(u8, driver, '/')) |at| driver[at + 1 ..] else driver;
    if (!std.mem.eql(u8, tail, expected_driver)) return false;
    const anchor = "/firmware/devicetree/base/";
    const start = std.mem.indexOf(u8, node, anchor) orelse return false;
    if (std.mem.indexOf(u8, node[start + 1 ..], anchor) != null) return false;
    const id = node[start + "/firmware/devicetree".len ..];
    return validCameraId(id) and std.mem.eql(u8, camera_id, id);
}
test "sensor nodes match exact camera and driver identities for Pi device-tree layouts" {
    const t = std.testing;
    for ([_][]const u8{ "/base/soc/i2c0mux/i2c@1/imx708@1a", "/base/axi/pcie@1000120000/rp1/i2c@80000/imx708@1a" }) |id| {
        var path: [max_path]u8 = undefined;
        const node = try std.fmt.bufPrint(&path, "../../../firmware/devicetree{s}", .{id});
        try t.expect(matches(id, "../../../../bus/i2c/drivers/imx708", node, "imx708"));
        try t.expect(matches(id, "imx708", node, "imx708"));
        for ([_][]const u8{ "imx708fake", "imx708/", "IMX708", "imx708\x00hidden", "imx219" }) |driver| try t.expect(!matches(id, driver, node, "imx708"));
        try t.expect(!matches(id[0 .. id.len - 1], "imx708", node, "imx708"));
        var changed = path;
        changed[node.len - 1] = 'b';
        try t.expect(!matches(id, "imx708", changed[0..node.len], "imx708"));
    }
}
test "sensor association rejects traversal ambiguous anchors malformed bytes and suffix spoofing" {
    const t = std.testing;
    const id = "/base/soc/i2c@1/imx708@1a";
    const node = "/sys/firmware/devicetree/base/soc/i2c@1/imx708@1a";
    for ([_][]const u8{ "", "/base/", "/base//imx708@1a", "/base/../imx708@1a", "/base/./imx708@1a", "/base/soc/", "/base/soc\\x/imx708@1a", "/base/soc/\xff", "/base/soc/\x00" }) |bad| {
        try t.expect(!validCameraId(bad));
        try t.expect(!matches(bad, "imx708", node, "imx708"));
    }
    for ([_][]const u8{ "/tmp/base/soc/i2c@1/imx708@1a", "/sys/firmware/devicetree/base/soc/i2c@1/imx708@1ab", "/sys/firmware/devicetree/base/soc/i2c@1/../imx708@1a", "/sys/firmware/devicetree/base/soc/i2c@1/imx708@1a/", "/sys/firmware/devicetree/base/firmware/devicetree/base/soc/i2c@1/imx708@1a" }) |bad| try t.expect(!matches(id, "imx708", bad, "imx708"));
    var oversized: [max_path]u8 = @splat('x');
    try t.expect(!matches(id, "imx708", &oversized, "imx708"));
}
test "subdevice names admit canonical bounded indices beyond the old sixteen-node scan" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, 0), subdeviceIndex("v4l-subdev0"));
    try t.expectEqual(@as(?u32, 2), subdeviceIndex("v4l-subdev2"));
    try t.expectEqual(@as(?u32, 127), subdeviceIndex("v4l-subdev127"));
    try t.expectEqual(@as(?u32, 65535), subdeviceIndex("v4l-subdev65535"));
    for ([_][]const u8{ "v4l-subdev", "v4l-subdev-1", "v4l-subdev00", "v4l-subdev02", "v4l-subdev65536", "v4l-subdev100000", "v4l-subdev2/other", "v4l-subdev2\x00", "video0", "V4L-subdev2" }) |bad| try t.expectEqual(@as(?u32, null), subdeviceIndex(bad));
}
