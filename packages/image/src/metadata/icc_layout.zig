//! Allocation-free ICC v2/v4 structural validation and tag views. This is not
//! a complete ICC conformance checker or LUT color-management engine.
const std = @import("std");
pub const Curve = @import("icc_curve.zig").Curve;
pub const max_bytes = 16 * 1024 * 1024;
pub const max_tags = 1024;
pub const Tag = struct { signature: u32, offset: usize, size: usize };
pub const Profile = struct {
    data: []const u8,
    count: usize,
    fn tag(self: Profile, index: usize) Tag {
        const at = 132 + index * 12;
        return .{ .signature = std.mem.readInt(u32, self.data[at..][0..4], .big), .offset = std.mem.readInt(u32, self.data[at + 4 ..][0..4], .big), .size = std.mem.readInt(u32, self.data[at + 8 ..][0..4], .big) };
    }
    pub fn find(self: Profile, signature: *const [4]u8) ?[]const u8 {
        const id = std.mem.readInt(u32, signature, .big);
        for (0..self.count) |i| {
            const entry = self.tag(i);
            if (entry.signature == id) return self.data[entry.offset..][0..entry.size];
        }
        return null;
    }
    /// Conservative owned-copy budget, including UTF-16 to UTF-8 text expansion.
    /// Shared wire bodies can otherwise multiply allocation by the tag count.
    pub fn checkOwnedBudget(self: Profile, limit: usize) !void {
        var total: usize = 0;
        for (0..self.count) |i| {
            const size = std.math.mul(usize, self.tag(i).size, 2) catch return error.MetadataTooLarge;
            total = std.math.add(usize, total, size) catch return error.MetadataTooLarge;
            if (total > limit) return error.MetadataTooLarge;
        }
    }
};
pub fn validate(data: []const u8) !Profile {
    if (data.len < 132 or data.len > max_bytes or std.mem.readInt(u32, data[0..4], .big) != data.len or !std.mem.eql(u8, data[36..40], "acsp") or (data[8] != 2 and data[8] != 4)) return error.InvalidProfile;
    if (!std.mem.allEqual(u8, data[100..128], 0) or std.mem.readInt(u32, data[64..68], .big) > 3) return error.InvalidProfile;
    const count: usize = std.mem.readInt(u32, data[128..132], .big);
    if (count > max_tags or count > (data.len - 132) / 12) return error.InvalidProfile;
    const result = Profile{ .data = data, .count = count };
    const end = 132 + count * 12;
    for (0..count) |i| {
        const entry = result.tag(i);
        if (entry.offset < end or entry.offset % 4 != 0 or entry.offset > data.len or entry.size < 8 or entry.size > data.len - entry.offset) return error.InvalidProfile;
        const bytes = data[entry.offset..][0..entry.size];
        if (!std.mem.allEqual(u8, bytes[4..8], 0)) return error.InvalidProfile;
        // Shared bodies are legal (especially RGB TRCs), partial overlap and
        // duplicate signatures are ambiguous and rejected before allocation.
        var shared = false;
        for (0..i) |j| {
            const old = result.tag(j);
            if (entry.signature == old.signature) return error.InvalidProfile;
            if (entry.offset == old.offset and entry.size == old.size) {
                shared = true;
                continue;
            }
            if (entry.offset < old.offset + old.size and old.offset < entry.offset + entry.size) return error.InvalidProfile;
        }
        if (shared) continue; // Validate each distinct body once, even for large shared TRCs.
        if (std.mem.eql(u8, bytes[0..4], "curv") or std.mem.eql(u8, bytes[0..4], "para")) {
            _ = try Curve.init(bytes);
        } else if (std.mem.eql(u8, bytes[0..4], "XYZ ")) {
            if (bytes.len < 20 or (bytes.len - 8) % 12 != 0) return error.InvalidProfile;
        } else if (std.mem.eql(u8, bytes[0..4], "desc")) {
            if (bytes.len < 12) return error.InvalidProfile;
            const ascii: usize = std.mem.readInt(u32, bytes[8..12], .big);
            if (ascii == 0 or ascii > bytes.len - 12 or bytes[12 + ascii - 1] != 0) return error.InvalidProfile;
            const at = 12 + ascii;
            if (bytes.len - at < 8) return error.InvalidProfile;
            const unicode: usize = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .big);
            if (unicode > (bytes.len - at - 8) / 2) return error.InvalidProfile;
            const mac = at + 8 + unicode * 2;
            if (bytes.len - mac < 70 or bytes[mac + 2] > 67) return error.InvalidProfile;
        } else if (std.mem.eql(u8, bytes[0..4], "mluc")) {
            if (bytes.len < 16) return error.InvalidProfile;
            const records: usize = std.mem.readInt(u32, bytes[8..12], .big);
            const stride: usize = std.mem.readInt(u32, bytes[12..16], .big);
            if (stride < 12 or records > (bytes.len - 16) / stride) return error.InvalidProfile;
            const table_end = 16 + records * stride;
            for (0..records) |r| {
                const at = 16 + r * stride;
                const length: usize = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .big);
                const offset: usize = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .big);
                if (length % 2 != 0 or offset < table_end or offset > bytes.len or length > bytes.len - offset) return error.InvalidProfile;
            }
        }
    }
    return result;
}
/// Embedded processed camera images are RGB. Device-link/LUT execution, profile
/// intent and calibration remain the CMM/caller's responsibility; no conversion
/// is performed by validating or embedding these bytes.
pub fn validateRgb(data: []const u8) !Profile {
    const result = try validate(data);
    if (!std.mem.eql(u8, data[16..20], "RGB ") or (!std.mem.eql(u8, data[20..24], "XYZ ") and !std.mem.eql(u8, data[20..24], "Lab "))) return error.UnsupportedProfile;
    return result;
}
test "ICC tag views reject malformed geometry and permit exactly shared bodies" {
    const t = std.testing;
    var bytes: [180]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], bytes.len, .big);
    bytes[8] = 2;
    @memcpy(bytes[16..20], "RGB ");
    @memcpy(bytes[20..24], "XYZ ");
    @memcpy(bytes[36..40], "acsp");
    std.mem.writeInt(u32, bytes[128..132], 2, .big);
    @memcpy(bytes[132..136], "rTRC");
    @memcpy(bytes[144..148], "gTRC");
    for ([_]usize{ 132, 144 }) |at| {
        std.mem.writeInt(u32, bytes[at + 4 ..][0..4], 156, .big);
        std.mem.writeInt(u32, bytes[at + 8 ..][0..4], 12, .big);
    }
    @memcpy(bytes[156..160], "curv");
    const view = try validateRgb(&bytes);
    try view.checkOwnedBudget(48);
    try t.expectError(error.MetadataTooLarge, view.checkOwnedBudget(47));
    try t.expectEqualSlices(u8, view.find("rTRC").?, view.find("gTRC").?);
    const original = bytes;
    for ([_]usize{ 0, 8, 36, 100, 128, 136, 140, 148, 152, 160 }) |offset| {
        bytes = original;
        bytes[offset] = 255;
        try t.expectError(error.InvalidProfile, validate(&bytes));
    }
    bytes = original;
    @memcpy(bytes[144..148], "rTRC");
    try t.expectError(error.InvalidProfile, validate(&bytes));
    bytes = original;
    std.mem.writeInt(u32, bytes[148..152], 160, .big);
    try t.expectError(error.InvalidProfile, validate(&bytes));
    bytes = original;
    @memcpy(bytes[16..20], "CMYK");
    try t.expectError(error.UnsupportedProfile, validateRgb(&bytes));
    try t.expectError(error.InvalidProfile, validate(bytes[0..179]));
}
