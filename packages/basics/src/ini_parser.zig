// INI Parser for Home Language
// Used for parsing C&C Generals game data files
// Format: [Section]\nkey=value\n; comments

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const IniValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

pub const IniEntry = struct {
    key: []const u8,
    value: IniValue,

    pub fn deinit(self: *IniEntry, allocator: Allocator) void {
        allocator.free(self.key);
        switch (self.value) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

pub const IniSection = struct {
    name: []const u8,
    entries: std.StringHashMap(IniValue),

    pub fn init(allocator: Allocator, name: []const u8) !IniSection {
        return .{
            .name = try allocator.dupe(u8, name),
            .entries = std.StringHashMap(IniValue).init(allocator),
        };
    }

    pub fn deinit(self: *IniSection, allocator: Allocator) void {
        allocator.free(self.name);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
        self.entries.deinit();
    }

    pub fn get(self: *const IniSection, key: []const u8) ?IniValue {
        return self.entries.get(key);
    }

    pub fn getString(self: *const IniSection, key: []const u8) ?[]const u8 {
        if (self.entries.get(key)) |value| {
            switch (value) {
                .string => |s| return s,
                else => return null,
            }
        }
        return null;
    }

    pub fn getInt(self: *const IniSection, key: []const u8) ?i64 {
        if (self.entries.get(key)) |value| {
            switch (value) {
                .integer => |i| return i,
                else => return null,
            }
        }
        return null;
    }

    pub fn getFloat(self: *const IniSection, key: []const u8) ?f64 {
        if (self.entries.get(key)) |value| {
            switch (value) {
                .float => |f| return f,
                else => return null,
            }
        }
        return null;
    }

    pub fn getBool(self: *const IniSection, key: []const u8) ?bool {
        if (self.entries.get(key)) |value| {
            switch (value) {
                .boolean => |b| return b,
                else => return null,
            }
        }
        return null;
    }
};

pub const IniFile = struct {
    allocator: Allocator,
    sections: std.StringHashMap(IniSection),

    pub fn init(allocator: Allocator) IniFile {
        return .{
            .allocator = allocator,
            .sections = std.StringHashMap(IniSection).init(allocator),
        };
    }

    pub fn deinit(self: *IniFile) void {
        var it = self.sections.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var section = entry.value_ptr;
            section.deinit(self.allocator);
        }
        self.sections.deinit();
    }

    pub fn parse(allocator: Allocator, content: []const u8) !IniFile {
        var ini = IniFile.init(allocator);
        errdefer ini.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_section: ?*IniSection = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines
            if (trimmed.len == 0) continue;

            // Skip comments
            if (trimmed[0] == ';' or trimmed[0] == '#') continue;

            // Section header [SectionName] or Generals format "Word Word"
            if (trimmed[0] == '[') {
                if (std.mem.indexOfScalar(u8, trimmed, ']')) |close_bracket| {
                    const section_name = std.mem.trim(u8, trimmed[1..close_bracket], " \t");
                    const section = try ini.getOrCreateSection(section_name);
                    current_section = section;
                }
                continue;
            }

            // C&C Generals format: "Weapon WeaponName" or "Object ObjectName"
            // Check for section-starting keywords without =
            const has_equals = std.mem.indexOfScalar(u8, trimmed, '=') != null;
            if (!has_equals) {
                // Check for End keyword
                if (std.mem.eql(u8, trimmed, "End")) {
                    continue;
                }
                // Treat as section header (e.g., "Weapon AVCrusaderTankGun")
                const section_name = trimmed;
                const section = try ini.getOrCreateSection(section_name);
                current_section = section;
                continue;
            }

            // Key=Value pair
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                var value_str = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                // Remove inline comments
                if (std.mem.indexOfScalar(u8, value_str, ';')) |comment_pos| {
                    value_str = std.mem.trim(u8, value_str[0..comment_pos], " \t");
                }

                const value = try parseValue(allocator, value_str);

                if (current_section) |section| {
                    const key_copy = try allocator.dupe(u8, key);
                    try section.entries.put(key_copy, value);
                }
            }
        }

        return ini;
    }

    pub fn parseFile(allocator: Allocator, path: []const u8) !IniFile {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(content);

        return try parse(allocator, content);
    }

    pub fn getSection(self: *const IniFile, name: []const u8) ?*const IniSection {
        if (self.sections.getPtr(name)) |section| {
            return section;
        }
        return null;
    }

    fn getOrCreateSection(self: *IniFile, name: []const u8) !*IniSection {
        if (self.sections.getPtr(name)) |section| {
            return section;
        }

        const section = try IniSection.init(self.allocator, name);
        const name_copy = try self.allocator.dupe(u8, name);
        try self.sections.put(name_copy, section);
        return self.sections.getPtr(name_copy).?;
    }

    pub fn getValue(self: *const IniFile, section_name: []const u8, key: []const u8) ?IniValue {
        if (self.getSection(section_name)) |section| {
            return section.get(key);
        }
        return null;
    }

    pub fn getString(self: *const IniFile, section_name: []const u8, key: []const u8) ?[]const u8 {
        if (self.getSection(section_name)) |section| {
            return section.getString(key);
        }
        return null;
    }

    pub fn getInt(self: *const IniFile, section_name: []const u8, key: []const u8) ?i64 {
        if (self.getSection(section_name)) |section| {
            return section.getInt(key);
        }
        return null;
    }

    pub fn getFloat(self: *const IniFile, section_name: []const u8, key: []const u8) ?f64 {
        if (self.getSection(section_name)) |section| {
            return section.getFloat(key);
        }
        return null;
    }

    pub fn getBool(self: *const IniFile, section_name: []const u8, key: []const u8) ?bool {
        if (self.getSection(section_name)) |section| {
            return section.getBool(key);
        }
        return null;
    }
};

fn parseValue(allocator: Allocator, str: []const u8) !IniValue {
    // Try boolean
    if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "yes") or std.mem.eql(u8, str, "Yes") or std.mem.eql(u8, str, "YES")) {
        return IniValue{ .boolean = true };
    }
    if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "no") or std.mem.eql(u8, str, "No") or std.mem.eql(u8, str, "NO")) {
        return IniValue{ .boolean = false };
    }

    // Try integer
    if (std.fmt.parseInt(i64, str, 10)) |int_val| {
        return IniValue{ .integer = int_val };
    } else |_| {}

    // Try float
    if (std.fmt.parseFloat(f64, str)) |float_val| {
        return IniValue{ .float = float_val };
    } else |_| {}

    // Default to string
    return IniValue{ .string = try allocator.dupe(u8, str) };
}

// Tests
test "IniParser - basic parsing" {
    const content =
        \\[Section1]
        \\key1=value1
        \\key2=42
        \\
        \\[Section2]
        \\key3=3.14
        \\key4=true
    ;

    var ini = try IniFile.parse(std.testing.allocator, content);
    defer ini.deinit();

    const val1 = ini.getString("Section1", "key1");
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("value1", val1.?);

    const val2 = ini.getInt("Section1", "key2");
    try std.testing.expect(val2 != null);
    try std.testing.expectEqual(@as(i64, 42), val2.?);

    const val3 = ini.getFloat("Section2", "key3");
    try std.testing.expect(val3 != null);
    try std.testing.expectApproxEqAbs(3.14, val3.?, 0.001);

    const val4 = ini.getBool("Section2", "key4");
    try std.testing.expect(val4 != null);
    try std.testing.expect(val4.? == true);
}

test "IniParser - comments and whitespace" {
    const content =
        \\; This is a comment
        \\[Section1]
        \\  key1  =  value1  ; inline comment
        \\# Another comment style
        \\key2=42
    ;

    var ini = try IniFile.parse(std.testing.allocator, content);
    defer ini.deinit();

    const val1 = ini.getString("Section1", "key1");
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("value1", val1.?);
}

test "IniParser - C&C Generals format" {
    const content =
        \\Weapon AVCrusaderTankGun
        \\  AttackRange = 200.0
        \\  RadiusDamageAffects = ENEMIES
        \\  DelayBetweenShots = 2000
        \\  WeaponSpeed = 400
        \\End
    ;

    var ini = try IniFile.parse(std.testing.allocator, content);
    defer ini.deinit();

    const range = ini.getFloat("Weapon AVCrusaderTankGun", "AttackRange");
    try std.testing.expect(range != null);
    try std.testing.expectApproxEqAbs(200.0, range.?, 0.001);

    const delay = ini.getInt("Weapon AVCrusaderTankGun", "DelayBetweenShots");
    try std.testing.expect(delay != null);
    try std.testing.expectEqual(@as(i64, 2000), delay.?);
}
