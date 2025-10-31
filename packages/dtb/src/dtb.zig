// Device Tree Binary (DTB) Implementation
// Devicetree Specification v0.4

const std = @import("std");

/// DTB Magic number (0xd00dfeed)
pub const MAGIC: u32 = 0xd00dfeed;

/// DTB Version
pub const VERSION: u32 = 17;

/// FDT Header (Flattened Device Tree)
pub const FdtHeader = extern struct {
    magic: u32, // 0xd00dfeed
    totalsize: u32, // Total size of DTB in bytes
    off_dt_struct: u32, // Offset to structure block
    off_dt_strings: u32, // Offset to strings block
    off_mem_rsvmap: u32, // Offset to memory reservation block
    version: u32, // DTB version
    last_comp_version: u32, // Last compatible version
    boot_cpuid_phys: u32, // Physical CPU ID of boot processor
    size_dt_strings: u32, // Size of strings block
    size_dt_struct: u32, // Size of structure block

    pub fn fromBytes(data: []const u8) !FdtHeader {
        if (data.len < @sizeOf(FdtHeader)) {
            return error.InvalidHeader;
        }

        var header: FdtHeader = undefined;
        @memcpy(std.mem.asBytes(&header), data[0..@sizeOf(FdtHeader)]);

        // Convert from big-endian
        header.magic = std.mem.bigToNative(u32, header.magic);
        header.totalsize = std.mem.bigToNative(u32, header.totalsize);
        header.off_dt_struct = std.mem.bigToNative(u32, header.off_dt_struct);
        header.off_dt_strings = std.mem.bigToNative(u32, header.off_dt_strings);
        header.off_mem_rsvmap = std.mem.bigToNative(u32, header.off_mem_rsvmap);
        header.version = std.mem.bigToNative(u32, header.version);
        header.last_comp_version = std.mem.bigToNative(u32, header.last_comp_version);
        header.boot_cpuid_phys = std.mem.bigToNative(u32, header.boot_cpuid_phys);
        header.size_dt_strings = std.mem.bigToNative(u32, header.size_dt_strings);
        header.size_dt_struct = std.mem.bigToNative(u32, header.size_dt_struct);

        if (header.magic != MAGIC) {
            return error.InvalidMagic;
        }

        return header;
    }

    pub fn validate(self: FdtHeader) bool {
        return self.magic == MAGIC and
            self.version >= 16 and
            self.totalsize > @sizeOf(FdtHeader);
    }
};

/// FDT Tokens
pub const Token = enum(u32) {
    begin_node = 0x00000001,
    end_node = 0x00000002,
    prop = 0x00000003,
    nop = 0x00000004,
    end = 0x00000009,

    pub fn fromU32(val: u32) !Token {
        return switch (val) {
            0x00000001 => .begin_node,
            0x00000002 => .end_node,
            0x00000003 => .prop,
            0x00000004 => .nop,
            0x00000009 => .end,
            else => error.InvalidToken,
        };
    }
};

/// Memory reservation entry
pub const MemReserveEntry = extern struct {
    address: u64,
    size: u64,

    pub fn fromBytes(data: []const u8) MemReserveEntry {
        var entry: MemReserveEntry = undefined;
        @memcpy(std.mem.asBytes(&entry), data[0..@sizeOf(MemReserveEntry)]);
        entry.address = std.mem.bigToNative(u64, entry.address);
        entry.size = std.mem.bigToNative(u64, entry.size);
        return entry;
    }

    pub fn isEmpty(self: MemReserveEntry) bool {
        return self.address == 0 and self.size == 0;
    }
};

/// Device Tree Property
pub const Property = struct {
    name: []const u8,
    value: []const u8,

    pub fn asString(self: Property) ?[]const u8 {
        if (self.value.len == 0) return null;
        // Find null terminator
        const end = std.mem.indexOfScalar(u8, self.value, 0) orelse self.value.len;
        return self.value[0..end];
    }

    pub fn asU32(self: Property) ?u32 {
        if (self.value.len < 4) return null;
        const val = std.mem.readInt(u32, self.value[0..4], .big);
        return val;
    }

    pub fn asU64(self: Property) ?u64 {
        if (self.value.len < 8) return null;
        const val = std.mem.readInt(u64, self.value[0..8], .big);
        return val;
    }

    pub fn asU32Array(self: Property, allocator: std.mem.Allocator) ![]u32 {
        if (self.value.len == 0 or self.value.len % 4 != 0) {
            return error.InvalidArraySize;
        }

        const count = self.value.len / 4;
        var array = try allocator.alloc(u32, count);

        for (0..count) |i| {
            array[i] = std.mem.readInt(u32, self.value[i * 4 ..][0..4], .big);
        }

        return array;
    }

    pub fn asU64Array(self: Property, allocator: std.mem.Allocator) ![]u64 {
        if (self.value.len == 0 or self.value.len % 8 != 0) {
            return error.InvalidArraySize;
        }

        const count = self.value.len / 8;
        var array = try allocator.alloc(u64, count);

        for (0..count) |i| {
            array[i] = std.mem.readInt(u64, self.value[i * 8 ..][0..8], .big);
        }

        return array;
    }

    pub fn asStringList(self: Property, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8){};
        var offset: usize = 0;

        while (offset < self.value.len) {
            const start = offset;
            const end = std.mem.indexOfScalarPos(u8, self.value, start, 0) orelse self.value.len;
            if (end > start) {
                try list.append(allocator, self.value[start..end]);
            }
            offset = end + 1;
        }

        return list.toOwnedSlice(allocator);
    }
};

/// Device Tree Node
pub const Node = struct {
    name: []const u8,
    unit_address: ?[]const u8,
    properties: std.StringHashMap(Property),
    children: std.ArrayList(*Node),
    parent: ?*Node,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Node {
        const node = try allocator.create(Node);

        // Parse unit address if present (name@address)
        const actual_name = if (std.mem.indexOfScalar(u8, name, '@')) |at_pos|
            name[0..at_pos]
        else
            name;

        const unit_addr = if (std.mem.indexOfScalar(u8, name, '@')) |at_pos|
            try allocator.dupe(u8, name[at_pos + 1 ..])
        else
            null;

        node.* = .{
            .name = try allocator.dupe(u8, actual_name),
            .unit_address = unit_addr,
            .properties = std.StringHashMap(Property).init(allocator),
            .children = std.ArrayList(*Node){},
            .parent = null,
            .allocator = allocator,
        };

        return node;
    }

    pub fn deinit(self: *Node) void {
        self.allocator.free(self.name);
        if (self.unit_address) |addr| {
            self.allocator.free(addr);
        }

        var it = self.properties.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.properties.deinit();

        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }

    pub fn addProperty(self: *Node, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.properties.put(name_copy, Property{
            .name = name_copy,
            .value = value,
        });
    }

    pub fn getProperty(self: *const Node, name: []const u8) ?Property {
        return self.properties.get(name);
    }

    pub fn addChild(self: *Node, child: *Node) !void {
        child.parent = self;
        try self.children.append(self.allocator, child);
    }

    pub fn findChild(self: *const Node, name: []const u8) ?*Node {
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }
        return null;
    }

    pub fn getFullPath(self: *const Node, allocator: std.mem.Allocator) ![]u8 {
        var path = std.ArrayList(u8).init(allocator);

        var current: ?*const Node = self;
        while (current) |node| {
            if (node.parent != null) {
                try path.insertSlice(0, node.name);
                try path.insert(0, '/');
            }
            current = node.parent;
        }

        if (path.items.len == 0) {
            try path.append('/');
        }

        return path.toOwnedSlice();
    }

    /// Get compatible property
    pub fn getCompatible(self: *const Node, allocator: std.mem.Allocator) !?[][]const u8 {
        const prop = self.getProperty("compatible") orelse return null;
        return try prop.asStringList(allocator);
    }

    /// Get #address-cells
    pub fn getAddressCells(self: *const Node) u32 {
        if (self.getProperty("#address-cells")) |prop| {
            return prop.asU32() orelse 2;
        }
        return 2; // Default
    }

    /// Get #size-cells
    pub fn getSizeCells(self: *const Node) u32 {
        if (self.getProperty("#size-cells")) |prop| {
            return prop.asU32() orelse 1;
        }
        return 1; // Default
    }

    /// Check if node is compatible with string
    pub fn isCompatible(self: *const Node, allocator: std.mem.Allocator, compat: []const u8) !bool {
        const compat_list = try self.getCompatible(allocator) orelse return false;
        defer allocator.free(compat_list);

        for (compat_list) |c| {
            if (std.mem.eql(u8, c, compat)) {
                return true;
            }
        }
        return false;
    }
};

/// Device Tree Parser
pub const DeviceTree = struct {
    header: FdtHeader,
    data: []const u8,
    root: *Node,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !*DeviceTree {
        const header = try FdtHeader.fromBytes(data);

        if (!header.validate()) {
            return error.InvalidDeviceTree;
        }

        if (data.len < header.totalsize) {
            return error.TruncatedDeviceTree;
        }

        var dt = try allocator.create(DeviceTree);
        dt.* = .{
            .header = header,
            .data = data,
            .root = try Node.init(allocator, ""),
            .allocator = allocator,
        };

        try dt.parseStructure();

        return dt;
    }

    pub fn deinit(self: *DeviceTree) void {
        self.root.deinit();
        self.allocator.destroy(self.root);
        self.allocator.destroy(self);
    }

    fn parseStructure(self: *DeviceTree) !void {
        const struct_block = self.data[self.header.off_dt_struct..];
        var offset: usize = 0;
        var current_node = self.root;

        while (offset < self.header.size_dt_struct) {
            const token_val = std.mem.readInt(u32, struct_block[offset..][0..4], .big);
            offset += 4;

            const token = try Token.fromU32(token_val);

            switch (token) {
                .begin_node => {
                    // Read node name (null-terminated)
                    const name_start = offset;
                    const name_end = std.mem.indexOfScalarPos(u8, struct_block, offset, 0) orelse
                        return error.InvalidNodeName;

                    const name = struct_block[name_start..name_end];
                    offset = name_end + 1;

                    // Align to 4-byte boundary
                    offset = std.mem.alignForward(usize, offset, 4);

                    // Create new node
                    if (name.len > 0) {
                        const new_node = try Node.init(self.allocator, name);
                        try current_node.addChild(new_node);
                        current_node = new_node;
                    }
                },
                .end_node => {
                    if (current_node.parent) |parent| {
                        current_node = parent;
                    }
                },
                .prop => {
                    // Read property length and name offset
                    const len = std.mem.readInt(u32, struct_block[offset..][0..4], .big);
                    offset += 4;
                    const nameoff = std.mem.readInt(u32, struct_block[offset..][0..4], .big);
                    offset += 4;

                    // Read property name from strings block
                    const strings_block = self.data[self.header.off_dt_strings..];
                    const name_start = nameoff;
                    const name_end = std.mem.indexOfScalarPos(u8, strings_block, name_start, 0) orelse
                        return error.InvalidPropertyName;
                    const prop_name = strings_block[name_start..name_end];

                    // Read property value
                    const value = struct_block[offset .. offset + len];
                    offset += len;

                    // Align to 4-byte boundary
                    offset = std.mem.alignForward(usize, offset, 4);

                    // Add property to current node
                    try current_node.addProperty(prop_name, value);
                },
                .nop => {
                    // Skip NOP
                },
                .end => {
                    // End of structure block
                    break;
                },
            }
        }
    }

    /// Get memory reservations
    pub fn getMemoryReservations(self: *DeviceTree, allocator: std.mem.Allocator) ![]MemReserveEntry {
        var reservations = std.ArrayList(MemReserveEntry){};

        var offset = self.header.off_mem_rsvmap;
        while (offset + @sizeOf(MemReserveEntry) <= self.data.len) {
            const entry = MemReserveEntry.fromBytes(self.data[offset..]);
            if (entry.isEmpty()) break;

            try reservations.append(allocator, entry);
            offset += @sizeOf(MemReserveEntry);
        }

        return reservations.toOwnedSlice(allocator);
    }

    /// Find node by path
    pub fn findNode(self: *DeviceTree, path: []const u8) ?*Node {
        if (path.len == 0 or path[0] != '/') return null;

        if (std.mem.eql(u8, path, "/")) {
            return self.root;
        }

        var current = self.root;
        var it = std.mem.tokenizeScalar(u8, path[1..], '/');

        while (it.next()) |name| {
            current = current.findChild(name) orelse return null;
        }

        return current;
    }
};

test "FDT header parsing" {
    const testing = std.testing;

    // Create minimal valid header
    var header_bytes: [@sizeOf(FdtHeader)]u8 = undefined;
    std.mem.writeInt(u32, header_bytes[0..4], MAGIC, .big);
    std.mem.writeInt(u32, header_bytes[4..8], 256, .big); // totalsize
    std.mem.writeInt(u32, header_bytes[8..12], 40, .big); // off_dt_struct

    const header = try FdtHeader.fromBytes(&header_bytes);
    try testing.expectEqual(MAGIC, header.magic);
    try testing.expectEqual(@as(u32, 256), header.totalsize);
}

test "memory reservation entry" {
    const testing = std.testing;

    var entry_bytes: [@sizeOf(MemReserveEntry)]u8 = undefined;
    std.mem.writeInt(u64, entry_bytes[0..8], 0x1000, .big);
    std.mem.writeInt(u64, entry_bytes[8..16], 0x1000, .big);

    const entry = MemReserveEntry.fromBytes(&entry_bytes);
    try testing.expectEqual(@as(u64, 0x1000), entry.address);
    try testing.expectEqual(@as(u64, 0x1000), entry.size);
    try testing.expect(!entry.isEmpty());
}

test "device tree node" {
    const testing = std.testing;

    var node = try Node.init(testing.allocator, "test@0");
    defer {
        node.deinit();
        testing.allocator.destroy(node);
    }

    try testing.expectEqualStrings("test", node.name);
    try testing.expectEqualStrings("0", node.unit_address.?);

    // Add property
    const value = [_]u8{ 0x00, 0x00, 0x00, 0x01 };
    try node.addProperty("test-prop", &value);

    const prop = node.getProperty("test-prop").?;
    try testing.expectEqual(@as(u32, 1), prop.asU32().?);
}

test "property conversions" {
    const testing = std.testing;

    // U32
    const u32_value = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const prop_u32 = Property{ .name = "u32", .value = &u32_value };
    try testing.expectEqual(@as(u32, 0x12345678), prop_u32.asU32().?);

    // String
    const str_value = "hello\x00";
    const prop_str = Property{ .name = "str", .value = str_value };
    try testing.expectEqualStrings("hello", prop_str.asString().?);
}
