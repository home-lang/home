// Home Programming Language - Global Type Registry
// Shared type information across compilation units for cross-module type resolution

const std = @import("std");

/// Simple spinlock mutex (std.Thread.Mutex removed in Zig 0.16)
const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

// Forward declare the types - they are actually defined in native_codegen.zig
// and we import them to avoid duplication
const native_codegen = @import("native_codegen.zig");
pub const EnumVariantInfo = native_codegen.EnumVariantInfo;
pub const EnumLayout = native_codegen.EnumLayout;
pub const FieldInfo = native_codegen.FieldInfo;
pub const StructLayout = native_codegen.StructLayout;

/// Global type registry for sharing type information across modules.
/// This is a singleton that persists across all compilation units.
pub const TypeRegistry = struct {
    allocator: std.mem.Allocator,
    /// Map of enum names to their layouts
    enum_layouts: std.StringHashMap(EnumLayout),
    /// Map of struct names to their layouts
    struct_layouts: std.StringHashMap(StructLayout),
    /// Mutex for thread-safe access (future-proofing for parallel compilation)
    mutex: SpinMutex,

    pub fn init(allocator: std.mem.Allocator) TypeRegistry {
        return .{
            .allocator = allocator,
            .enum_layouts = std.StringHashMap(EnumLayout).init(allocator),
            .struct_layouts = std.StringHashMap(StructLayout).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *TypeRegistry) void {
        // Free enum layouts
        {
            var iter = self.enum_layouts.iterator();
            while (iter.next()) |entry| {
                const layout = entry.value_ptr.*;
                self.allocator.free(layout.name);
                for (layout.variants) |variant| {
                    self.allocator.free(variant.name);
                    if (variant.data_type) |dt| {
                        self.allocator.free(dt);
                    }
                }
                self.allocator.free(layout.variants);
            }
            self.enum_layouts.deinit();
        }

        // Free struct layouts
        {
            var iter = self.struct_layouts.iterator();
            while (iter.next()) |entry| {
                const layout = entry.value_ptr.*;
                self.allocator.free(layout.name);
                for (layout.fields) |field| {
                    self.allocator.free(field.name);
                    if (field.type_name.len > 0) {
                        self.allocator.free(field.type_name);
                    }
                }
                self.allocator.free(layout.fields);
            }
            self.struct_layouts.deinit();
        }
    }

    /// Register an enum layout in the global registry
    pub fn registerEnum(self: *TypeRegistry, layout: EnumLayout) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already registered
        if (self.enum_layouts.contains(layout.name)) {
            return; // Already registered, skip
        }

        // Deep copy the layout
        const name_copy = try self.allocator.dupe(u8, layout.name);
        errdefer self.allocator.free(name_copy);

        var variants = try self.allocator.alloc(EnumVariantInfo, layout.variants.len);
        errdefer self.allocator.free(variants);

        var num_initialized: usize = 0;
        errdefer {
            for (variants[0..num_initialized]) |v| {
                self.allocator.free(v.name);
                if (v.data_type) |dt| self.allocator.free(dt);
            }
        }

        for (layout.variants, 0..) |variant, i| {
            const variant_name = try self.allocator.dupe(u8, variant.name);
            const variant_data_type = if (variant.data_type) |dt|
                try self.allocator.dupe(u8, dt)
            else
                null;

            variants[i] = .{
                .name = variant_name,
                .data_type = variant_data_type,
            };
            num_initialized += 1;
        }

        const global_layout = EnumLayout{
            .name = name_copy,
            .variants = variants,
        };

        try self.enum_layouts.put(name_copy, global_layout);
    }

    /// Register a struct layout in the global registry
    pub fn registerStruct(self: *TypeRegistry, layout: StructLayout) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already registered
        if (self.struct_layouts.contains(layout.name)) {
            return; // Already registered, skip
        }

        // Deep copy the layout
        const name_copy = try self.allocator.dupe(u8, layout.name);
        errdefer self.allocator.free(name_copy);

        var fields = try self.allocator.alloc(FieldInfo, layout.fields.len);
        errdefer self.allocator.free(fields);

        var num_initialized: usize = 0;
        errdefer {
            for (fields[0..num_initialized]) |f| {
                self.allocator.free(f.name);
                if (f.type_name.len > 0) self.allocator.free(f.type_name);
            }
        }

        for (layout.fields, 0..) |field, i| {
            const field_name = try self.allocator.dupe(u8, field.name);
            const field_type_name = if (field.type_name.len > 0)
                try self.allocator.dupe(u8, field.type_name)
            else
                "";

            fields[i] = .{
                .name = field_name,
                .offset = field.offset,
                .size = field.size,
                .type_name = field_type_name,
            };
            num_initialized += 1;
        }

        const global_layout = StructLayout{
            .name = name_copy,
            .fields = fields,
            .total_size = layout.total_size,
        };

        try self.struct_layouts.put(name_copy, global_layout);
    }

    /// Look up an enum layout by name
    pub fn getEnum(self: *TypeRegistry, name: []const u8) ?EnumLayout {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.enum_layouts.get(name);
    }

    /// Look up a struct layout by name
    pub fn getStruct(self: *TypeRegistry, name: []const u8) ?StructLayout {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.struct_layouts.get(name);
    }

    /// Check if an enum is registered
    pub fn hasEnum(self: *TypeRegistry, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.enum_layouts.contains(name);
    }

    /// Check if a struct is registered
    pub fn hasStruct(self: *TypeRegistry, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.struct_layouts.contains(name);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TypeRegistry - register and lookup enum" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = TypeRegistry.init(allocator);
    defer registry.deinit();

    // Create an enum layout
    var variants = [_]EnumVariantInfo{
        .{ .name = "None", .data_type = null },
        .{ .name = "Some", .data_type = "i64" },
    };

    const layout = EnumLayout{
        .name = "Option",
        .variants = &variants,
    };

    // Register it
    try registry.registerEnum(layout);

    // Look it up
    const retrieved = registry.getEnum("Option");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("Option", retrieved.?.name);
    try testing.expectEqual(@as(usize, 2), retrieved.?.variants.len);
    try testing.expectEqualStrings("None", retrieved.?.variants[0].name);
    try testing.expectEqualStrings("Some", retrieved.?.variants[1].name);
}

test "TypeRegistry - register and lookup struct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = TypeRegistry.init(allocator);
    defer registry.deinit();

    // Create a struct layout
    var fields = [_]FieldInfo{
        .{ .name = "x", .offset = 0, .size = 8, .type_name = "i64" },
        .{ .name = "y", .offset = 8, .size = 8, .type_name = "i64" },
    };

    const layout = StructLayout{
        .name = "Point",
        .fields = &fields,
        .total_size = 16,
    };

    // Register it
    try registry.registerStruct(layout);

    // Look it up
    const retrieved = registry.getStruct("Point");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("Point", retrieved.?.name);
    try testing.expectEqual(@as(usize, 2), retrieved.?.fields.len);
    try testing.expectEqual(@as(usize, 16), retrieved.?.total_size);
}
