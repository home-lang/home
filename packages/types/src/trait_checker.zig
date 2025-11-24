const std = @import("std");
const ast = @import("ast");
const traits_mod = @import("traits");
const TraitSystem = traits_mod.TraitSystem;

/// Trait type checker
/// Verifies trait implementations and bounds during type checking
pub const TraitChecker = struct {
    allocator: std.mem.Allocator,
    trait_system: *TraitSystem,
    errors: std.ArrayList(TraitError),

    pub fn init(allocator: std.mem.Allocator, trait_system: *TraitSystem) TraitChecker {
        return .{
            .allocator = allocator,
            .trait_system = trait_system,
            .errors = std.ArrayList(TraitError).init(allocator),
        };
    }

    pub fn deinit(self: *TraitChecker) void {
        for (self.errors.items) |*err| {
            err.deinit(self.allocator);
        }
        self.errors.deinit();
    }

    /// Check a trait declaration for validity
    pub fn checkTraitDecl(self: *TraitChecker, trait_decl: *ast.TraitDecl) !void {
        // Verify super traits exist
        for (trait_decl.super_traits) |super_trait| {
            if (self.trait_system.traits.get(super_trait) == null) {
                try self.addError(.{
                    .kind = .UndefinedSuperTrait,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Super trait '{s}' is not defined",
                        .{super_trait},
                    ),
                    .location = trait_decl.node.loc,
                });
            }
        }

        // Check for circular trait inheritance
        try self.checkCircularInheritance(trait_decl.name, trait_decl.super_traits);

        // Verify method signatures are valid
        for (trait_decl.methods) |method| {
            try self.checkTraitMethod(trait_decl.name, method);
        }

        // Verify associated types
        for (trait_decl.associated_types) |assoc_type| {
            for (assoc_type.bounds) |bound| {
                if (self.trait_system.traits.get(bound) == null) {
                    try self.addError(.{
                        .kind = .UndefinedTrait,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Trait bound '{s}' on associated type '{s}' is not defined",
                            .{ bound, assoc_type.name },
                        ),
                        .location = trait_decl.node.loc,
                    });
                }
            }
        }
    }

    /// Check an impl declaration for validity
    pub fn checkImplDecl(self: *TraitChecker, impl_decl: *ast.ImplDecl) !void {
        // If this is a trait impl, verify the trait exists
        if (impl_decl.trait_name) |trait_name| {
            const trait_def = self.trait_system.traits.get(trait_name) orelse {
                try self.addError(.{
                    .kind = .UndefinedTrait,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Trait '{s}' is not defined",
                        .{trait_name},
                    ),
                    .location = impl_decl.node.loc,
                });
                return;
            };

            // Verify all required methods are implemented
            try self.checkRequiredMethods(impl_decl, trait_def);

            // Verify method signatures match trait definition
            try self.checkMethodSignatures(impl_decl, trait_def);

            // Verify associated type bindings
            try self.checkAssociatedTypes(impl_decl, trait_def);

            // Check super trait requirements
            try self.checkSuperTraitRequirements(impl_decl, trait_def);
        }

        // Check where clause bounds
        if (impl_decl.where_clause) |where_clause| {
            try self.checkWhereClause(where_clause);
        }
    }

    /// Verify all required trait methods are implemented
    fn checkRequiredMethods(
        self: *TraitChecker,
        impl_decl: *ast.ImplDecl,
        trait_def: TraitSystem.TraitDef,
    ) !void {
        for (trait_def.methods) |trait_method| {
            if (!trait_method.is_required) continue;

            var found = false;
            for (impl_decl.methods) |impl_method| {
                if (std.mem.eql(u8, impl_method.name, trait_method.name)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                try self.addError(.{
                    .kind = .MissingRequiredMethod,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Missing required method '{s}' from trait '{s}'",
                        .{ trait_method.name, trait_def.name },
                    ),
                    .location = impl_decl.node.loc,
                });
            }
        }
    }

    /// Verify method signatures match trait definition
    fn checkMethodSignatures(
        self: *TraitChecker,
        impl_decl: *ast.ImplDecl,
        trait_def: TraitSystem.TraitDef,
    ) !void {
        for (impl_decl.methods) |impl_method| {
            // Find corresponding trait method
            var trait_method: ?TraitSystem.TraitDef.MethodSignature = null;
            for (trait_def.methods) |tm| {
                if (std.mem.eql(u8, tm.name, impl_method.name)) {
                    trait_method = tm;
                    break;
                }
            }

            if (trait_method == null) {
                try self.addError(.{
                    .kind = .ExtraMethod,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Method '{s}' is not part of trait '{s}'",
                        .{ impl_method.name, trait_def.name },
                    ),
                    .location = impl_decl.node.loc,
                });
                continue;
            }

            // Verify parameter types and return type match
            try self.verifyMethodSignature(impl_method, trait_method.?, trait_def.name);
        }
    }

    /// Verify that implementation method signature matches trait method
    fn verifyMethodSignature(
        self: *TraitChecker,
        impl_method: *ast.TraitMethod,
        trait_method: *ast.TraitMethod,
        trait_name: []const u8,
    ) !void {
        // Check parameter count
        if (impl_method.params.len != trait_method.params.len) {
            try self.addError(.{
                .kind = .MethodSignatureMismatch,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Method '{s}' parameter count mismatch: trait expects {d}, impl has {d}",
                    .{ impl_method.name, trait_method.params.len, impl_method.params.len },
                ),
                .location = impl_method.loc,
            });
            return;
        }

        // Check each parameter type
        for (impl_method.params, trait_method.params) |impl_param, trait_param| {
            // For now, just check if both have type annotations
            // Full type checking would require type resolution
            const impl_has_type = impl_param.type_expr != null;
            const trait_has_type = trait_param.type_expr != null;

            if (impl_has_type and trait_has_type) {
                // In a full implementation, would compare resolved types
                // For now, we trust that the type checker will catch mismatches
            } else if (trait_has_type and !impl_has_type) {
                try self.addError(.{
                    .kind = .MethodSignatureMismatch,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Method '{s}' parameter '{s}' missing type annotation in trait '{s}'",
                        .{ impl_method.name, impl_param.name, trait_name },
                    ),
                    .location = impl_method.loc,
                });
            }
        }

        // Check return type
        const impl_has_return = impl_method.return_type != null;
        const trait_has_return = trait_method.return_type != null;

        if (impl_has_return != trait_has_return) {
            try self.addError(.{
                .kind = .MethodSignatureMismatch,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Method '{s}' return type mismatch in trait '{s}'",
                    .{ impl_method.name, trait_name },
                ),
                .location = impl_method.loc,
            });
        }
    }

    /// Verify associated type bindings
    fn checkAssociatedTypes(
        self: *TraitChecker,
        impl_decl: *ast.ImplDecl,
        trait_def: TraitSystem.TraitDef,
    ) !void {
        // Check that all required associated types are provided
        for (trait_def.associated_types) |assoc_type| {
            if (impl_decl.associated_type_bindings.get(assoc_type.name) == null) {
                // Check if there's a default
                if (assoc_type.default_type == null) {
                    try self.addError(.{
                        .kind = .MissingAssociatedType,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Missing associated type '{s}' in impl of trait '{s}'",
                            .{ assoc_type.name, trait_def.name },
                        ),
                        .location = impl_decl.node.loc,
                    });
                }
            }
        }

        // Check that provided associated types are valid
        var it = impl_decl.associated_type_bindings.iterator();
        while (it.next()) |entry| {
            var found = false;
            for (trait_def.associated_types) |assoc_type| {
                if (std.mem.eql(u8, assoc_type.name, entry.key_ptr.*)) {
                    found = true;
                    // Verify the type satisfies bounds
                    if (assoc_type.bounds.len > 0) {
                        try self.verifyTypeBounds(entry.value_ptr.*, assoc_type.bounds, trait_def.name);
                    }
                    break;
                }
            }

            if (!found) {
                try self.addError(.{
                    .kind = .ExtraAssociatedType,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Associated type '{s}' is not part of trait '{s}'",
                        .{ entry.key_ptr.*, trait_def.name },
                    ),
                    .location = impl_decl.node.loc,
                });
            }
        }
    }

    /// Check super trait requirements
    fn checkSuperTraitRequirements(
        self: *TraitChecker,
        impl_decl: *ast.ImplDecl,
        trait_def: TraitSystem.TraitDef,
    ) !void {
        // Get the type being implemented for
        const type_name = try self.typeExprToString(impl_decl.for_type);
        defer self.allocator.free(type_name);

        // Verify all super traits are also implemented
        for (trait_def.super_traits) |super_trait| {
            if (!self.trait_system.implementsTrait(type_name, super_trait)) {
                try self.addError(.{
                    .kind = .MissingSuperTraitImpl,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Type '{s}' must implement super trait '{s}' before implementing '{s}'",
                        .{ type_name, super_trait, trait_def.name },
                    ),
                    .location = impl_decl.node.loc,
                });
            }
        }
    }

    /// Verify that a type satisfies trait bounds
    fn verifyTypeBounds(
        self: *TraitChecker,
        type_expr: *ast.TypeExpr,
        bounds: []const []const u8,
        context: []const u8,
    ) !void {
        // Convert type expression to string for checking
        const type_name = try self.typeExprToString(type_expr);
        defer self.allocator.free(type_name);

        // Check each bound
        for (bounds) |bound_trait| {
            // Check if trait exists
            if (self.trait_system.traits.get(bound_trait) == null) {
                try self.addError(.{
                    .kind = .UndefinedTrait,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Trait bound '{s}' is not defined in context '{s}'",
                        .{ bound_trait, context },
                    ),
                    .location = .{ .line = 0, .column = 0 },
                });
                continue;
            }

            // Check if type implements the trait
            if (!self.trait_system.implementsTrait(type_name, bound_trait)) {
                try self.addError(.{
                    .kind = .TraitBoundNotSatisfied,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Type '{s}' does not satisfy trait bound '{s}' in context '{s}'",
                        .{ type_name, bound_trait, context },
                    ),
                    .location = .{ .line = 0, .column = 0 },
                });
            }
        }
    }

    /// Check where clause bounds
    fn checkWhereClause(self: *TraitChecker, where_clause: *ast.WhereClause) !void {
        for (where_clause.bounds) |bound| {
            for (bound.trait_bounds) |trait_name| {
                if (self.trait_system.traits.get(trait_name) == null) {
                    try self.addError(.{
                        .kind = .UndefinedTrait,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Trait '{s}' in where clause is not defined",
                            .{trait_name},
                        ),
                        .location = .{ .line = 0, .column = 0 },
                    });
                }
            }
        }
    }

    /// Check for circular trait inheritance
    fn checkCircularInheritance(
        self: *TraitChecker,
        trait_name: []const u8,
        _: []const []const u8,
    ) !void {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        try self.checkCircularInheritanceHelper(trait_name, &visited);
    }

    fn checkCircularInheritanceHelper(
        self: *TraitChecker,
        trait_name: []const u8,
        visited: *std.StringHashMap(void),
    ) !void {
        if (visited.contains(trait_name)) {
            try self.addError(.{
                .kind = .CircularInheritance,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Circular trait inheritance detected involving '{s}'",
                    .{trait_name},
                ),
                .location = .{ .line = 0, .column = 0 },
            });
            return;
        }

        try visited.put(trait_name, {});

        const trait_def = self.trait_system.traits.get(trait_name) orelse return;
        for (trait_def.super_traits) |super_trait| {
            try self.checkCircularInheritanceHelper(super_trait, visited);
        }

        _ = visited.remove(trait_name);
    }

    /// Check a trait method for validity
    fn checkTraitMethod(
        _: *TraitChecker,
        trait_name: []const u8,
        method: ast.TraitMethod,
    ) !void {
        _ = trait_name;
        _ = method;
        // TODO: Verify method signature is valid
        // - Check parameter types exist
        // - Check return type exists
        // - Verify Self type usage is correct
    }

    /// Convert TypeExpr to string for error messages
    fn typeExprToString(self: *TraitChecker, type_expr: *ast.TypeExpr) ![]const u8 {
        return switch (type_expr.*) {
            .Named => |name| try self.allocator.dupe(u8, name),
            .SelfType => try self.allocator.dupe(u8, "Self"),
            .Generic => |gen| try std.fmt.allocPrint(
                self.allocator,
                "{s}<...>",
                .{gen.base},
            ),
            .Reference => |ref| {
                const inner = try self.typeExprToString(ref.inner);
                defer self.allocator.free(inner);
                return try std.fmt.allocPrint(
                    self.allocator,
                    "&{s}{s}",
                    .{ if (ref.is_mut) "mut " else "", inner },
                );
            },
            .TraitObject => |obj| try std.fmt.allocPrint(
                self.allocator,
                "dyn {s}",
                .{obj.trait_name},
            ),
            else => try self.allocator.dupe(u8, "<unknown>"),
        };
    }

    fn addError(self: *TraitChecker, err: TraitError) !void {
        try self.errors.append(err);
    }

    pub fn hasErrors(self: *const TraitChecker) bool {
        return self.errors.items.len > 0;
    }

    pub fn getErrors(self: *const TraitChecker) []const TraitError {
        return self.errors.items;
    }
};

/// Trait checking error
pub const TraitError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,

    pub const ErrorKind = enum {
        UndefinedTrait,
        UndefinedSuperTrait,
        MissingRequiredMethod,
        MissingAssociatedType,
        MissingSuperTraitImpl,
        ExtraMethod,
        ExtraAssociatedType,
        CircularInheritance,
        InvalidMethodSignature,
        InvalidTypeParameter,
    };

    pub fn deinit(self: *TraitError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// Check if a type satisfies trait bounds
pub fn checkTraitBounds(
    trait_system: *TraitSystem,
    type_name: []const u8,
    bounds: []const []const u8,
) bool {
    return trait_system.checkBounds(type_name, bounds);
}

/// Resolve associated type from a trait implementation
pub fn resolveAssociatedType(
    trait_system: *TraitSystem,
    type_name: []const u8,
    trait_name: []const u8,
    assoc_type_name: []const u8,
) ?[]const u8 {
    const impl = trait_system.getImplementation(type_name, trait_name) orelse return null;
    return impl.associated_types.get(assoc_type_name);
}
