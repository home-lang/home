const std = @import("std");
const ast = @import("../ast/ast.zig");
const types = @import("../types/type_system.zig");

/// Trait definition - similar to Rust traits or TypeScript interfaces
pub const Trait = struct {
    name: []const u8,
    methods: []TraitMethod,
    associated_types: []AssociatedType,
    super_traits: [][]const u8, // Trait inheritance
    loc: ast.SourceLocation,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, loc: ast.SourceLocation) !*Trait {
        const trait = try allocator.create(Trait);
        errdefer allocator.destroy(trait);
        trait.* = .{
            .name = name,
            .methods = &[_]TraitMethod{},
            .associated_types = &[_]AssociatedType{},
            .super_traits = &[_][]const u8{},
            .loc = loc,
            .allocator = allocator,
        };
        return trait;
    }

    pub fn deinit(self: *Trait) void {
        for (self.methods) |*method| {
            method.deinit();
        }
        self.allocator.free(self.methods);
        self.allocator.free(self.associated_types);
        self.allocator.free(self.super_traits);
        self.allocator.destroy(self);
    }
};

/// Method signature within a trait
pub const TraitMethod = struct {
    name: []const u8,
    params: []types.Type,
    return_type: types.Type,
    has_default_impl: bool,
    is_async: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TraitMethod) void {
        self.allocator.free(self.params);
    }
};

/// Associated type in a trait (like Rust's associated types)
pub const AssociatedType = struct {
    name: []const u8,
    bounds: [][]const u8, // Trait bounds
};

/// Trait implementation for a concrete type
pub const TraitImpl = struct {
    trait_name: []const u8,
    for_type: types.Type,
    methods: std.StringHashMap(TraitMethodImpl),
    associated_types: std.StringHashMap(types.Type),
    loc: ast.SourceLocation,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, trait_name: []const u8, for_type: types.Type, loc: ast.SourceLocation) TraitImpl {
        return .{
            .trait_name = trait_name,
            .for_type = for_type,
            .methods = std.StringHashMap(TraitMethodImpl).init(allocator),
            .associated_types = std.StringHashMap(types.Type).init(allocator),
            .loc = loc,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TraitImpl) void {
        var method_iter = self.methods.iterator();
        while (method_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.methods.deinit();
        self.associated_types.deinit();
    }
};

/// Concrete implementation of a trait method
pub const TraitMethodImpl = struct {
    name: []const u8,
    function_node: *ast.FunctionDecl,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TraitMethodImpl) void {
        _ = self;
    }
};

/// Trait bound for generic types (e.g., T: Display + Clone)
pub const TraitBound = struct {
    type_param: []const u8,
    required_traits: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, type_param: []const u8) TraitBound {
        return .{
            .type_param = type_param,
            .required_traits = &[_][]const u8{},
            .allocator = allocator,
        };
    }

    pub fn addTrait(self: *TraitBound, trait_name: []const u8) !void {
        const new_slice = try self.allocator.alloc([]const u8, self.required_traits.len + 1);
        @memcpy(new_slice[0..self.required_traits.len], self.required_traits);
        new_slice[self.required_traits.len] = trait_name;
        if (self.required_traits.len > 0) {
            self.allocator.free(self.required_traits);
        }
        self.required_traits = new_slice;
    }

    pub fn deinit(self: *TraitBound) void {
        if (self.required_traits.len > 0) {
            self.allocator.free(self.required_traits);
        }
    }
};

/// The trait system manages all traits and implementations
pub const TraitSystem = struct {
    allocator: std.mem.Allocator,
    traits: std.StringHashMap(*Trait),
    implementations: std.ArrayList(TraitImpl),
    builtin_traits: std.StringHashMap(BuiltinTraitInfo),
    errors: std.ArrayList(TraitError),

    pub fn init(allocator: std.mem.Allocator) TraitSystem {
        var system = TraitSystem{
            .allocator = allocator,
            .traits = std.StringHashMap(*Trait).init(allocator),
            .implementations = std.ArrayList(TraitImpl).init(allocator),
            .builtin_traits = std.StringHashMap(BuiltinTraitInfo).init(allocator),
            .errors = std.ArrayList(TraitError).init(allocator),
        };

        // Initialize built-in traits
        system.initBuiltinTraits() catch {};

        return system;
    }

    pub fn deinit(self: *TraitSystem) void {
        var trait_iter = self.traits.iterator();
        while (trait_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.traits.deinit();

        for (self.implementations.items) |*impl| {
            impl.deinit();
        }
        self.implementations.deinit();

        self.builtin_traits.deinit();
        self.errors.deinit();
    }

    /// Initialize built-in traits like Copy, Clone, Display, Debug
    fn initBuiltinTraits(self: *TraitSystem) !void {
        try self.builtin_traits.put("Copy", .{
            .name = "Copy",
            .auto_derive = true,
            .marker_trait = true,
        });

        try self.builtin_traits.put("Clone", .{
            .name = "Clone",
            .auto_derive = false,
            .marker_trait = false,
        });

        try self.builtin_traits.put("Display", .{
            .name = "Display",
            .auto_derive = false,
            .marker_trait = false,
        });

        try self.builtin_traits.put("Debug", .{
            .name = "Debug",
            .auto_derive = true,
            .marker_trait = false,
        });

        try self.builtin_traits.put("Default", .{
            .name = "Default",
            .auto_derive = true,
            .marker_trait = false,
        });

        try self.builtin_traits.put("Eq", .{
            .name = "Eq",
            .auto_derive = true,
            .marker_trait = false,
        });

        try self.builtin_traits.put("Ord", .{
            .name = "Ord",
            .auto_derive = true,
            .marker_trait = false,
        });

        try self.builtin_traits.put("Hash", .{
            .name = "Hash",
            .auto_derive = true,
            .marker_trait = false,
        });
    }

    /// Register a new trait definition
    pub fn registerTrait(self: *TraitSystem, trait: *Trait) !void {
        if (self.traits.contains(trait.name)) {
            try self.addError(.{
                .kind = .DuplicateTrait,
                .message = try std.fmt.allocPrint(self.allocator, "trait '{s}' is already defined", .{trait.name}),
                .loc = trait.loc,
            });
            return error.DuplicateTrait;
        }
        try self.traits.put(trait.name, trait);
    }

    /// Register a trait implementation
    pub fn registerImpl(self: *TraitSystem, impl: TraitImpl) !void {
        // Verify trait exists
        if (!self.traits.contains(impl.trait_name)) {
            try self.addError(.{
                .kind = .UnknownTrait,
                .message = try std.fmt.allocPrint(self.allocator, "trait '{s}' is not defined", .{impl.trait_name}),
                .loc = impl.loc,
            });
            return error.UnknownTrait;
        }

        // Check for duplicate implementations
        for (self.implementations.items) |*existing| {
            if (std.mem.eql(u8, existing.trait_name, impl.trait_name) and
                self.typesEqual(existing.for_type, impl.for_type))
            {
                try self.addError(.{
                    .kind = .DuplicateImpl,
                    .message = try std.fmt.allocPrint(self.allocator, "trait '{s}' is already implemented for this type", .{impl.trait_name}),
                    .loc = impl.loc,
                });
                return error.DuplicateImpl;
            }
        }

        try self.implementations.append(impl);
    }

    /// Check if a type implements a trait
    pub fn implementsTrait(self: *TraitSystem, typ: types.Type, trait_name: []const u8) bool {
        // Check for explicit implementation
        for (self.implementations.items) |*impl| {
            if (std.mem.eql(u8, impl.trait_name, trait_name) and
                self.typesEqual(impl.for_type, typ))
            {
                return true;
            }
        }

        // Check for automatic trait implementation (like Copy for primitives)
        if (self.builtin_traits.get(trait_name)) |info| {
            if (info.auto_derive) {
                return self.canAutoDeriveBuiltin(typ, trait_name);
            }
        }

        return false;
    }

    /// Verify that a trait implementation satisfies all required methods
    pub fn verifyImpl(self: *TraitSystem, impl: *TraitImpl) !bool {
        const trait = self.traits.get(impl.trait_name) orelse return false;

        // Check that all required methods are implemented
        for (trait.methods) |*method| {
            if (!method.has_default_impl) {
                if (!impl.methods.contains(method.name)) {
                    try self.addError(.{
                        .kind = .MissingTraitMethod,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "missing required method '{s}' for trait '{s}'",
                            .{ method.name, trait.name },
                        ),
                        .loc = impl.loc,
                    });
                    return false;
                }
            }
        }

        // Check that all associated types are provided
        for (trait.associated_types) |*assoc_type| {
            if (!impl.associated_types.contains(assoc_type.name)) {
                try self.addError(.{
                    .kind = .MissingAssociatedType,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "missing associated type '{s}' for trait '{s}'",
                        .{ assoc_type.name, trait.name },
                    ),
                    .loc = impl.loc,
                });
                return false;
            }
        }

        return true;
    }

    /// Check if trait bounds are satisfied for a generic type
    pub fn checkTraitBounds(self: *TraitSystem, typ: types.Type, bounds: []TraitBound) !bool {
        for (bounds) |*bound| {
            for (bound.required_traits) |trait_name| {
                if (!self.implementsTrait(typ, trait_name)) {
                    try self.addError(.{
                        .kind = .UnsatisfiedTraitBound,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "type does not implement required trait '{s}'",
                            .{trait_name},
                        ),
                        .loc = ast.SourceLocation{ .line = 0, .column = 0 },
                    });
                    return false;
                }
            }
        }
        return true;
    }

    /// Find the implementation of a trait method for a given type
    pub fn findMethod(self: *TraitSystem, typ: types.Type, trait_name: []const u8, method_name: []const u8) ?*TraitMethodImpl {
        for (self.implementations.items) |*impl| {
            if (std.mem.eql(u8, impl.trait_name, trait_name) and
                self.typesEqual(impl.for_type, typ))
            {
                if (impl.methods.getPtr(method_name)) |method| {
                    return method;
                }
            }
        }
        return null;
    }

    /// Check if a type can automatically derive a builtin trait
    fn canAutoDeriveBuiltin(self: *TraitSystem, typ: types.Type, trait_name: []const u8) bool {
        _ = self;

        // Primitives can derive Copy, Debug, Eq, Ord, Hash, Default
        switch (typ) {
            .Int, .Float, .Bool => {
                return std.mem.eql(u8, trait_name, "Copy") or
                    std.mem.eql(u8, trait_name, "Debug") or
                    std.mem.eql(u8, trait_name, "Eq") or
                    std.mem.eql(u8, trait_name, "Ord") or
                    std.mem.eql(u8, trait_name, "Hash") or
                    std.mem.eql(u8, trait_name, "Default");
            },
            .String => {
                return std.mem.eql(u8, trait_name, "Debug") or
                    std.mem.eql(u8, trait_name, "Eq") or
                    std.mem.eql(u8, trait_name, "Hash");
            },
            else => return false,
        }
    }

    fn typesEqual(self: *TraitSystem, a: types.Type, b: types.Type) bool {
        _ = self;
        // Simplified type equality check
        return std.meta.eql(a, b);
    }

    fn addError(self: *TraitSystem, err: TraitError) !void {
        try self.errors.append(err);
    }
};

/// Information about built-in traits
pub const BuiltinTraitInfo = struct {
    name: []const u8,
    auto_derive: bool,
    marker_trait: bool,
};

/// Errors related to traits
pub const TraitError = struct {
    kind: TraitErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
};

pub const TraitErrorKind = enum {
    DuplicateTrait,
    UnknownTrait,
    DuplicateImpl,
    MissingTraitMethod,
    MissingAssociatedType,
    UnsatisfiedTraitBound,
    InvalidTraitBound,
};
