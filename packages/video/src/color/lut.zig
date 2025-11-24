// Home Video Library - Color LUT Support
// 1D and 3D LUT parsing and application (.cube, .3dl, .csp formats)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// LUT Types
// ============================================================================

pub const LutType = enum {
    lut_1d,
    lut_3d,
};

pub const ColorSpace = enum {
    srgb,
    rec709,
    rec2020,
    dci_p3,
    aces,
    linear,
    log_c, // ARRI LogC
    s_log3, // Sony S-Log3
    v_log, // Panasonic V-Log
    unknown,
};

// ============================================================================
// 1D LUT
// ============================================================================

pub const Lut1D = struct {
    title: [256]u8 = [_]u8{0} ** 256,
    title_len: u8 = 0,

    size: u32, // Number of entries
    domain_min: [3]f32 = .{ 0.0, 0.0, 0.0 },
    domain_max: [3]f32 = .{ 1.0, 1.0, 1.0 },

    // Separate tables for R, G, B
    red: []f32,
    green: []f32,
    blue: []f32,

    input_colorspace: ColorSpace = .unknown,
    output_colorspace: ColorSpace = .unknown,

    allocator: Allocator,

    pub fn deinit(self: *Lut1D) void {
        self.allocator.free(self.red);
        self.allocator.free(self.green);
        self.allocator.free(self.blue);
    }

    pub fn setTitle(self: *Lut1D, title: []const u8) void {
        const len = @min(title.len, 255);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = @intCast(len);
    }

    pub fn getTitle(self: *const Lut1D) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Apply 1D LUT to a single RGB value (0.0-1.0 range)
    pub fn apply(self: *const Lut1D, r: f32, g: f32, b: f32) struct { r: f32, g: f32, b: f32 } {
        return .{
            .r = self.interpolate1D(self.red, r, 0),
            .g = self.interpolate1D(self.green, g, 1),
            .b = self.interpolate1D(self.blue, b, 2),
        };
    }

    fn interpolate1D(self: *const Lut1D, table: []f32, value: f32, channel: usize) f32 {
        // Normalize to domain
        const normalized = (value - self.domain_min[channel]) /
            (self.domain_max[channel] - self.domain_min[channel]);

        // Clamp to valid range
        const clamped = std.math.clamp(normalized, 0.0, 1.0);

        // Calculate index
        const index_f = clamped * @as(f32, @floatFromInt(self.size - 1));
        const index_low: usize = @intFromFloat(@floor(index_f));
        const index_high: usize = @min(index_low + 1, self.size - 1);
        const fraction = index_f - @as(f32, @floatFromInt(index_low));

        // Linear interpolation
        return table[index_low] * (1.0 - fraction) + table[index_high] * fraction;
    }
};

// ============================================================================
// 3D LUT
// ============================================================================

pub const Lut3D = struct {
    title: [256]u8 = [_]u8{0} ** 256,
    title_len: u8 = 0,

    size: u32, // Size per dimension (e.g., 33 for 33x33x33)
    domain_min: [3]f32 = .{ 0.0, 0.0, 0.0 },
    domain_max: [3]f32 = .{ 1.0, 1.0, 1.0 },

    // 3D table stored as flat array [r][g][b] = [r * size * size + g * size + b]
    // Each entry is RGB triplet
    data: []f32, // size^3 * 3 elements

    input_colorspace: ColorSpace = .unknown,
    output_colorspace: ColorSpace = .unknown,

    allocator: Allocator,

    pub fn deinit(self: *Lut3D) void {
        self.allocator.free(self.data);
    }

    pub fn setTitle(self: *Lut3D, title: []const u8) void {
        const len = @min(title.len, 255);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = @intCast(len);
    }

    pub fn getTitle(self: *const Lut3D) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Get table index for a given RGB coordinate
    fn getIndex(self: *const Lut3D, r: usize, g: usize, b: usize) usize {
        return (b * self.size * self.size + g * self.size + r) * 3;
    }

    /// Get RGB value at table position
    fn getValueAt(self: *const Lut3D, r: usize, g: usize, b: usize) [3]f32 {
        const idx = self.getIndex(r, g, b);
        if (idx + 2 >= self.data.len) return .{ 0, 0, 0 };
        return .{ self.data[idx], self.data[idx + 1], self.data[idx + 2] };
    }

    /// Apply 3D LUT with trilinear interpolation
    pub fn apply(self: *const Lut3D, r: f32, g: f32, b: f32) struct { r: f32, g: f32, b: f32 } {
        // Normalize to domain
        const rn = (r - self.domain_min[0]) / (self.domain_max[0] - self.domain_min[0]);
        const gn = (g - self.domain_min[1]) / (self.domain_max[1] - self.domain_min[1]);
        const bn = (b - self.domain_min[2]) / (self.domain_max[2] - self.domain_min[2]);

        // Clamp and scale to table indices
        const size_f = @as(f32, @floatFromInt(self.size - 1));
        const ri = std.math.clamp(rn * size_f, 0, size_f);
        const gi = std.math.clamp(gn * size_f, 0, size_f);
        const bi = std.math.clamp(bn * size_f, 0, size_f);

        // Get integer and fractional parts
        const r0: usize = @intFromFloat(@floor(ri));
        const g0: usize = @intFromFloat(@floor(gi));
        const b0: usize = @intFromFloat(@floor(bi));
        const r1: usize = @min(r0 + 1, self.size - 1);
        const g1: usize = @min(g0 + 1, self.size - 1);
        const b1: usize = @min(b0 + 1, self.size - 1);

        const rf = ri - @as(f32, @floatFromInt(r0));
        const gf = gi - @as(f32, @floatFromInt(g0));
        const bf = bi - @as(f32, @floatFromInt(b0));

        // Trilinear interpolation - 8 corner samples
        const c000 = self.getValueAt(r0, g0, b0);
        const c100 = self.getValueAt(r1, g0, b0);
        const c010 = self.getValueAt(r0, g1, b0);
        const c110 = self.getValueAt(r1, g1, b0);
        const c001 = self.getValueAt(r0, g0, b1);
        const c101 = self.getValueAt(r1, g0, b1);
        const c011 = self.getValueAt(r0, g1, b1);
        const c111 = self.getValueAt(r1, g1, b1);

        // Interpolate along R axis
        const c00 = lerp3(c000, c100, rf);
        const c10 = lerp3(c010, c110, rf);
        const c01 = lerp3(c001, c101, rf);
        const c11 = lerp3(c011, c111, rf);

        // Interpolate along G axis
        const c0 = lerp3(c00, c10, gf);
        const c1 = lerp3(c01, c11, gf);

        // Interpolate along B axis
        const result = lerp3(c0, c1, bf);

        return .{ .r = result[0], .g = result[1], .b = result[2] };
    }

    /// Apply with tetrahedral interpolation (higher quality)
    pub fn applyTetrahedral(self: *const Lut3D, r: f32, g: f32, b: f32) struct { r: f32, g: f32, b: f32 } {
        // Normalize to domain
        const rn = (r - self.domain_min[0]) / (self.domain_max[0] - self.domain_min[0]);
        const gn = (g - self.domain_min[1]) / (self.domain_max[1] - self.domain_min[1]);
        const bn = (b - self.domain_min[2]) / (self.domain_max[2] - self.domain_min[2]);

        // Clamp and scale
        const size_f = @as(f32, @floatFromInt(self.size - 1));
        const ri = std.math.clamp(rn * size_f, 0, size_f);
        const gi = std.math.clamp(gn * size_f, 0, size_f);
        const bi = std.math.clamp(bn * size_f, 0, size_f);

        // Get base indices
        const r0: usize = @intFromFloat(@floor(ri));
        const g0: usize = @intFromFloat(@floor(gi));
        const b0: usize = @intFromFloat(@floor(bi));
        const r1: usize = @min(r0 + 1, self.size - 1);
        const g1: usize = @min(g0 + 1, self.size - 1);
        const b1: usize = @min(b0 + 1, self.size - 1);

        // Fractional parts
        const rf = ri - @as(f32, @floatFromInt(r0));
        const gf = gi - @as(f32, @floatFromInt(g0));
        const bf = bi - @as(f32, @floatFromInt(b0));

        // Get corner values
        const c000 = self.getValueAt(r0, g0, b0);
        const c111 = self.getValueAt(r1, g1, b1);

        // Determine which tetrahedron we're in
        var result: [3]f32 = undefined;

        if (rf > gf) {
            if (gf > bf) {
                // Tetrahedron 1: r > g > b
                const c100 = self.getValueAt(r1, g0, b0);
                const c110 = self.getValueAt(r1, g1, b0);
                result = tetraInterp(c000, c100, c110, c111, rf, gf, bf);
            } else if (rf > bf) {
                // Tetrahedron 2: r > b > g
                const c100 = self.getValueAt(r1, g0, b0);
                const c101 = self.getValueAt(r1, g0, b1);
                result = tetraInterp(c000, c100, c101, c111, rf, bf, gf);
            } else {
                // Tetrahedron 3: b > r > g
                const c001 = self.getValueAt(r0, g0, b1);
                const c101 = self.getValueAt(r1, g0, b1);
                result = tetraInterp(c000, c001, c101, c111, bf, rf, gf);
            }
        } else {
            if (bf > gf) {
                // Tetrahedron 4: b > g > r
                const c001 = self.getValueAt(r0, g0, b1);
                const c011 = self.getValueAt(r0, g1, b1);
                result = tetraInterp(c000, c001, c011, c111, bf, gf, rf);
            } else if (bf > rf) {
                // Tetrahedron 5: g > b > r
                const c010 = self.getValueAt(r0, g1, b0);
                const c011 = self.getValueAt(r0, g1, b1);
                result = tetraInterp(c000, c010, c011, c111, gf, bf, rf);
            } else {
                // Tetrahedron 6: g > r > b
                const c010 = self.getValueAt(r0, g1, b0);
                const c110 = self.getValueAt(r1, g1, b0);
                result = tetraInterp(c000, c010, c110, c111, gf, rf, bf);
            }
        }

        return .{ .r = result[0], .g = result[1], .b = result[2] };
    }
};

fn lerp3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] * (1.0 - t) + b[0] * t,
        a[1] * (1.0 - t) + b[1] * t,
        a[2] * (1.0 - t) + b[2] * t,
    };
}

fn tetraInterp(v0: [3]f32, v1: [3]f32, v2: [3]f32, v3: [3]f32, w1: f32, w2: f32, w3: f32) [3]f32 {
    const w0 = 1.0 - w1;
    return .{
        v0[0] * w0 + (v1[0] - v0[0]) * w1 + (v2[0] - v1[0]) * w2 + (v3[0] - v2[0]) * w3,
        v0[1] * w0 + (v1[1] - v0[1]) * w1 + (v2[1] - v1[1]) * w2 + (v3[1] - v2[1]) * w3,
        v0[2] * w0 + (v1[2] - v0[2]) * w1 + (v2[2] - v1[2]) * w2 + (v3[2] - v2[2]) * w3,
    };
}

// ============================================================================
// .cube Format Parser (Adobe/Resolve)
// ============================================================================

pub fn parseCube(data: []const u8, allocator: Allocator) !union(enum) {
    lut_1d: Lut1D,
    lut_3d: Lut3D,
} {
    var lines = std.mem.splitScalar(u8, data, '\n');

    var title: [256]u8 = [_]u8{0} ** 256;
    var title_len: u8 = 0;
    var lut_size: u32 = 0;
    var lut_1d_size: u32 = 0;
    var domain_min: [3]f32 = .{ 0.0, 0.0, 0.0 };
    var domain_max: [3]f32 = .{ 1.0, 1.0, 1.0 };
    var is_3d = false;

    var data_values = std.ArrayList(f32).init(allocator);
    defer data_values.deinit();

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "TITLE")) {
            // Parse title (may be quoted)
            var rest = trimmed[5..];
            rest = std.mem.trim(u8, rest, " \t\"");
            const len = @min(rest.len, 255);
            @memcpy(title[0..len], rest[0..len]);
            title_len = @intCast(len);
        } else if (std.mem.startsWith(u8, trimmed, "LUT_3D_SIZE")) {
            is_3d = true;
            const size_str = std.mem.trim(u8, trimmed[11..], " \t");
            lut_size = std.fmt.parseInt(u32, size_str, 10) catch 0;
        } else if (std.mem.startsWith(u8, trimmed, "LUT_1D_SIZE")) {
            is_3d = false;
            const size_str = std.mem.trim(u8, trimmed[11..], " \t");
            lut_1d_size = std.fmt.parseInt(u32, size_str, 10) catch 0;
        } else if (std.mem.startsWith(u8, trimmed, "DOMAIN_MIN")) {
            var parts = std.mem.tokenizeScalar(u8, trimmed[10..], ' ');
            for (0..3) |i| {
                if (parts.next()) |part| {
                    domain_min[i] = std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t")) catch 0.0;
                }
            }
        } else if (std.mem.startsWith(u8, trimmed, "DOMAIN_MAX")) {
            var parts = std.mem.tokenizeScalar(u8, trimmed[10..], ' ');
            for (0..3) |i| {
                if (parts.next()) |part| {
                    domain_max[i] = std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t")) catch 1.0;
                }
            }
        } else {
            // Try to parse as RGB values
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            var count: u8 = 0;
            while (parts.next()) |part| : (count += 1) {
                if (count >= 3) break;
                const val = std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t")) catch continue;
                try data_values.append(val);
            }
        }
    }

    if (is_3d and lut_size > 0) {
        const expected = lut_size * lut_size * lut_size * 3;
        if (data_values.items.len < expected) {
            return error.IncompleteLut;
        }

        var lut = Lut3D{
            .size = lut_size,
            .domain_min = domain_min,
            .domain_max = domain_max,
            .data = try allocator.dupe(f32, data_values.items[0..expected]),
            .allocator = allocator,
        };
        lut.title = title;
        lut.title_len = title_len;
        return .{ .lut_3d = lut };
    } else if (lut_1d_size > 0) {
        const expected = lut_1d_size * 3;
        if (data_values.items.len < expected) {
            return error.IncompleteLut;
        }

        // Split into R, G, B channels
        var red = try allocator.alloc(f32, lut_1d_size);
        var green = try allocator.alloc(f32, lut_1d_size);
        var blue = try allocator.alloc(f32, lut_1d_size);

        for (0..lut_1d_size) |i| {
            red[i] = data_values.items[i * 3];
            green[i] = data_values.items[i * 3 + 1];
            blue[i] = data_values.items[i * 3 + 2];
        }

        var lut = Lut1D{
            .size = lut_1d_size,
            .domain_min = domain_min,
            .domain_max = domain_max,
            .red = red,
            .green = green,
            .blue = blue,
            .allocator = allocator,
        };
        lut.title = title;
        lut.title_len = title_len;
        return .{ .lut_1d = lut };
    }

    return error.InvalidLutFormat;
}

// ============================================================================
// .3dl Format Parser (Lustre/Flame)
// ============================================================================

pub fn parse3dl(data: []const u8, allocator: Allocator) !Lut3D {
    var lines = std.mem.splitScalar(u8, data, '\n');

    // First line contains input bit depth info
    const first_line = lines.next() orelse return error.InvalidFormat;
    _ = first_line; // Skip header line

    // Second line contains shaper LUT info (we skip it)
    _ = lines.next();

    var data_values = std.ArrayList(f32).init(allocator);
    defer data_values.deinit();

    var max_value: f32 = 4095.0; // 12-bit default

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
        while (parts.next()) |part| {
            const val = std.fmt.parseInt(u32, std.mem.trim(u8, part, " \t"), 10) catch continue;
            try data_values.append(@as(f32, @floatFromInt(val)) / max_value);
        }
    }

    // Determine cube size from data count
    const total_values = data_values.items.len;
    const cube_entries = total_values / 3;

    // Find cube root
    var size: u32 = 2;
    while (size * size * size < cube_entries and size < 256) {
        size += 1;
    }

    if (size * size * size != cube_entries) {
        return error.InvalidLutSize;
    }

    return Lut3D{
        .size = size,
        .data = try allocator.dupe(f32, data_values.items),
        .allocator = allocator,
    };
}

// ============================================================================
// .csp Format Parser (Rising Sun Research)
// ============================================================================

pub fn parseCsp(data: []const u8, allocator: Allocator) !Lut3D {
    var lines = std.mem.splitScalar(u8, data, '\n');

    var size: u32 = 0;
    var in_3d_section = false;

    var data_values = std.ArrayList(f32).init(allocator);
    defer data_values.deinit();

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "CSPLUTV100")) continue;
        if (std.mem.eql(u8, trimmed, "3D")) {
            in_3d_section = true;
            continue;
        }

        if (in_3d_section and size == 0) {
            // First line after "3D" is the size
            size = std.fmt.parseInt(u32, trimmed, 10) catch continue;
            continue;
        }

        if (in_3d_section and size > 0) {
            // Parse RGB values
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            while (parts.next()) |part| {
                const val = std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t")) catch continue;
                try data_values.append(val);
            }
        }
    }

    if (size == 0) return error.InvalidFormat;

    return Lut3D{
        .size = size,
        .data = try allocator.dupe(f32, data_values.items),
        .allocator = allocator,
    };
}

// ============================================================================
// LUT Application to Image Buffer
// ============================================================================

pub const LutProcessor = struct {
    /// Apply 3D LUT to RGB float buffer (values 0.0-1.0)
    pub fn apply3D(lut: *const Lut3D, buffer: []f32, width: u32, height: u32, use_tetrahedral: bool) void {
        const pixels = width * height;
        var i: usize = 0;
        while (i < pixels and i * 3 + 2 < buffer.len) : (i += 1) {
            const r = buffer[i * 3];
            const g = buffer[i * 3 + 1];
            const b = buffer[i * 3 + 2];

            const result = if (use_tetrahedral)
                lut.applyTetrahedral(r, g, b)
            else
                lut.apply(r, g, b);

            buffer[i * 3] = result.r;
            buffer[i * 3 + 1] = result.g;
            buffer[i * 3 + 2] = result.b;
        }
    }

    /// Apply 1D LUT to RGB float buffer
    pub fn apply1D(lut: *const Lut1D, buffer: []f32, width: u32, height: u32) void {
        const pixels = width * height;
        var i: usize = 0;
        while (i < pixels and i * 3 + 2 < buffer.len) : (i += 1) {
            const r = buffer[i * 3];
            const g = buffer[i * 3 + 1];
            const b = buffer[i * 3 + 2];

            const result = lut.apply(r, g, b);

            buffer[i * 3] = result.r;
            buffer[i * 3 + 1] = result.g;
            buffer[i * 3 + 2] = result.b;
        }
    }

    /// Apply 3D LUT to 8-bit RGB buffer
    pub fn apply3D_u8(lut: *const Lut3D, buffer: []u8, width: u32, height: u32) void {
        const pixels = width * height;
        var i: usize = 0;
        while (i < pixels and i * 3 + 2 < buffer.len) : (i += 1) {
            const r = @as(f32, @floatFromInt(buffer[i * 3])) / 255.0;
            const g = @as(f32, @floatFromInt(buffer[i * 3 + 1])) / 255.0;
            const b = @as(f32, @floatFromInt(buffer[i * 3 + 2])) / 255.0;

            const result = lut.apply(r, g, b);

            buffer[i * 3] = @intFromFloat(std.math.clamp(result.r * 255.0, 0, 255));
            buffer[i * 3 + 1] = @intFromFloat(std.math.clamp(result.g * 255.0, 0, 255));
            buffer[i * 3 + 2] = @intFromFloat(std.math.clamp(result.b * 255.0, 0, 255));
        }
    }

    /// Apply 1D LUT to 8-bit RGB buffer
    pub fn apply1D_u8(lut: *const Lut1D, buffer: []u8, width: u32, height: u32) void {
        const pixels = width * height;
        var i: usize = 0;
        while (i < pixels and i * 3 + 2 < buffer.len) : (i += 1) {
            const r = @as(f32, @floatFromInt(buffer[i * 3])) / 255.0;
            const g = @as(f32, @floatFromInt(buffer[i * 3 + 1])) / 255.0;
            const b = @as(f32, @floatFromInt(buffer[i * 3 + 2])) / 255.0;

            const result = lut.apply(r, g, b);

            buffer[i * 3] = @intFromFloat(std.math.clamp(result.r * 255.0, 0, 255));
            buffer[i * 3 + 1] = @intFromFloat(std.math.clamp(result.g * 255.0, 0, 255));
            buffer[i * 3 + 2] = @intFromFloat(std.math.clamp(result.b * 255.0, 0, 255));
        }
    }
};

// ============================================================================
// LUT Generation Utilities
// ============================================================================

pub const LutGenerator = struct {
    /// Create identity 3D LUT
    pub fn createIdentity3D(size: u32, allocator: Allocator) !Lut3D {
        const total = size * size * size * 3;
        var data = try allocator.alloc(f32, total);

        const size_f = @as(f32, @floatFromInt(size - 1));
        var idx: usize = 0;

        for (0..size) |bi| {
            for (0..size) |gi| {
                for (0..size) |ri| {
                    data[idx] = @as(f32, @floatFromInt(ri)) / size_f;
                    data[idx + 1] = @as(f32, @floatFromInt(gi)) / size_f;
                    data[idx + 2] = @as(f32, @floatFromInt(bi)) / size_f;
                    idx += 3;
                }
            }
        }

        return Lut3D{
            .size = size,
            .data = data,
            .allocator = allocator,
        };
    }

    /// Create identity 1D LUT
    pub fn createIdentity1D(size: u32, allocator: Allocator) !Lut1D {
        var red = try allocator.alloc(f32, size);
        var green = try allocator.alloc(f32, size);
        var blue = try allocator.alloc(f32, size);

        const size_f = @as(f32, @floatFromInt(size - 1));
        for (0..size) |i| {
            const val = @as(f32, @floatFromInt(i)) / size_f;
            red[i] = val;
            green[i] = val;
            blue[i] = val;
        }

        return Lut1D{
            .size = size,
            .red = red,
            .green = green,
            .blue = blue,
            .allocator = allocator,
        };
    }

    /// Create gamma correction 1D LUT
    pub fn createGamma1D(size: u32, gamma: f32, allocator: Allocator) !Lut1D {
        var red = try allocator.alloc(f32, size);
        var green = try allocator.alloc(f32, size);
        var blue = try allocator.alloc(f32, size);

        const size_f = @as(f32, @floatFromInt(size - 1));
        const inv_gamma = 1.0 / gamma;

        for (0..size) |i| {
            const normalized = @as(f32, @floatFromInt(i)) / size_f;
            const corrected = std.math.pow(normalized, inv_gamma);
            red[i] = corrected;
            green[i] = corrected;
            blue[i] = corrected;
        }

        return Lut1D{
            .size = size,
            .red = red,
            .green = green,
            .blue = blue,
            .allocator = allocator,
        };
    }

    /// Create contrast adjustment 1D LUT
    pub fn createContrast1D(size: u32, contrast: f32, allocator: Allocator) !Lut1D {
        var red = try allocator.alloc(f32, size);
        var green = try allocator.alloc(f32, size);
        var blue = try allocator.alloc(f32, size);

        const size_f = @as(f32, @floatFromInt(size - 1));
        const factor = (259.0 * (contrast + 255.0)) / (255.0 * (259.0 - contrast));

        for (0..size) |i| {
            const normalized = @as(f32, @floatFromInt(i)) / size_f;
            const adjusted = std.math.clamp(factor * (normalized - 0.5) + 0.5, 0.0, 1.0);
            red[i] = adjusted;
            green[i] = adjusted;
            blue[i] = adjusted;
        }

        return Lut1D{
            .size = size,
            .red = red,
            .green = green,
            .blue = blue,
            .allocator = allocator,
        };
    }
};

// ============================================================================
// LUT Serialization
// ============================================================================

pub const LutWriter = struct {
    /// Write 3D LUT to .cube format
    pub fn writeCube3D(lut: *const Lut3D, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        var writer = output.writer();

        // Header
        if (lut.title_len > 0) {
            try writer.print("TITLE \"{s}\"\n", .{lut.getTitle()});
        }
        try writer.print("LUT_3D_SIZE {d}\n", .{lut.size});
        try writer.print("DOMAIN_MIN {d:.6} {d:.6} {d:.6}\n", .{
            lut.domain_min[0],
            lut.domain_min[1],
            lut.domain_min[2],
        });
        try writer.print("DOMAIN_MAX {d:.6} {d:.6} {d:.6}\n\n", .{
            lut.domain_max[0],
            lut.domain_max[1],
            lut.domain_max[2],
        });

        // Data
        const entries = lut.size * lut.size * lut.size;
        for (0..entries) |i| {
            const idx = i * 3;
            try writer.print("{d:.6} {d:.6} {d:.6}\n", .{
                lut.data[idx],
                lut.data[idx + 1],
                lut.data[idx + 2],
            });
        }

        return output.toOwnedSlice();
    }

    /// Write 1D LUT to .cube format
    pub fn writeCube1D(lut: *const Lut1D, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        var writer = output.writer();

        // Header
        if (lut.title_len > 0) {
            try writer.print("TITLE \"{s}\"\n", .{lut.getTitle()});
        }
        try writer.print("LUT_1D_SIZE {d}\n", .{lut.size});
        try writer.print("DOMAIN_MIN {d:.6} {d:.6} {d:.6}\n", .{
            lut.domain_min[0],
            lut.domain_min[1],
            lut.domain_min[2],
        });
        try writer.print("DOMAIN_MAX {d:.6} {d:.6} {d:.6}\n\n", .{
            lut.domain_max[0],
            lut.domain_max[1],
            lut.domain_max[2],
        });

        // Data
        for (0..lut.size) |i| {
            try writer.print("{d:.6} {d:.6} {d:.6}\n", .{
                lut.red[i],
                lut.green[i],
                lut.blue[i],
            });
        }

        return output.toOwnedSlice();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Parse .cube 3D LUT" {
    const testing = std.testing;

    const cube_data =
        \\TITLE "Test LUT"
        \\LUT_3D_SIZE 2
        \\DOMAIN_MIN 0.0 0.0 0.0
        \\DOMAIN_MAX 1.0 1.0 1.0
        \\
        \\0.0 0.0 0.0
        \\1.0 0.0 0.0
        \\0.0 1.0 0.0
        \\1.0 1.0 0.0
        \\0.0 0.0 1.0
        \\1.0 0.0 1.0
        \\0.0 1.0 1.0
        \\1.0 1.0 1.0
    ;

    const result = try parseCube(cube_data, testing.allocator);
    defer switch (result) {
        .lut_3d => |*l| @constCast(l).deinit(),
        .lut_1d => |*l| @constCast(l).deinit(),
    };

    try testing.expectEqual(result, .lut_3d);
    const lut = result.lut_3d;
    try testing.expectEqual(@as(u32, 2), lut.size);
    try testing.expect(std.mem.eql(u8, lut.getTitle(), "Test LUT"));
}

test "3D LUT trilinear interpolation" {
    const testing = std.testing;

    // Create identity LUT
    var lut = try LutGenerator.createIdentity3D(17, testing.allocator);
    defer lut.deinit();

    // Identity should return same values
    const result = lut.apply(0.5, 0.25, 0.75);
    try testing.expectApproxEqAbs(@as(f32, 0.5), result.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.25), result.g, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.75), result.b, 0.01);
}

test "1D LUT interpolation" {
    const testing = std.testing;

    var lut = try LutGenerator.createIdentity1D(256, testing.allocator);
    defer lut.deinit();

    const result = lut.apply(0.5, 0.25, 0.75);
    try testing.expectApproxEqAbs(@as(f32, 0.5), result.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.25), result.g, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.75), result.b, 0.01);
}

test "Gamma LUT" {
    const testing = std.testing;

    var lut = try LutGenerator.createGamma1D(256, 2.2, testing.allocator);
    defer lut.deinit();

    // Mid-gray (0.5) with gamma 2.2 inverse should give ~0.73
    const result = lut.apply(0.5, 0.5, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.73), result.r, 0.01);
}

test "LUT to buffer application" {
    const testing = std.testing;

    var lut = try LutGenerator.createIdentity3D(17, testing.allocator);
    defer lut.deinit();

    var buffer = [_]f32{ 0.25, 0.5, 0.75, 0.1, 0.2, 0.3 };
    LutProcessor.apply3D(&lut, &buffer, 2, 1, false);

    try testing.expectApproxEqAbs(@as(f32, 0.25), buffer[0], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.5), buffer[1], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.75), buffer[2], 0.02);
}
