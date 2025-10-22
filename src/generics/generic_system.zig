const std = @import("std");
const ast = @import("../ast/ast.zig");
const types = @import("../types/type_system.zig");
const traits = @import("../traits/trait_system.zig");

/// Generic parameter definition
pub const GenericParam = struct {
    name: []const u8,
    bounds: []traits.TraitBound,
    default_type: ?types.Type,
    loc: ast.SourceLocation,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, loc: ast.SourceLocation) !*GenericParam {
        const param = try allocator.create(GenericParam);
        param.* = .{
            .name = name,
            .bounds = &[_]traits.TraitBound{},
            .default_type = null,
            .loc = loc,
            .allocator = allocator,
        };
        return param;
    }

    pub fn deinit(self: *GenericParam) void {
        for (self.bounds) |*bound| {
            bound.deinit();
        }
        if (self.bounds.len > 0) {
            self.allocator.free(self.bounds);
        }
        self.allocator.destroy(self);
    }

    pub fn addBound(self: *GenericParam, bound: traits.TraitBound) !void {
        const new_bounds = try self.allocator.alloc(traits.TraitBound, self.bounds.len + 1);
        if (self.bounds.len > 0) {
            @memcpy(new_bounds[0..self.bounds.len], self.bounds);
            self.allocator.free(self.bounds);
        }
        new_bounds[self.bounds.len] = bound;
        self.bounds = new_bounds;
    }
};

/// Generic function or struct declaration
pub const GenericDecl = struct {
    name: []const u8,
    params: []*GenericParam,
    where_clauses: []WhereClause,
    loc: ast.SourceLocation,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, loc: ast.SourceLocation) !*GenericDecl {
        const decl = try allocator.create(GenericDecl);
        decl.* = .{
            .name = name,
            .params = &[_]*GenericParam{},
            .where_clauses = &[_]WhereClause{},
            .loc = loc,
            .allocator = allocator,
        };
        return decl;
    }

    pub fn deinit(self: *GenericDecl) void {
        for (self.params) |param| {
            param.deinit();
        }
        if (self.params.len > 0) {
            self.allocator.free(self.params);
        }

        for (self.where_clauses) |*clause| {
            clause.deinit();
        }
        if (self.where_clauses.len > 0) {
            self.allocator.free(self.where_clauses);
        }

        self.allocator.destroy(self);
    }

    pub fn addParam(self: *GenericDecl, param: *GenericParam) !void {
        const new_params = try self.allocator.alloc(*GenericParam, self.params.len + 1);
        if (self.params.len > 0) {
            @memcpy(new_params[0..self.params.len], self.params);
            self.allocator.free(self.params);
        }
        new_params[self.params.len] = param;
        self.params = new_params;
    }

    pub fn addWhereClause(self: *GenericDecl, clause: WhereClause) !void {
        const new_clauses = try self.allocator.alloc(WhereClause, self.where_clauses.len + 1);
        if (self.where_clauses.len > 0) {
            @memcpy(new_clauses[0..self.where_clauses.len], self.where_clauses);
            self.allocator.free(self.where_clauses);
        }
        new_clauses[self.where_clauses.len] = clause;
        self.where_clauses = new_clauses;
    }
};

/// Where clause for complex trait bounds
pub const WhereClause = struct {
    type_expr: types.Type,
    bounds: [][]const u8, // Trait names
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WhereClause) void {
        if (self.bounds.len > 0) {
            self.allocator.free(self.bounds);
        }
    }
};

/// Concrete instantiation of a generic
pub const GenericInstantiation = struct {
    generic_name: []const u8,
    type_args: []types.Type,
    monomorphized: bool,
    loc: ast.SourceLocation,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, generic_name: []const u8, type_args: []types.Type, loc: ast.SourceLocation) !*GenericInstantiation {
        const inst = try allocator.create(GenericInstantiation);
        inst.* = .{
            .generic_name = generic_name,
            .type_args = type_args,
            .monomorphized = false,
            .loc = loc,
            .allocator = allocator,
        };
        return inst;
    }

    pub fn deinit(self: *GenericInstantiation) void {
        if (self.type_args.len > 0) {
            self.allocator.free(self.type_args);
        }
        self.allocator.destroy(self);
    }

    /// Generate a unique name for this instantiation (for monomorphization)
    pub fn getMonomorphizedName(self: *GenericInstantiation) ![]const u8 {
        var name = std.ArrayList(u8).init(self.allocator);
        try name.appendSlice(self.generic_name);
        try name.append('_');

        for (self.type_args, 0..) |arg, i| {
            if (i > 0) try name.append('_');
            try name.appendSlice(try self.typeToString(arg));
        }

        return name.toOwnedSlice();
    }

    fn typeToString(self: *GenericInstantiation, typ: types.Type) ![]const u8 {
        return switch (typ) {
            .Int => "int",
            .Float => "float",
            .Bool => "bool",
            .String => "string",
            .Void => "void",
            else => try std.fmt.allocPrint(self.allocator, "type_{d}", .{@intFromPtr(&typ)}),
        };
    }
};

/// Generic system managing monomorphization and constraint checking
pub const GenericSystem = struct {
    allocator: std.mem.Allocator,
    declarations: std.StringHashMap(*GenericDecl),
    instantiations: std.ArrayList(*GenericInstantiation),
    trait_system: *traits.TraitSystem,
    errors: std.ArrayList(GenericError),

    pub fn init(allocator: std.mem.Allocator, trait_system: *traits.TraitSystem) GenericSystem {
        return .{
            .allocator = allocator,
            .declarations = std.StringHashMap(*GenericDecl).init(allocator),
            .instantiations = std.ArrayList(*GenericInstantiation).init(allocator),
            .trait_system = trait_system,
            .errors = std.ArrayList(GenericError).init(allocator),
        };
    }

    pub fn deinit(self: *GenericSystem) void {
        var decl_iter = self.declarations.iterator();
        while (decl_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.declarations.deinit();

        for (self.instantiations.items) |inst| {
            inst.deinit();
        }
        self.instantiations.deinit();

        self.errors.deinit();
    }

    /// Register a generic declaration
    pub fn registerGeneric(self: *GenericSystem, decl: *GenericDecl) !void {
        if (self.declarations.contains(decl.name)) {
            try self.addError(.{
                .kind = .DuplicateGeneric,
                .message = try std.fmt.allocPrint(self.allocator, "generic '{s}' is already defined", .{decl.name}),
                .loc = decl.loc,
            });
            return error.DuplicateGeneric;
        }
        try self.declarations.put(decl.name, decl);
    }

    /// Instantiate a generic with concrete types
    pub fn instantiate(self: *GenericSystem, generic_name: []const u8, type_args: []types.Type, loc: ast.SourceLocation) !*GenericInstantiation {
        const decl = self.declarations.get(generic_name) orelse {
            try self.addError(.{
                .kind = .UnknownGeneric,
                .message = try std.fmt.allocPrint(self.allocator, "generic '{s}' is not defined", .{generic_name}),
                .loc = loc,
            });
            return error.UnknownGeneric;
        };

        // Check parameter count
        if (type_args.len != decl.params.len) {
            try self.addError(.{
                .kind = .WrongNumberOfTypeArgs,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "expected {d} type arguments, got {d}",
                    .{ decl.params.len, type_args.len },
                ),
                .loc = loc,
            });
            return error.WrongNumberOfTypeArgs;
        }

        // Check trait bounds for each type argument
        for (decl.params, 0..) |param, i| {
            const type_arg = type_args[i];

            for (param.bounds) |*bound| {
                if (!try self.trait_system.checkTraitBounds(type_arg, &[_]traits.TraitBound{bound.*})) {
                    try self.addError(.{
                        .kind = .UnsatisfiedBound,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "type argument does not satisfy bounds for parameter '{s}'",
                            .{param.name},
                        ),
                        .loc = loc,
                    });
                    return error.UnsatisfiedBound;
                }
            }
        }

        // Check where clauses
        for (decl.where_clauses) |*clause| {
            // Substitute generic parameters with concrete types
            const concrete_type = try self.substituteType(clause.type_expr, decl.params, type_args);

            // Check if the substituted type satisfies the bounds
            for (clause.bounds) |trait_name| {
                if (!self.trait_system.implementsTrait(concrete_type, trait_name)) {
                    try self.addError(.{
                        .kind = .UnsatisfiedWhereClause,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "where clause not satisfied: type does not implement '{s}'",
                            .{trait_name},
                        ),
                        .loc = loc,
                    });
                    return error.UnsatisfiedWhereClause;
                }
            }
        }

        // Check if this instantiation already exists
        for (self.instantiations.items) |inst| {
            if (std.mem.eql(u8, inst.generic_name, generic_name) and
                self.typeArgsEqual(inst.type_args, type_args))
            {
                return inst; // Return existing instantiation
            }
        }

        // Create new instantiation
        const inst = try GenericInstantiation.init(self.allocator, generic_name, type_args, loc);
        try self.instantiations.append(inst);

        return inst;
    }

    /// Monomorphize all generic instantiations
    pub fn monomorphizeAll(self: *GenericSystem) ![]MonomorphizedFunction {
        var result = std.ArrayList(MonomorphizedFunction).init(self.allocator);

        for (self.instantiations.items) |inst| {
            if (!inst.monomorphized) {
                const mono = try self.monomorphize(inst);
                try result.append(mono);
                inst.monomorphized = true;
            }
        }

        return result.toOwnedSlice();
    }

    /// Monomorphize a single instantiation
    fn monomorphize(self: *GenericSystem, inst: *GenericInstantiation) !MonomorphizedFunction {
        const decl = self.declarations.get(inst.generic_name).?;

        const name = try inst.getMonomorphizedName();

        return MonomorphizedFunction{
            .name = name,
            .original_generic = inst.generic_name,
            .type_args = inst.type_args,
            .loc = inst.loc,
        };
    }

    /// Substitute generic type parameters with concrete types
    fn substituteType(self: *GenericSystem, typ: types.Type, params: []*GenericParam, args: []types.Type) !types.Type {
        _ = self;

        switch (typ) {
            .Generic => |gen| {
                // Find the parameter and substitute
                for (params, 0..) |param, i| {
                    if (std.mem.eql(u8, param.name, gen.name)) {
                        return args[i];
                    }
                }
                return typ; // Not found, return as is
            },
            else => return typ,
        }
    }

    /// Check if two type argument lists are equal
    fn typeArgsEqual(self: *GenericSystem, a: []types.Type, b: []types.Type) bool {
        _ = self;
        if (a.len != b.len) return false;

        for (a, 0..) |type_a, i| {
            const type_b = b[i];
            if (!std.meta.eql(type_a, type_b)) return false;
        }

        return true;
    }

    fn addError(self: *GenericSystem, err: GenericError) !void {
        try self.errors.append(err);
    }
};

/// Monomorphized (concrete) function from generic
pub const MonomorphizedFunction = struct {
    name: []const u8,
    original_generic: []const u8,
    type_args: []types.Type,
    loc: ast.SourceLocation,
};

/// Generic system errors
pub const GenericError = struct {
    kind: GenericErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
};

pub const GenericErrorKind = enum {
    DuplicateGeneric,
    UnknownGeneric,
    WrongNumberOfTypeArgs,
    UnsatisfiedBound,
    UnsatisfiedWhereClause,
    InvalidTypeArg,
    RecursiveInstantiation,
};

/// Higher-Kinded Types (HKT) support for advanced generics
pub const HigherKindedType = struct {
    name: []const u8,
    kind: TypeKind,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, kind: TypeKind) !*HigherKindedType {
        const hkt = try allocator.create(HigherKindedType);
        hkt.* = .{
            .name = name,
            .kind = kind,
            .allocator = allocator,
        };
        return hkt;
    }

    pub fn deinit(self: *HigherKindedType) void {
        self.allocator.destroy(self);
    }
};

/// Type kinds for HKT (like * -> * for container types)
pub const TypeKind = union(enum) {
    Star: void, // * (concrete type)
    Arrow: struct { // * -> *  (type constructor)
        from: *TypeKind,
        to: *TypeKind,
    },
};

/// Variance annotations for generics
pub const Variance = enum {
    Covariant, // +T (can substitute with subtypes)
    Contravariant, // -T (can substitute with supertypes)
    Invariant, // T (no substitution)
    Bivariant, // +/- T (can substitute either way)
};
