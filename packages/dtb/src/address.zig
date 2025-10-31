// Device Tree Address Translation
// Address mapping and translation between different address spaces

const std = @import("std");
const dtb = @import("dtb.zig");

/// Address range
pub const AddressRange = struct {
    child_address: u64,
    parent_address: u64,
    size: u64,

    pub fn contains(self: AddressRange, addr: u64) bool {
        return addr >= self.child_address and addr < self.child_address + self.size;
    }

    pub fn translate(self: AddressRange, addr: u64) ?u64 {
        if (!self.contains(addr)) return null;
        const offset = addr - self.child_address;
        return self.parent_address + offset;
    }
};

/// Parse reg property
pub fn parseReg(node: *const dtb.Node, allocator: std.mem.Allocator) ![]AddressRange {
    const reg_prop = node.getProperty("reg") orelse return error.NoRegProperty;

    // Get address and size cells from parent
    const parent = node.parent orelse return error.NoParent;
    const address_cells = parent.getAddressCells();
    const size_cells = parent.getSizeCells();

    const cell_size = 4; // Each cell is 4 bytes
    const entry_size = (address_cells + size_cells) * cell_size;

    if (reg_prop.value.len % entry_size != 0) {
        return error.InvalidRegSize;
    }

    const num_entries = reg_prop.value.len / entry_size;
    var ranges = try allocator.alloc(AddressRange, num_entries);

    var offset: usize = 0;
    for (0..num_entries) |i| {
        // Read address
        var address: u64 = 0;
        for (0..address_cells) |_| {
            address = (address << 32) | std.mem.readInt(u32, reg_prop.value[offset..][0..4], .big);
            offset += 4;
        }

        // Read size
        var size: u64 = 0;
        for (0..size_cells) |_| {
            size = (size << 32) | std.mem.readInt(u32, reg_prop.value[offset..][0..4], .big);
            offset += 4;
        }

        ranges[i] = AddressRange{
            .child_address = address,
            .parent_address = address, // Same space initially
            .size = size,
        };
    }

    return ranges;
}

/// Parse ranges property for address translation
pub fn parseRanges(node: *const dtb.Node, allocator: std.mem.Allocator) ![]AddressRange {
    const ranges_prop = node.getProperty("ranges") orelse return error.NoRangesProperty;

    const child_address_cells = node.getAddressCells();
    const address_cells = node.getAddressCells(); // Parent address cells
    const size_cells = node.getSizeCells();

    const cell_size = 4;
    const entry_size = (child_address_cells + address_cells + size_cells) * cell_size;

    // Empty ranges means 1:1 mapping
    if (ranges_prop.value.len == 0) {
        return &[_]AddressRange{};
    }

    if (ranges_prop.value.len % entry_size != 0) {
        return error.InvalidRangesSize;
    }

    const num_entries = ranges_prop.value.len / entry_size;
    var ranges = try allocator.alloc(AddressRange, num_entries);

    var offset: usize = 0;
    for (0..num_entries) |i| {
        // Read child address
        var child_addr: u64 = 0;
        for (0..child_address_cells) |_| {
            child_addr = (child_addr << 32) | std.mem.readInt(u32, ranges_prop.value[offset..][0..4], .big);
            offset += 4;
        }

        // Read parent address
        var parent_addr: u64 = 0;
        for (0..address_cells) |_| {
            parent_addr = (parent_addr << 32) | std.mem.readInt(u32, ranges_prop.value[offset..][0..4], .big);
            offset += 4;
        }

        // Read size
        var size: u64 = 0;
        for (0..size_cells) |_| {
            size = (size << 32) | std.mem.readInt(u32, ranges_prop.value[offset..][0..4], .big);
            offset += 4;
        }

        ranges[i] = AddressRange{
            .child_address = child_addr,
            .parent_address = parent_addr,
            .size = size,
        };
    }

    return ranges;
}

/// Translate address from child to parent address space
pub fn translateAddress(node: *const dtb.Node, address: u64, allocator: std.mem.Allocator) !u64 {
    var current_addr = address;
    var current_node = node.parent;

    while (current_node) |parent_node| {
        // Check if parent has ranges property
        const ranges = parseRanges(parent_node, allocator) catch |err| {
            if (err == error.NoRangesProperty) {
                // No ranges means addresses pass through unchanged
                current_node = parent_node.parent;
                continue;
            }
            return err;
        };
        defer allocator.free(ranges);

        // Find matching range
        var translated = false;
        for (ranges) |range| {
            if (range.translate(current_addr)) |new_addr| {
                current_addr = new_addr;
                translated = true;
                break;
            }
        }

        if (!translated and ranges.len > 0) {
            return error.AddressNotInRange;
        }

        current_node = parent_node.parent;
    }

    return current_addr;
}

/// Get physical address of device
pub fn getPhysicalAddress(node: *const dtb.Node, allocator: std.mem.Allocator, index: usize) !u64 {
    const reg_ranges = try parseReg(node, allocator);
    defer allocator.free(reg_ranges);

    if (index >= reg_ranges.len) {
        return error.IndexOutOfBounds;
    }

    const device_addr = reg_ranges[index].child_address;
    return try translateAddress(node, device_addr, allocator);
}

/// Memory node helper
pub const Memory = struct {
    address: u64,
    size: u64,

    pub fn fromNode(node: *const dtb.Node, allocator: std.mem.Allocator) ![]Memory {
        const reg_ranges = try parseReg(node, allocator);
        defer allocator.free(reg_ranges);

        var memory = try allocator.alloc(Memory, reg_ranges.len);

        for (reg_ranges, 0..) |range, i| {
            memory[i] = Memory{
                .address = range.child_address,
                .size = range.size,
            };
        }

        return memory;
    }
};

/// Interrupt specifier
pub const InterruptSpecifier = struct {
    interrupt_controller: *const dtb.Node,
    cells: []const u32,

    pub fn deinit(self: *InterruptSpecifier, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }
};

/// Parse interrupts property
pub fn parseInterrupts(node: *const dtb.Node, allocator: std.mem.Allocator) ![]InterruptSpecifier {
    const interrupts_prop = node.getProperty("interrupts") orelse return error.NoInterruptsProperty;

    // Find interrupt parent
    const int_parent = findInterruptParent(node) orelse return error.NoInterruptParent;

    // Get #interrupt-cells from parent
    const int_cells_prop = int_parent.getProperty("#interrupt-cells") orelse return error.NoInterruptCells;
    const int_cells = int_cells_prop.asU32() orelse return error.InvalidInterruptCells;

    const cell_size = 4;
    const entry_size = int_cells * cell_size;

    if (interrupts_prop.value.len % entry_size != 0) {
        return error.InvalidInterruptsSize;
    }

    const num_interrupts = interrupts_prop.value.len / entry_size;
    var interrupts = try allocator.alloc(InterruptSpecifier, num_interrupts);

    var offset: usize = 0;
    for (0..num_interrupts) |i| {
        var cells = try allocator.alloc(u32, int_cells);

        for (0..int_cells) |j| {
            cells[j] = std.mem.readInt(u32, interrupts_prop.value[offset..][0..4], .big);
            offset += 4;
        }

        interrupts[i] = InterruptSpecifier{
            .interrupt_controller = int_parent,
            .cells = cells,
        };
    }

    return interrupts;
}

/// Find interrupt parent node
fn findInterruptParent(node: *const dtb.Node) ?*const dtb.Node {
    // Check for interrupt-parent property
    if (node.getProperty("interrupt-parent")) |prop| {
        _ = prop; // Would need to resolve phandle
        // For now, search upward for interrupt-controller
    }

    // Search upward for interrupt-controller
    var current = node.parent;
    while (current) |parent_node| {
        if (parent_node.getProperty("interrupt-controller")) |_| {
            return parent_node;
        }
        current = parent_node.parent;
    }

    return null;
}

test "address range" {
    const testing = std.testing;

    const range = AddressRange{
        .child_address = 0x1000,
        .parent_address = 0x10000,
        .size = 0x1000,
    };

    try testing.expect(range.contains(0x1000));
    try testing.expect(range.contains(0x1FFF));
    try testing.expect(!range.contains(0x2000));

    try testing.expectEqual(@as(u64, 0x10500), range.translate(0x1500).?);
    try testing.expectEqual(@as(?u64, null), range.translate(0x3000));
}

test "parse reg property" {
    const testing = std.testing;

    var root = try dtb.Node.init(testing.allocator, "");
    defer {
        root.deinit();
        testing.allocator.destroy(root);
    }

    var node = try dtb.Node.init(testing.allocator, "device@1000");
    // Note: node will be freed by root.deinit() since it's a child
    try root.addChild(node);

    // Set #address-cells and #size-cells on parent
    const addr_cells = [_]u8{ 0x00, 0x00, 0x00, 0x01 };
    try root.addProperty("#address-cells", &addr_cells);

    const size_cells = [_]u8{ 0x00, 0x00, 0x00, 0x01 };
    try root.addProperty("#size-cells", &size_cells);

    // Add reg property: address=0x1000, size=0x1000
    const reg = [_]u8{
        0x00, 0x00, 0x10, 0x00, // address
        0x00, 0x00, 0x10, 0x00, // size
    };
    try node.addProperty("reg", &reg);

    const ranges = try parseReg(node, testing.allocator);
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(u64, 0x1000), ranges[0].child_address);
    try testing.expectEqual(@as(u64, 0x1000), ranges[0].size);
}
