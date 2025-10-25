// Home Programming Language - Capability-Based Security System
// Fine-grained access control for kernel objects

const Basics = @import("basics");

// ============================================================================
// Core Capability Types
// ============================================================================

/// Capability represents a transferable, unforgeable token of authority
/// that grants specific permissions on a kernel object.
pub fn Capability(comptime Resource: type, comptime Permissions: type) type {
    return struct {
        const Self = @This();

        resource: *Resource,
        permissions: Permissions,
        generation: u64, // Prevents use-after-free
        revoked: bool,

        pub fn init(resource: *Resource, permissions: Permissions) Self {
            return .{
                .resource = resource,
                .permissions = permissions,
                .generation = resource.getGeneration(),
                .revoked = false,
            };
        }

        pub fn hasPermission(self: *const Self, permission: Permissions) bool {
            return !self.revoked and self.permissions.contains(permission);
        }

        pub fn checkValid(self: *const Self) !void {
            if (self.revoked) return error.CapabilityRevoked;
            if (self.generation != self.resource.getGeneration()) {
                return error.CapabilityInvalidated;
            }
        }

        pub fn revoke(self: *Self) void {
            self.revoked = true;
        }

        pub fn derive(self: *const Self, new_permissions: Permissions) !Self {
            try self.checkValid();

            // Can only derive capabilities with subset of permissions
            if (!self.permissions.contains(new_permissions)) {
                return error.InsufficientPermissions;
            }

            return Self{
                .resource = self.resource,
                .permissions = new_permissions,
                .generation = self.generation,
                .revoked = false,
            };
        }
    };
}

// ============================================================================
// Permission Sets
// ============================================================================

pub const FilePermissions = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    append: bool = false,
    delete: bool = false,
    chown: bool = false,
    chmod: bool = false,
    _padding: u1 = 0,

    pub fn contains(self: FilePermissions, other: FilePermissions) bool {
        const self_bits: u8 = @bitCast(self);
        const other_bits: u8 = @bitCast(other);
        return (self_bits & other_bits) == other_bits;
    }

    pub fn readOnly() FilePermissions {
        return .{ .read = true };
    }

    pub fn readWrite() FilePermissions {
        return .{ .read = true, .write = true };
    }

    pub fn full() FilePermissions {
        return .{
            .read = true,
            .write = true,
            .execute = true,
            .append = true,
            .delete = true,
            .chown = true,
            .chmod = true,
        };
    }
};

pub const ProcessPermissions = packed struct(u8) {
    read: bool = false, // Read process info
    signal: bool = false, // Send signals
    kill: bool = false, // Terminate process
    ptrace: bool = false, // Debug process
    setpriority: bool = false, // Change priority
    setaffinity: bool = false, // Set CPU affinity
    _padding: u2 = 0,

    pub fn contains(self: ProcessPermissions, other: ProcessPermissions) bool {
        const self_bits: u8 = @bitCast(self);
        const other_bits: u8 = @bitCast(other);
        return (self_bits & other_bits) == other_bits;
    }

    pub fn readOnly() ProcessPermissions {
        return .{ .read = true };
    }

    pub fn full() ProcessPermissions {
        return .{
            .read = true,
            .signal = true,
            .kill = true,
            .ptrace = true,
            .setpriority = true,
            .setaffinity = true,
        };
    }
};

pub const MemoryPermissions = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    map: bool = false, // Map new memory
    unmap: bool = false, // Unmap memory
    protect: bool = false, // Change protections
    _padding: u2 = 0,

    pub fn contains(self: MemoryPermissions, other: MemoryPermissions) bool {
        const self_bits: u8 = @bitCast(self);
        const other_bits: u8 = @bitCast(other);
        return (self_bits & other_bits) == other_bits;
    }

    pub fn readOnly() MemoryPermissions {
        return .{ .read = true };
    }

    pub fn readWrite() MemoryPermissions {
        return .{ .read = true, .write = true };
    }

    pub fn readExecute() MemoryPermissions {
        return .{ .read = true, .execute = true };
    }

    pub fn full() MemoryPermissions {
        return .{
            .read = true,
            .write = true,
            .execute = true,
            .map = true,
            .unmap = true,
            .protect = true,
        };
    }
};

pub const DevicePermissions = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    ioctl: bool = false,
    mmap: bool = false,
    interrupt: bool = false, // Handle interrupts
    dma: bool = false, // DMA access
    _padding: u2 = 0,

    pub fn contains(self: DevicePermissions, other: DevicePermissions) bool {
        const self_bits: u8 = @bitCast(self);
        const other_bits: u8 = @bitCast(other);
        return (self_bits & other_bits) == other_bits;
    }

    pub fn readOnly() DevicePermissions {
        return .{ .read = true };
    }

    pub fn full() DevicePermissions {
        return .{
            .read = true,
            .write = true,
            .ioctl = true,
            .mmap = true,
            .interrupt = true,
            .dma = true,
        };
    }
};

// ============================================================================
// Kernel Object Traits
// ============================================================================

/// Objects that can be protected by capabilities must implement this interface
pub fn CapableResource(comptime T: type) type {
    return struct {
        pub fn getGeneration(self: *const T) u64 {
            return self.generation;
        }

        pub fn incrementGeneration(self: *T) void {
            self.generation +%= 1;
        }
    };
}

// ============================================================================
// Capability Tables
// ============================================================================

pub const CapabilitySlot = union(enum) {
    Empty,
    File: Capability(*FileResource, FilePermissions),
    Process: Capability(*ProcessResource, ProcessPermissions),
    Memory: Capability(*MemoryResource, MemoryPermissions),
    Device: Capability(*DeviceResource, DevicePermissions),

    pub fn isEmpty(self: CapabilitySlot) bool {
        return self == .Empty;
    }

    pub fn revoke(self: *CapabilitySlot) void {
        switch (self.*) {
            .Empty => {},
            inline else => |*cap| cap.revoke(),
        }
    }
};

pub const CapabilityTable = struct {
    slots: []CapabilitySlot,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, size: usize) !*CapabilityTable {
        const table = try allocator.create(CapabilityTable);
        errdefer allocator.destroy(table);

        const slots = try allocator.alloc(CapabilitySlot, size);
        @memset(slots, .Empty);

        table.* = .{
            .slots = slots,
            .allocator = allocator,
        };

        return table;
    }

    pub fn deinit(self: *CapabilityTable) void {
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    pub fn allocateSlot(self: *CapabilityTable) !usize {
        for (self.slots, 0..) |slot, i| {
            if (slot.isEmpty()) {
                return i;
            }
        }
        return error.CapabilityTableFull;
    }

    pub fn insertFile(self: *CapabilityTable, resource: *FileResource, permissions: FilePermissions) !usize {
        const slot = try self.allocateSlot();
        self.slots[slot] = .{ .File = Capability(*FileResource, FilePermissions).init(resource, permissions) };
        return slot;
    }

    pub fn insertProcess(self: *CapabilityTable, resource: *ProcessResource, permissions: ProcessPermissions) !usize {
        const slot = try self.allocateSlot();
        self.slots[slot] = .{ .Process = Capability(*ProcessResource, ProcessPermissions).init(resource, permissions) };
        return slot;
    }

    pub fn insertMemory(self: *CapabilityTable, resource: *MemoryResource, permissions: MemoryPermissions) !usize {
        const slot = try self.allocateSlot();
        self.slots[slot] = .{ .Memory = Capability(*MemoryResource, MemoryPermissions).init(resource, permissions) };
        return slot;
    }

    pub fn insertDevice(self: *CapabilityTable, resource: *DeviceResource, permissions: DevicePermissions) !usize {
        const slot = try self.allocateSlot();
        self.slots[slot] = .{ .Device = Capability(*DeviceResource, DevicePermissions).init(resource, permissions) };
        return slot;
    }

    pub fn get(self: *CapabilityTable, index: usize) !*CapabilitySlot {
        if (index >= self.slots.len) return error.InvalidCapabilityIndex;
        if (self.slots[index].isEmpty()) return error.EmptyCapabilitySlot;
        return &self.slots[index];
    }

    pub fn remove(self: *CapabilityTable, index: usize) !void {
        if (index >= self.slots.len) return error.InvalidCapabilityIndex;
        self.slots[index] = .Empty;
    }

    pub fn revokeAll(self: *CapabilityTable) void {
        for (self.slots) |*slot| {
            slot.revoke();
        }
    }
};

// ============================================================================
// Example Resource Types
// ============================================================================

pub const FileResource = struct {
    path: []const u8,
    generation: u64,
    allocator: Basics.Allocator,

    pub usingnamespace CapableResource(@This());

    pub fn init(allocator: Basics.Allocator, path: []const u8) !*FileResource {
        const resource = try allocator.create(FileResource);
        resource.* = .{
            .path = try allocator.dupe(u8, path),
            .generation = 0,
            .allocator = allocator,
        };
        return resource;
    }

    pub fn deinit(self: *FileResource) void {
        self.allocator.free(self.path);
        self.incrementGeneration(); // Invalidate all capabilities
        self.allocator.destroy(self);
    }
};

pub const ProcessResource = struct {
    pid: u32,
    generation: u64,

    pub usingnamespace CapableResource(@This());

    pub fn init(pid: u32) ProcessResource {
        return .{
            .pid = pid,
            .generation = 0,
        };
    }
};

pub const MemoryResource = struct {
    base_addr: usize,
    size: usize,
    generation: u64,

    pub usingnamespace CapableResource(@This());

    pub fn init(base_addr: usize, size: usize) MemoryResource {
        return .{
            .base_addr = base_addr,
            .size = size,
            .generation = 0,
        };
    }
};

pub const DeviceResource = struct {
    device_id: u32,
    generation: u64,

    pub usingnamespace CapableResource(@This());

    pub fn init(device_id: u32) DeviceResource {
        return .{
            .device_id = device_id,
            .generation = 0,
        };
    }
};

// ============================================================================
// Capability Operations
// ============================================================================

pub const CapabilityOps = struct {
    /// Transfer a capability from one table to another
    pub fn transfer(from: *CapabilityTable, from_index: usize, to: *CapabilityTable) !usize {
        const cap_slot = try from.get(from_index);
        const to_index = try to.allocateSlot();

        to.slots[to_index] = cap_slot.*;
        try from.remove(from_index);

        return to_index;
    }

    /// Copy a capability (derive with same permissions)
    pub fn copy(from: *CapabilityTable, from_index: usize, to: *CapabilityTable) !usize {
        const cap_slot = try from.get(from_index);
        const to_index = try to.allocateSlot();

        to.slots[to_index] = cap_slot.*;

        return to_index;
    }

    /// Derive a capability with reduced permissions
    pub fn derive(from: *CapabilityTable, from_index: usize, to: *CapabilityTable, new_perms: anytype) !usize {
        const cap_slot = try from.get(from_index);
        const to_index = try to.allocateSlot();

        switch (cap_slot.*) {
            .File => |cap| {
                const derived = try cap.derive(new_perms);
                to.slots[to_index] = .{ .File = derived };
            },
            .Process => |cap| {
                const derived = try cap.derive(new_perms);
                to.slots[to_index] = .{ .Process = derived };
            },
            .Memory => |cap| {
                const derived = try cap.derive(new_perms);
                to.slots[to_index] = .{ .Memory = derived };
            },
            .Device => |cap| {
                const derived = try cap.derive(new_perms);
                to.slots[to_index] = .{ .Device = derived };
            },
            .Empty => return error.EmptyCapabilitySlot,
        }

        return to_index;
    }
};

// ============================================================================
// Compile-Time Permission Checking
// ============================================================================

/// Compile-time verification that a permission is required
pub fn requirePermission(comptime required: anytype) void {
    @compileLog("Required permission:", required);
}

/// Compile-time permission enforcement
pub fn enforcePermissions(comptime T: type, comptime permissions: anytype) type {
    return struct {
        capability: Capability(T, @TypeOf(permissions)),

        pub fn init(cap: Capability(T, @TypeOf(permissions))) @This() {
            return .{ .capability = cap };
        }

        pub fn checkPermission(self: *const @This(), perm: @TypeOf(permissions)) !void {
            if (!self.capability.hasPermission(perm)) {
                return error.PermissionDenied;
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "capability permissions" {
    const perms = FilePermissions.readWrite();
    try Basics.testing.expect(perms.read);
    try Basics.testing.expect(perms.write);
    try Basics.testing.expect(!perms.execute);
}

test "permission containment" {
    const full = FilePermissions.full();
    const read_only = FilePermissions.readOnly();

    try Basics.testing.expect(full.contains(read_only));
    try Basics.testing.expect(!read_only.contains(full));
}

test "capability table" {
    const allocator = Basics.testing.allocator;

    const table = try CapabilityTable.init(allocator, 16);
    defer table.deinit();

    var proc = ProcessResource.init(1234);
    const slot = try table.insertProcess(&proc, ProcessPermissions.full());

    try Basics.testing.expectEqual(@as(usize, 0), slot);

    const cap_slot = try table.get(slot);
    try Basics.testing.expect(!cap_slot.isEmpty());
}

test "capability revocation" {
    const allocator = Basics.testing.allocator;

    const table = try CapabilityTable.init(allocator, 16);
    defer table.deinit();

    var proc = ProcessResource.init(1234);
    const slot = try table.insertProcess(&proc, ProcessPermissions.full());

    const cap_slot = try table.get(slot);
    cap_slot.revoke();

    switch (cap_slot.*) {
        .Process => |cap| {
            try Basics.testing.expect(cap.revoked);
        },
        else => unreachable,
    }
}

test "capability derivation" {
    const allocator = Basics.testing.allocator;

    var proc = ProcessResource.init(1234);
    const full_cap = Capability(*ProcessResource, ProcessPermissions).init(&proc, ProcessPermissions.full());

    const read_only = try full_cap.derive(ProcessPermissions.readOnly());
    try Basics.testing.expect(read_only.hasPermission(ProcessPermissions.readOnly()));
    try Basics.testing.expect(!read_only.hasPermission(ProcessPermissions.full()));
}
