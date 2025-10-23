const std = @import("std");
const ast = @import("ast");

/// Trait system for Home (similar to Rust traits / TypeScript interfaces)
/// Provides polymorphism, code reuse, and abstraction
pub const TraitSystem = struct {
    allocator: std.mem.Allocator,
    traits: std.StringHashMap(TraitDef),
    impls: std.ArrayList(TraitImpl),
    vtables: std.StringHashMap(VTable),

    pub const TraitDef = struct {
        name: []const u8,
        methods: []const MethodSignature,
        associated_types: []const AssociatedType,
        super_traits: []const []const u8, // Trait inheritance
        generic_params: []const []const u8,

        pub const MethodSignature = struct {
            name: []const u8,
            params: []const Param,
            return_type: ?[]const u8,
            is_async: bool,
            is_required: bool, // false for default implementations

            pub const Param = struct {
                name: []const u8,
                type_name: []const u8,
            };
        };

        pub const AssociatedType = struct {
            name: []const u8,
            bounds: []const []const u8, // Trait bounds
        };
    };

    pub const TraitImpl = struct {
        trait_name: []const u8,
        for_type: []const u8,
        methods: []const MethodImpl,
        associated_types: std.StringHashMap([]const u8),

        pub const MethodImpl = struct {
            name: []const u8,
            function: *ast.FnDecl,
        };
    };

    /// Virtual table for dynamic dispatch
    pub const VTable = struct {
        trait_name: []const u8,
        type_name: []const u8,
        methods: std.StringHashMap(usize), // Method name -> function pointer offset
        destructor: ?usize,
    };

    pub fn init(allocator: std.mem.Allocator) TraitSystem {
        return .{
            .allocator = allocator,
            .traits = std.StringHashMap(TraitDef).init(allocator),
            .impls = std.ArrayList(TraitImpl).init(allocator),
            .vtables = std.StringHashMap(VTable).init(allocator),
        };
    }

    pub fn deinit(self: *TraitSystem) void {
        self.traits.deinit();
        self.impls.deinit();
        self.vtables.deinit();
    }

    /// Define a new trait
    pub fn defineTrait(
        self: *TraitSystem,
        name: []const u8,
        methods: []const TraitDef.MethodSignature,
        associated_types: []const TraitDef.AssociatedType,
        super_traits: []const []const u8,
        generic_params: []const []const u8,
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const methods_copy = try self.allocator.dupe(TraitDef.MethodSignature, methods);
        errdefer self.allocator.free(methods_copy);

        const associated_types_copy = try self.allocator.dupe(TraitDef.AssociatedType, associated_types);
        errdefer self.allocator.free(associated_types_copy);

        const trait_def = TraitDef{
            .name = name_copy,
            .methods = methods_copy,
            .associated_types = associated_types_copy,
            .super_traits = super_traits,
            .generic_params = generic_params,
        };

        try self.traits.put(trait_def.name, trait_def);
    }

    /// Implement a trait for a type
    pub fn implementTrait(
        self: *TraitSystem,
        trait_name: []const u8,
        for_type: []const u8,
        methods: []const TraitImpl.MethodImpl,
    ) !void {
        // Verify trait exists
        const trait_def = self.traits.get(trait_name) orelse return error.UndefinedTrait;

        // Verify all required methods are implemented
        for (trait_def.methods) |method_sig| {
            if (!method_sig.is_required) continue;

            var found = false;
            for (methods) |impl_method| {
                if (std.mem.eql(u8, impl_method.name, method_sig.name)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                return error.MissingRequiredMethod;
            }
        }

        const trait_name_copy = try self.allocator.dupe(u8, trait_name);
        errdefer self.allocator.free(trait_name_copy);

        const for_type_copy = try self.allocator.dupe(u8, for_type);
        errdefer self.allocator.free(for_type_copy);

        const methods_copy = try self.allocator.dupe(TraitImpl.MethodImpl, methods);
        errdefer self.allocator.free(methods_copy);

        const impl = TraitImpl{
            .trait_name = trait_name_copy,
            .for_type = for_type_copy,
            .methods = methods_copy,
            .associated_types = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.impls.append(impl);

        // Generate vtable for dynamic dispatch
        try self.generateVTable(trait_name, for_type);
    }

    /// Check if a type implements a trait
    pub fn implementsTrait(self: *const TraitSystem, type_name: []const u8, trait_name: []const u8) bool {
        for (self.impls.items) |impl| {
            if (std.mem.eql(u8, impl.for_type, type_name) and
                std.mem.eql(u8, impl.trait_name, trait_name))
            {
                return true;
            }
        }
        return false;
    }

    /// Get trait implementation for a type
    pub fn getImplementation(
        self: *const TraitSystem,
        type_name: []const u8,
        trait_name: []const u8,
    ) ?*const TraitImpl {
        for (self.impls.items) |*impl| {
            if (std.mem.eql(u8, impl.for_type, type_name) and
                std.mem.eql(u8, impl.trait_name, trait_name))
            {
                return impl;
            }
        }
        return null;
    }

    /// Generate vtable for dynamic dispatch
    fn generateVTable(self: *TraitSystem, trait_name: []const u8, type_name: []const u8) !void {
        const impl = self.getImplementation(type_name, trait_name) orelse return error.NoImplementation;

        const trait_name_copy = try self.allocator.dupe(u8, trait_name);
        errdefer self.allocator.free(trait_name_copy);

        const type_name_copy = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(type_name_copy);

        var vtable = VTable{
            .trait_name = trait_name_copy,
            .type_name = type_name_copy,
            .methods = std.StringHashMap(usize).init(self.allocator),
            .destructor = null,
        };
        errdefer vtable.methods.deinit();

        // Build method table
        for (impl.methods, 0..) |method, i| {
            try vtable.methods.put(method.name, i);
        }

        const key = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ type_name, trait_name });
        errdefer self.allocator.free(key);
        try self.vtables.put(key, vtable);
    }

    /// Trait object for dynamic dispatch
    pub const TraitObject = struct {
        data: *anyopaque,
        vtable: *const VTable,

        pub fn call(self: *const TraitObject, method_name: []const u8, args: anytype) !void {
            const offset = self.vtable.methods.get(method_name) orelse return error.MethodNotFound;
            _ = offset;
            _ = args;
            // In real implementation: call function at vtable[offset] with data + args
        }
    };

    /// Create trait object for dynamic dispatch
    pub fn createTraitObject(
        self: *TraitSystem,
        type_name: []const u8,
        trait_name: []const u8,
        data: *anyopaque,
    ) !TraitObject {
        const key = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ type_name, trait_name });
        errdefer self.allocator.free(key);
        defer self.allocator.free(key);

        const vtable = self.vtables.getPtr(key) orelse return error.NoVTable;

        return TraitObject{
            .data = data,
            .vtable = vtable,
        };
    }

    /// Check trait bounds
    pub fn checkBounds(
        self: *const TraitSystem,
        type_name: []const u8,
        bounds: []const []const u8,
    ) bool {
        for (bounds) |trait_name| {
            if (!self.implementsTrait(type_name, trait_name)) {
                return false;
            }
        }
        return true;
    }
};

/// Built-in traits (like Rust's std traits)
pub const BuiltinTraits = struct {
    /// Clone trait - ability to duplicate values
    pub const Clone = struct {
        pub const name = "Clone";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "clone",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "&Self" },
                },
                .return_type = "Self",
                .is_async = false,
                .is_required = true,
            },
        };
    };

    /// Copy trait - bitwise copy (marker trait)
    pub const Copy = struct {
        pub const name = "Copy";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{};
        pub const super_traits = [_][]const u8{"Clone"};
    };

    /// Debug trait - formatted output
    pub const Debug = struct {
        pub const name = "Debug";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "fmt",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "&Self" },
                    .{ .name = "f", .type_name = "&mut Formatter" },
                },
                .return_type = "Result<(), Error>",
                .is_async = false,
                .is_required = true,
            },
        };
    };

    /// Display trait - user-facing output
    pub const Display = struct {
        pub const name = "Display";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "fmt",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "&Self" },
                    .{ .name = "f", .type_name = "&mut Formatter" },
                },
                .return_type = "Result<(), Error>",
                .is_async = false,
                .is_required = true,
            },
        };
    };

    /// PartialEq trait - equality comparison
    pub const PartialEq = struct {
        pub const name = "PartialEq";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "eq",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "&Self" },
                    .{ .name = "other", .type_name = "&Self" },
                },
                .return_type = "bool",
                .is_async = false,
                .is_required = true,
            },
        };
    };

    /// Eq trait - full equality (marker trait)
    pub const Eq = struct {
        pub const name = "Eq";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{};
        pub const super_traits = [_][]const u8{"PartialEq"};
    };

    /// PartialOrd trait - partial ordering
    pub const PartialOrd = struct {
        pub const name = "PartialOrd";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "partial_cmp",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "&Self" },
                    .{ .name = "other", .type_name = "&Self" },
                },
                .return_type = "Option<Ordering>",
                .is_async = false,
                .is_required = true,
            },
        };
        pub const super_traits = [_][]const u8{"PartialEq"};
    };

    /// Ord trait - total ordering
    pub const Ord = struct {
        pub const name = "Ord";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "cmp",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "&Self" },
                    .{ .name = "other", .type_name = "&Self" },
                },
                .return_type = "Ordering",
                .is_async = false,
                .is_required = true,
            },
        };
        pub const super_traits = [_][]const u8{ "Eq", "PartialOrd" };
    };

    /// Iterator trait
    pub const Iterator = struct {
        pub const name = "Iterator";
        pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
            .{ .name = "Item", .bounds = &[_][]const u8{} },
        };
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "next",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "&mut Self" },
                },
                .return_type = "Option<Self::Item>",
                .is_async = false,
                .is_required = true,
            },
        };
    };

    /// Default trait - default values
    pub const Default = struct {
        pub const name = "Default";
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "default",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{},
                .return_type = "Self",
                .is_async = false,
                .is_required = true,
            },
        };
    };

    /// From trait - value-to-value conversion
    pub const From = struct {
        pub const name = "From";
        pub const generic_params = [_][]const u8{"T"};
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "from",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "value", .type_name = "T" },
                },
                .return_type = "Self",
                .is_async = false,
                .is_required = true,
            },
        };
    };

    /// Into trait - consuming conversion
    pub const Into = struct {
        pub const name = "Into";
        pub const generic_params = [_][]const u8{"T"};
        pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
            .{
                .name = "into",
                .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                    .{ .name = "self", .type_name = "Self" },
                },
                .return_type = "T",
                .is_async = false,
                .is_required = true,
            },
        };
    };
};
