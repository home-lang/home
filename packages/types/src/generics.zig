const std = @import("std");
const ast = @import("ast");
const Type = @import("type_system.zig").Type;
const TraitSystem = @import("traits").TraitSystem;

/// Generic type system with monomorphization
pub const GenericHandler = struct {
    allocator: std.mem.Allocator,
    /// Map from (generic function/struct, concrete types) to monomorphized version
    monomorphizations: std.StringHashMap(MonomorphizationInfo),
    errors: std.ArrayList(GenericError),
    trait_system: *TraitSystem,

    pub const GenericError = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub const MonomorphizationInfo = struct {
        /// Original generic definition
        generic_name: []const u8,
        /// Concrete type arguments
        type_args: []const Type,
        /// Generated monomorphic name (e.g., "Vec_i32", "max_f64")
        monomorphic_name: []const u8,
        /// The instantiated type/function
        concrete_item: union(enum) {
            Function: *ast.FunctionDecl,
            Struct: Type.StructType,
            Enum: Type.EnumType,
        },
    };

    pub fn init(allocator: std.mem.Allocator, trait_system: *TraitSystem) GenericHandler {
        return .{
            .allocator = allocator,
            .monomorphizations = std.StringHashMap(MonomorphizationInfo).init(allocator),
            .errors = std.ArrayList(GenericError){},
            .trait_system = trait_system,
        };
    }

    pub fn deinit(self: *GenericHandler) void {
        var it = self.monomorphizations.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.monomorphic_name);
        }
        self.monomorphizations.deinit();

        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// Check if type arguments satisfy trait bounds
    pub fn checkBounds(
        self: *GenericHandler,
        type_params: []const TypeParameter,
        type_args: []const Type,
        loc: ast.SourceLocation,
    ) !bool {
        if (type_params.len != type_args.len) {
            try self.addError("Wrong number of type arguments", loc);
            return false;
        }

        for (type_params, type_args) |param, arg| {
            for (param.bounds) |bound_type| {
                // Check if arg satisfies the trait bound
                if (!try self.satisfiesBound(arg, bound_type, loc)) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Type does not satisfy bound",
                        .{},
                    );
                    try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
                    return false;
                }
            }
        }

        return true;
    }

    /// Check if a type satisfies a trait bound
    fn satisfiesBound(
        self: *GenericHandler,
        typ: Type,
        bound: Type,
        loc: ast.SourceLocation,
    ) !bool {
        _ = loc;
        _ = self;
        _ = typ;

        // If bound is a trait, check if type implements it
        if (bound == .Generic) {
            // This would check trait implementation
            // For now, we'll assume basic types satisfy common traits
            return true;
        }

        return true;
    }

    /// Monomorphize a generic function with concrete type arguments
    pub fn monomorphizeFunction(
        self: *GenericHandler,
        generic_fn: *ast.FunctionDecl,
        type_args: []const Type,
        loc: ast.SourceLocation,
    ) ![]const u8 {
        // Generate monomorphic name: func_T1_T2_...
        const mono_name = try self.generateMonomorphicName(generic_fn.name, type_args);

        // Check if already monomorphized
        if (self.monomorphizations.get(mono_name)) |existing| {
            return existing.monomorphic_name;
        }

        // TODO: Actually create monomorphized AST
        // For now, just register the monomorphization
        const info = MonomorphizationInfo{
            .generic_name = generic_fn.name,
            .type_args = type_args,
            .monomorphic_name = mono_name,
            .concrete_item = .{ .Function = generic_fn },
        };

        try self.monomorphizations.put(mono_name, info);

        _ = loc;
        return mono_name;
    }

    /// Generate a unique name for a monomorphized instance
    fn generateMonomorphicName(
        self: *GenericHandler,
        base_name: []const u8,
        type_args: []const Type,
    ) ![]const u8 {
        var name_buf = std.ArrayList(u8).init(self.allocator);
        defer name_buf.deinit();

        try name_buf.appendSlice(base_name);

        for (type_args) |typ| {
            try name_buf.append('_');
            try self.appendTypeName(&name_buf, typ);
        }

        return try self.allocator.dupe(u8, name_buf.items);
    }

    fn appendTypeName(self: *GenericHandler, buf: *std.ArrayList(u8), typ: Type) !void {
        _ = self;
        switch (typ) {
            .Int => try buf.appendSlice("int"),
            .I32 => try buf.appendSlice("i32"),
            .I64 => try buf.appendSlice("i64"),
            .Float => try buf.appendSlice("float"),
            .F32 => try buf.appendSlice("f32"),
            .F64 => try buf.appendSlice("f64"),
            .Bool => try buf.appendSlice("bool"),
            .String => try buf.appendSlice("string"),
            .Struct => |s| try buf.appendSlice(s.name),
            .Enum => |e| try buf.appendSlice(e.name),
            else => try buf.appendSlice("T"),
        }
    }

    /// Substitute type parameters with concrete types
    pub fn substituteType(
        self: *GenericHandler,
        typ: Type,
        type_params: []const TypeParameter,
        type_args: []const Type,
    ) !Type {
        return switch (typ) {
            .Generic => |g| blk: {
                // Find matching type parameter
                for (type_params, type_args) |param, arg| {
                    if (std.mem.eql(u8, param.name, g.name)) {
                        break :blk arg;
                    }
                }
                // Not found, return as-is
                break :blk typ;
            },

            .Array => |arr| blk: {
                const elem_type = try self.substituteType(arr.element_type.*, type_params, type_args);
                const elem_ptr = try self.allocator.create(Type);
                elem_ptr.* = elem_type;
                break :blk Type{
                    .Array = .{ .element_type = elem_ptr },
                };
            },

            .Optional => |opt| blk: {
                const inner_type = try self.substituteType(opt.*, type_params, type_args);
                const inner_ptr = try self.allocator.create(Type);
                inner_ptr.* = inner_type;
                break :blk Type{ .Optional = inner_ptr };
            },

            .Result => |res| blk: {
                const ok_type = try self.substituteType(res.ok_type.*, type_params, type_args);
                const err_type = try self.substituteType(res.err_type.*, type_params, type_args);

                const ok_ptr = try self.allocator.create(Type);
                ok_ptr.* = ok_type;
                const err_ptr = try self.allocator.create(Type);
                err_ptr.* = err_type;

                break :blk Type{
                    .Result = .{ .ok_type = ok_ptr, .err_type = err_ptr },
                };
            },

            else => typ,
        };
    }

    fn addError(self: *GenericHandler, message: []const u8, loc: ast.SourceLocation) !void {
        const msg = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
    }

    pub fn hasErrors(self: *GenericHandler) bool {
        return self.errors.items.len > 0;
    }
};

/// Type parameter with bounds
pub const TypeParameter = struct {
    name: []const u8,
    bounds: []const Type,
};

/// Utilities for working with generic types
pub const GenericUtils = struct {
    /// Check if a type contains any generic type parameters
    pub fn isGeneric(typ: Type) bool {
        return switch (typ) {
            .Generic => true,
            .Array => |arr| isGeneric(arr.element_type.*),
            .Optional => |opt| isGeneric(opt.*),
            .Result => |res| isGeneric(res.ok_type.*) or isGeneric(res.err_type.*),
            .Tuple => |tup| blk: {
                for (tup.element_types) |elem| {
                    if (isGeneric(elem)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    /// Extract all type variables from a type
    pub fn extractTypeVars(allocator: std.mem.Allocator, typ: Type) ![][]const u8 {
        var vars = std.ArrayList([]const u8).init(allocator);
        try collectTypeVars(typ, &vars);
        return try vars.toOwnedSlice();
    }

    fn collectTypeVars(typ: Type, vars: *std.ArrayList([]const u8)) !void {
        switch (typ) {
            .Generic => |g| {
                // Check if already added
                for (vars.items) |existing| {
                    if (std.mem.eql(u8, existing, g.name)) return;
                }
                try vars.append(g.name);
            },
            .Array => |arr| try collectTypeVars(arr.element_type.*, vars),
            .Optional => |opt| try collectTypeVars(opt.*, vars),
            .Result => |res| {
                try collectTypeVars(res.ok_type.*, vars);
                try collectTypeVars(res.err_type.*, vars);
            },
            .Tuple => |tup| {
                for (tup.element_types) |elem| {
                    try collectTypeVars(elem, vars);
                }
            },
            else => {},
        }
    }
};
