// INI Parser for Home Language
// Based on Command & Conquer Generals' INI format
// Supports sections, properties, nested blocks, and comments

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const HashMap = @import("collections").HashMap;
const PropertyMap = HashMap([]const u8, []const u8);

/// Represents a parsed INI file
pub const IniFile = struct {
    allocator: Allocator,
    // Map of section name -> Section
    sections: HashMap([]const u8, Section),

    pub const Section = struct {
        allocator: Allocator,
        name: []const u8,
        // Map of property key -> property value
        properties: PropertyMap,
        // Nested blocks (for Generals' complex Object blocks)
        blocks: std.ArrayList(Block),

        pub const Block = struct {
            name: []const u8,
            tag: []const u8, // ModuleTag_01, etc.
            properties: PropertyMap,
            sub_blocks: std.ArrayList(Block),

            pub fn init(allocator: Allocator, name: []const u8, tag: []const u8) !Block {
                const owned_name = try allocator.dupe(u8, name);
                errdefer allocator.free(owned_name);
                const owned_tag = try allocator.dupe(u8, tag);
                errdefer allocator.free(owned_tag);
                const sub_blocks = try std.ArrayList(Block).initCapacity(allocator, 2);
                return .{
                    .name = owned_name,
                    .tag = owned_tag,
                    .properties = PropertyMap.init(allocator),
                    .sub_blocks = sub_blocks,
                };
            }

            pub fn deinit(self: *Block, allocator: Allocator) void {
                allocator.free(self.name);
                allocator.free(self.tag);

                var prop_iter = self.properties.iterator();
                while (prop_iter.next()) |entry| {
                    allocator.free(entry.key);
                    allocator.free(entry.value);
                }
                self.properties.deinit();

                for (self.sub_blocks.items) |*sub| sub.deinit(allocator);
                self.sub_blocks.deinit(allocator);
            }
        };

        pub fn init(allocator: Allocator, name: []const u8) !Section {
            // Dupe the name first, then errdefer-free it so that a later
            // `initCapacity` failure doesn't leak the duped name.
            const name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(name_copy);
            const blocks = try std.ArrayList(Block).initCapacity(allocator, 4);
            return Section{
                .allocator = allocator,
                .name = name_copy,
                .properties = PropertyMap.init(allocator),
                .blocks = blocks,
            };
        }

        pub fn deinit(self: *Section) void {
            self.allocator.free(self.name);

            // Free all properties
            var prop_iter = self.properties.iterator();
            while (prop_iter.next()) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            self.properties.deinit();

            // Free all blocks
            for (self.blocks.items) |*block| {
                block.deinit(self.allocator);
            }
            self.blocks.deinit(self.allocator);
        }

        pub fn get(self: *const Section, key: []const u8) ?[]const u8 {
            return self.properties.get(key);
        }

        pub fn getInt(self: *const Section, key: []const u8) ?i32 {
            if (self.get(key)) |value| {
                return std.fmt.parseInt(i32, value, 10) catch null;
            }
            return null;
        }

        pub fn getFloat(self: *const Section, key: []const u8) ?f64 {
            if (self.get(key)) |value| {
                return std.fmt.parseFloat(f64, value) catch null;
            }
            return null;
        }

        pub fn getBool(self: *const Section, key: []const u8) ?bool {
            if (self.get(key)) |value| {
                if (std.mem.eql(u8, value, "Yes") or std.mem.eql(u8, value, "yes") or
                    std.mem.eql(u8, value, "True") or std.mem.eql(u8, value, "true") or
                    std.mem.eql(u8, value, "1"))
                {
                    return true;
                }
                if (std.mem.eql(u8, value, "No") or std.mem.eql(u8, value, "no") or
                    std.mem.eql(u8, value, "False") or std.mem.eql(u8, value, "false") or
                    std.mem.eql(u8, value, "0"))
                {
                    return false;
                }
            }
            return null;
        }
    };

    pub fn init(allocator: Allocator) IniFile {
        return IniFile{
            .allocator = allocator,
            .sections = HashMap([]const u8, Section).init(allocator),
        };
    }

    pub fn deinit(self: *IniFile) void {
        var iter = self.sections.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key);
            var section = entry.value;
            section.deinit();
        }
        self.sections.deinit();
    }

    /// Parse an INI file from a file path
    pub fn parseFile(allocator: Allocator, path: []const u8) !IniFile {
        return parseFileWithIo(allocator, Io.Threaded.global_single_threaded.io(), path);
    }

    /// Parse an INI file using the caller's I/O implementation.
    pub fn parseFileWithIo(allocator: Allocator, io: Io, path: []const u8) !IniFile {
        const content = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(content);

        return try parse(allocator, content);
    }

    /// Parse INI content from a string
    pub fn parse(allocator: Allocator, content: []const u8) !IniFile {
        var ini = IniFile.init(allocator);
        errdefer ini.deinit();

        var current_section: ?*Section = null;
        var current_block_stack = try std.ArrayList(*Section.Block).initCapacity(allocator, 8);
        defer current_block_stack.deinit(allocator);

        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, &std.ascii.whitespace);

            // Skip empty lines and comments
            if (line.len == 0 or line[0] == ';') {
                continue;
            }

            // Section header: Object AmericaParachute
            if (std.mem.startsWith(u8, line, "Object ")) {
                const section_name = std.mem.trim(u8, line[7..], &std.ascii.whitespace);
                const section = try Section.init(allocator, section_name);
                current_section = try ini.putSection(section_name, section);
                current_block_stack.clearRetainingCapacity();
                continue;
            }

            // End of section
            if (std.mem.eql(u8, line, "End")) {
                if (current_block_stack.items.len > 0) {
                    // End of a block
                    _ = current_block_stack.pop();
                } else {
                    // End of section
                    current_section = null;
                }
                continue;
            }

            // Block start (e.g., "Draw = W3DModelDraw ModuleTag_01")
            if (std.mem.indexOf(u8, line, " = ") != null and
                current_section != null and
                !std.mem.startsWith(u8, std.mem.trim(u8, line, &std.ascii.whitespace), "  "))
            {
                const equals_pos = std.mem.indexOf(u8, line, " = ").?;
                const key = std.mem.trim(u8, line[0..equals_pos], &std.ascii.whitespace);
                const rest = std.mem.trim(u8, line[equals_pos + 3 ..], &std.ascii.whitespace);

                // Check if this starts a block (has two parts after =)
                var parts = std.mem.splitSequence(u8, rest, " ");
                _ = parts.next() orelse ""; // block_type (unused but needed for iteration)
                const block_tag = parts.next() orelse "";

                if (block_tag.len > 0) {
                    var block = try Section.Block.init(allocator, key, block_tag);
                    var owns_block = true;
                    errdefer if (owns_block) block.deinit(allocator);

                    if (current_block_stack.items.len > 0) {
                        // Nested block
                        const parent = current_block_stack.items[current_block_stack.items.len - 1];
                        try parent.sub_blocks.append(allocator, block);
                        owns_block = false;
                        const added_block = &parent.sub_blocks.items[parent.sub_blocks.items.len - 1];
                        try current_block_stack.append(allocator, added_block);
                    } else if (current_section) |sec| {
                        // Top-level block
                        try sec.blocks.append(allocator, block);
                        owns_block = false;
                        const added_block = &sec.blocks.items[sec.blocks.items.len - 1];
                        try current_block_stack.append(allocator, added_block);
                    }
                    continue;
                }
            }

            // Property line (key = value or just key value)
            if (current_section) |sec| {
                const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

                // Handle both "=" and whitespace separators
                if (std.mem.indexOf(u8, trimmed, " = ")) |equals_pos| {
                    const key = std.mem.trim(u8, trimmed[0..equals_pos], &std.ascii.whitespace);
                    const value = std.mem.trim(u8, trimmed[equals_pos + 3 ..], &std.ascii.whitespace);

                    if (current_block_stack.items.len > 0) {
                        // Property in a block
                        const block = current_block_stack.items[current_block_stack.items.len - 1];
                        try putProperty(allocator, &block.properties, key, value);
                    } else {
                        // Property in section
                        try putProperty(allocator, &sec.properties, key, value);
                    }
                } else {
                    // Handle "Key Value" format (whitespace separated)
                    var parts = std.mem.splitSequence(u8, trimmed, " ");
                    const key = parts.next() orelse continue;
                    const rest_start = key.len;
                    if (rest_start < trimmed.len) {
                        const value = std.mem.trim(u8, trimmed[rest_start..], &std.ascii.whitespace);

                        if (current_block_stack.items.len > 0) {
                            const block = current_block_stack.items[current_block_stack.items.len - 1];
                            try putProperty(allocator, &block.properties, key, value);
                        } else {
                            try putProperty(allocator, &sec.properties, key, value);
                        }
                    }
                }
            }
        }

        return ini;
    }

    fn putSection(self: *IniFile, name: []const u8, section: Section) !*Section {
        var owned_section = section;
        var transferred = false;
        errdefer if (!transferred) owned_section.deinit();

        if (self.sections.getPtr(name)) |existing| {
            existing.deinit();
            existing.* = owned_section;
            transferred = true;
            return existing;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.sections.put(owned_name, owned_section);
        transferred = true;
        return self.sections.getPtr(owned_name).?;
    }

    fn putProperty(allocator: Allocator, properties: *PropertyMap, key: []const u8, value: []const u8) !void {
        if (properties.getPtr(key)) |existing| {
            const owned_value = try allocator.dupe(u8, value);
            allocator.free(existing.*);
            existing.* = owned_value;
            return;
        }

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        try properties.put(owned_key, owned_value);
    }

    pub fn getSection(self: *const IniFile, name: []const u8) ?Section {
        return self.sections.get(name);
    }

    pub fn getSectionNames(self: *const IniFile) ![][]const u8 {
        return try self.sections.keys(self.allocator);
    }
};

// ==================== Tests ====================

test "INI Parser: basic section and properties" {
    const allocator = std.testing.allocator;

    const ini_content =
        \\; Comment line
        \\Object TestUnit
        \\  Side = America
        \\  VisionRange = 300.0
        \\  IsTrainable = Yes
        \\End
    ;

    var ini = try IniFile.parse(allocator, ini_content);
    defer ini.deinit();

    const section = ini.getSection("TestUnit");
    try std.testing.expect(section != null);

    if (section) |sec| {
        try std.testing.expectEqualStrings("America", sec.get("Side").?);
        try std.testing.expectEqual(@as(?f64, 300.0), sec.getFloat("VisionRange"));
        try std.testing.expectEqual(@as(?bool, true), sec.getBool("IsTrainable"));
    }
}

test "INI Parser: nested blocks" {
    const allocator = std.testing.allocator;

    const ini_content =
        \\Object TestUnit
        \\  Draw = W3DModelDraw ModuleTag_01
        \\    Model = test.w3d
        \\    Animation = test.skl
        \\  End
        \\End
    ;

    var ini = try IniFile.parse(allocator, ini_content);
    defer ini.deinit();

    const section = ini.getSection("TestUnit");
    try std.testing.expect(section != null);

    if (section) |sec| {
        try std.testing.expectEqual(@as(usize, 1), sec.blocks.items.len);
        const block = sec.blocks.items[0];
        try std.testing.expectEqualStrings("Draw", block.name);
        try std.testing.expectEqualStrings("ModuleTag_01", block.tag);
    }
}

test "INI Parser: parse file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "test.ini" });
    defer allocator.free(test_file);
    const ini_content =
        \\Object Tank
        \\  Health = 100
        \\  Speed = 50.0
        \\  CanFire = Yes
        \\End
        \\
        \\Object Infantry
        \\  Health = 25
        \\  Speed = 75.0
        \\  CanFire = No
        \\End
    ;

    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = test_file, .data = ini_content });

    // Parse it
    var ini = try IniFile.parseFileWithIo(allocator, std.testing.io, test_file);
    defer ini.deinit();

    // Check tank
    const tank = ini.getSection("Tank");
    try std.testing.expect(tank != null);
    if (tank) |t| {
        try std.testing.expectEqual(@as(?i32, 100), t.getInt("Health"));
        try std.testing.expectEqual(@as(?f64, 50.0), t.getFloat("Speed"));
        try std.testing.expectEqual(@as(?bool, true), t.getBool("CanFire"));
    }

    // Check infantry
    const infantry = ini.getSection("Infantry");
    try std.testing.expect(infantry != null);
    if (infantry) |inf| {
        try std.testing.expectEqual(@as(?i32, 25), inf.getInt("Health"));
        try std.testing.expectEqual(@as(?bool, false), inf.getBool("CanFire"));
    }
}
