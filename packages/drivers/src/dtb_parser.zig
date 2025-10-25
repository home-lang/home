// Home Programming Language - Device Tree Blob (DTB) Parser
// For Raspberry Pi and other ARM systems

const Basics = @import("basics");

// ============================================================================
// DTB Header
// ============================================================================

pub const DTBHeader = extern struct {
    magic: u32, // 0xd00dfeed (big endian)
    totalsize: u32, // Total size in bytes
    off_dt_struct: u32, // Offset to structure block
    off_dt_strings: u32, // Offset to strings block
    off_mem_rsvmap: u32, // Offset to memory reserve map
    version: u32, // Version
    last_comp_version: u32, // Last compatible version
    boot_cpuid_phys: u32, // Physical CPU ID of boot CPU
    size_dt_strings: u32, // Size of strings block
    size_dt_struct: u32, // Size of structure block
};

// Magic value (big endian)
pub const DTB_MAGIC = 0xD00DFEED;
pub const DTB_VERSION = 17;

// ============================================================================
// DTB Tokens
// ============================================================================

pub const DTBToken = enum(u32) {
    BeginNode = 0x00000001,
    EndNode = 0x00000002,
    Prop = 0x00000003,
    Nop = 0x00000004,
    End = 0x00000009,
};

// ============================================================================
// Memory Reservation Entry
// ============================================================================

pub const MemReserveEntry = extern struct {
    address: u64,
    size: u64,
};

// ============================================================================
// DTB Node
// ============================================================================

pub const DTBNode = struct {
    name: []const u8,
    properties: []DTBProperty,
    children: []DTBNode,
    parent: ?*DTBNode,

    pub fn findProperty(self: *const DTBNode, name: []const u8) ?*const DTBProperty {
        for (self.properties) |*prop| {
            if (Basics.mem.eql(u8, prop.name, name)) {
                return prop;
            }
        }
        return null;
    }

    pub fn findChild(self: *const DTBNode, name: []const u8) ?*const DTBNode {
        for (self.children) |*child| {
            if (Basics.mem.eql(u8, child.name, name)) {
                return child;
            }
        }
        return null;
    }

    pub fn getU32Property(self: *const DTBNode, name: []const u8) ?u32 {
        const prop = self.findProperty(name) orelse return null;
        return prop.getU32();
    }

    pub fn getU64Property(self: *const DTBNode, name: []const u8) ?u64 {
        const prop = self.findProperty(name) orelse return null;
        return prop.getU64();
    }

    pub fn getStringProperty(self: *const DTBNode, name: []const u8) ?[]const u8 {
        const prop = self.findProperty(name) orelse return null;
        return prop.getString();
    }
};

// ============================================================================
// DTB Property
// ============================================================================

pub const DTBProperty = struct {
    name: []const u8,
    value: []const u8,

    pub fn getU32(self: *const DTBProperty) ?u32 {
        if (self.value.len < 4) return null;
        return bigEndianToHost(u32, self.value[0..4]);
    }

    pub fn getU64(self: *const DTBProperty) ?u64 {
        if (self.value.len < 8) return null;
        return bigEndianToHost(u64, self.value[0..8]);
    }

    pub fn getString(self: *const DTBProperty) ?[]const u8 {
        // Find null terminator
        for (self.value, 0..) |byte, i| {
            if (byte == 0) {
                return self.value[0..i];
            }
        }
        return self.value;
    }

    pub fn getU32Array(self: *const DTBProperty) []const u32 {
        const count = self.value.len / 4;
        var result: []u32 = undefined;
        result.len = count;
        result.ptr = @ptrCast(@alignCast(self.value.ptr));

        // Convert from big endian
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const bytes = self.value[i * 4 .. (i + 1) * 4];
            result[i] = bigEndianToHost(u32, bytes[0..4]);
        }

        return result;
    }

    pub fn getU64Array(self: *const DTBProperty) []const u64 {
        const count = self.value.len / 8;
        var result: []u64 = undefined;
        result.len = count;
        result.ptr = @ptrCast(@alignCast(self.value.ptr));

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const bytes = self.value[i * 8 .. (i + 1) * 8];
            result[i] = bigEndianToHost(u64, bytes[0..8]);
        }

        return result;
    }

    pub fn isCompatible(self: *const DTBProperty, compat: []const u8) bool {
        // Compatible property can be multiple null-terminated strings
        var offset: usize = 0;
        while (offset < self.value.len) {
            const remaining = self.value[offset..];

            // Find next null terminator
            var end = offset;
            while (end < self.value.len and self.value[end] != 0) {
                end += 1;
            }

            const str = self.value[offset..end];
            if (Basics.mem.eql(u8, str, compat)) {
                return true;
            }

            offset = end + 1;
        }
        return false;
    }
};

// ============================================================================
// DTB Parser
// ============================================================================

pub const DTBParser = struct {
    data: []const u8,
    header: *const DTBHeader,
    strings: []const u8,
    allocator: Basics.mem.Allocator,

    pub fn init(dtb_addr: u64, allocator: Basics.mem.Allocator) !DTBParser {
        const header: *const DTBHeader = @ptrFromInt(dtb_addr);

        // Verify magic
        const magic = bigEndianToHost(u32, @as(*const [4]u8, @ptrCast(&header.magic)));
        if (magic != DTB_MAGIC) {
            return error.InvalidDTBMagic;
        }

        const totalsize = bigEndianToHost(u32, @as(*const [4]u8, @ptrCast(&header.totalsize)));
        const data: [*]const u8 = @ptrFromInt(dtb_addr);

        const off_dt_strings = bigEndianToHost(u32, @as(*const [4]u8, @ptrCast(&header.off_dt_strings)));
        const size_dt_strings = bigEndianToHost(u32, @as(*const [4]u8, @ptrCast(&header.size_dt_strings)));

        return .{
            .data = data[0..totalsize],
            .header = header,
            .strings = data[off_dt_strings .. off_dt_strings + size_dt_strings],
            .allocator = allocator,
        };
    }

    pub fn getMemoryReservations(self: *const DTBParser) []const MemReserveEntry {
        const off_mem_rsvmap = bigEndianToHost(u32, @as(*const [4]u8, @ptrCast(&self.header.off_mem_rsvmap)));
        const entries: [*]const MemReserveEntry = @ptrCast(@alignCast(&self.data[off_mem_rsvmap]));

        // Count entries until we find the null entry
        var count: usize = 0;
        while (true) {
            const addr = bigEndianToHost(u64, @as(*const [8]u8, @ptrCast(&entries[count].address)));
            const size = bigEndianToHost(u64, @as(*const [8]u8, @ptrCast(&entries[count].size)));

            if (addr == 0 and size == 0) break;
            count += 1;
        }

        return entries[0..count];
    }

    pub fn parseRoot(self: *DTBParser) !DTBNode {
        const off_dt_struct = bigEndianToHost(u32, @as(*const [4]u8, @ptrCast(&self.header.off_dt_struct)));
        var offset = off_dt_struct;

        return try self.parseNode(&offset, null);
    }

    fn parseNode(self: *DTBParser, offset: *u32, parent: ?*DTBNode) !DTBNode {
        // Expect BeginNode token
        const token = self.readU32(offset);
        if (token != @intFromEnum(DTBToken.BeginNode)) {
            return error.ExpectedBeginNode;
        }

        // Read node name
        const name = self.readString(offset);

        // Align to 4 bytes
        offset.* = alignForward(offset.*, 4);

        var properties = Basics.ArrayList(DTBProperty).init(self.allocator);
        var children = Basics.ArrayList(DTBNode).init(self.allocator);

        // Parse properties and child nodes
        while (true) {
            const next_token = self.readU32(offset);

            if (next_token == @intFromEnum(DTBToken.Prop)) {
                const prop = try self.parseProperty(offset);
                try properties.append(prop);
            } else if (next_token == @intFromEnum(DTBToken.BeginNode)) {
                // Rewind to re-read BeginNode in parseNode
                offset.* -= 4;
                var node = DTBNode{
                    .name = name,
                    .properties = try properties.toOwnedSlice(),
                    .children = &[_]DTBNode{},
                    .parent = parent,
                };
                const child = try self.parseNode(offset, &node);
                try children.append(child);
            } else if (next_token == @intFromEnum(DTBToken.EndNode)) {
                break;
            } else if (next_token == @intFromEnum(DTBToken.Nop)) {
                continue;
            } else {
                return error.UnexpectedToken;
            }
        }

        return DTBNode{
            .name = name,
            .properties = try properties.toOwnedSlice(),
            .children = try children.toOwnedSlice(),
            .parent = parent,
        };
    }

    fn parseProperty(self: *DTBParser, offset: *u32) !DTBProperty {
        const len = self.readU32(offset);
        const nameoff = self.readU32(offset);

        const name = self.getString(nameoff);
        const value = self.data[offset.* .. offset.* + len];
        offset.* += len;

        // Align to 4 bytes
        offset.* = alignForward(offset.*, 4);

        return DTBProperty{
            .name = name,
            .value = value,
        };
    }

    fn readU32(self: *const DTBParser, offset: *u32) u32 {
        const value = bigEndianToHost(u32, self.data[offset.* .. offset.* + 4][0..4]);
        offset.* += 4;
        return value;
    }

    fn readString(self: *const DTBParser, offset: *u32) []const u8 {
        const start = offset.*;
        while (self.data[offset.*] != 0) {
            offset.* += 1;
        }
        const str = self.data[start..offset.*];
        offset.* += 1; // Skip null terminator
        return str;
    }

    fn getString(self: *const DTBParser, nameoff: u32) []const u8 {
        const start = nameoff;
        var end = nameoff;
        while (self.strings[end] != 0) {
            end += 1;
        }
        return self.strings[start..end];
    }

    /// Find node by path (e.g., "/soc/gpio@7e200000")
    pub fn findNodeByPath(self: *DTBParser, root: *const DTBNode, path: []const u8) ?*const DTBNode {
        if (path.len == 0 or path[0] != '/') return null;

        var current = root;
        var offset: usize = 1; // Skip leading '/'

        while (offset < path.len) {
            // Find next '/'
            var end = offset;
            while (end < path.len and path[end] != '/') {
                end += 1;
            }

            const component = path[offset..end];
            current = current.findChild(component) orelse return null;

            offset = end + 1;
        }

        return current;
    }

    /// Find all nodes with a specific compatible string
    pub fn findCompatibleNodes(self: *DTBParser, root: *const DTBNode, compat: []const u8, results: *Basics.ArrayList(*const DTBNode)) !void {
        // Check if this node matches
        if (root.findProperty("compatible")) |prop| {
            if (prop.isCompatible(compat)) {
                try results.append(root);
            }
        }

        // Recursively check children
        for (root.children) |*child| {
            try self.findCompatibleNodes(child, compat, results);
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert big-endian bytes to host endian
fn bigEndianToHost(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    var result: T = 0;
    comptime var i = 0;
    inline while (i < @sizeOf(T)) : (i += 1) {
        result = (result << 8) | bytes[i];
    }
    return result;
}

/// Align value forward to alignment
fn alignForward(value: u32, alignment: u32) u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// Parse reg property (address/size cells)
pub fn parseReg(prop: *const DTBProperty, address_cells: u32, size_cells: u32) ![]const RegEntry {
    const entry_size = (address_cells + size_cells) * 4;
    const count = prop.value.len / entry_size;

    var entries = try Basics.heap.page_allocator.alloc(RegEntry, count);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const base_offset = i * entry_size;

        // Read address
        var address: u64 = 0;
        var j: u32 = 0;
        while (j < address_cells) : (j += 1) {
            const offset = base_offset + j * 4;
            const val = bigEndianToHost(u32, prop.value[offset .. offset + 4][0..4]);
            address = (address << 32) | val;
        }

        // Read size
        var size: u64 = 0;
        j = 0;
        while (j < size_cells) : (j += 1) {
            const offset = base_offset + (address_cells + j) * 4;
            const val = bigEndianToHost(u32, prop.value[offset .. offset + 4][0..4]);
            size = (size << 32) | val;
        }

        entries[i] = .{ .address = address, .size = size };
    }

    return entries;
}

pub const RegEntry = struct {
    address: u64,
    size: u64,
};

// ============================================================================
// Common Device Tree Queries
// ============================================================================

/// Get memory nodes
pub fn getMemoryInfo(parser: *DTBParser, root: *const DTBNode) ![]RegEntry {
    const memory = root.findChild("memory") orelse return error.NoMemoryNode;

    const reg_prop = memory.findProperty("reg") orelse return error.NoRegProperty;

    // Memory nodes typically use #address-cells=2, #size-cells=1 or 2
    const address_cells = root.getU32Property("#address-cells") orelse 2;
    const size_cells = root.getU32Property("#size-cells") orelse 1;

    return parseReg(reg_prop, address_cells, size_cells);
}

/// Get chosen node (bootargs, stdout, etc.)
pub fn getChosenNode(root: *const DTBNode) ?*const DTBNode {
    return root.findChild("chosen");
}

/// Get boot arguments
pub fn getBootArgs(root: *const DTBNode) ?[]const u8 {
    const chosen = getChosenNode(root) orelse return null;
    return chosen.getStringProperty("bootargs");
}

/// Get CPU nodes
pub fn getCPUNodes(parser: *DTBParser, root: *const DTBNode) ![]const *const DTBNode {
    const cpus = root.findChild("cpus") orelse return error.NoCPUsNode;

    var cpu_list = Basics.ArrayList(*const DTBNode).init(parser.allocator);

    for (cpus.children) |*child| {
        if (Basics.mem.startsWith(u8, child.name, "cpu@")) {
            try cpu_list.append(child);
        }
    }

    return cpu_list.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "DTB header size" {
    try Basics.testing.expectEqual(@as(usize, 40), @sizeOf(DTBHeader));
}

test "DTB magic value" {
    try Basics.testing.expectEqual(@as(u32, 0xD00DFEED), DTB_MAGIC);
}

test "Memory reserve entry size" {
    try Basics.testing.expectEqual(@as(usize, 16), @sizeOf(MemReserveEntry));
}

test "Big endian conversion" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const value = bigEndianToHost(u32, &bytes);
    try Basics.testing.expectEqual(@as(u32, 0x12345678), value);
}

test "Align forward" {
    try Basics.testing.expectEqual(@as(u32, 4), alignForward(1, 4));
    try Basics.testing.expectEqual(@as(u32, 8), alignForward(5, 4));
    try Basics.testing.expectEqual(@as(u32, 12), alignForward(12, 4));
}
