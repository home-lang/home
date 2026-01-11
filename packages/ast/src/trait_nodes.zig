const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeType = ast.NodeType;
const SourceLocation = ast.SourceLocation;
const FnDecl = ast.FnDecl;
const Expr = ast.Expr;

/// Trait declaration node
/// Example: trait Drawable { fn draw(&self) -> void }
pub const TraitDecl = struct {
    node: Node,
    name: []const u8,
    generic_params: []const GenericParam,
    super_traits: []const []const u8,  // Trait names this trait extends
    methods: []const TraitMethod,
    associated_types: []const AssociatedType,
    where_clause: ?*WhereClause,
    is_public: bool = false,

    pub fn init(
        name: []const u8,
        generic_params: []const GenericParam,
        super_traits: []const []const u8,
        methods: []const TraitMethod,
        associated_types: []const AssociatedType,
        where_clause: ?*WhereClause,
        loc: SourceLocation,
    ) TraitDecl {
        return .{
            .node = .{ .type = .TraitDecl, .loc = loc },
            .name = name,
            .generic_params = generic_params,
            .super_traits = super_traits,
            .methods = methods,
            .associated_types = associated_types,
            .where_clause = where_clause,
        };
    }

    pub fn deinit(self: *TraitDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.generic_params);
        allocator.free(self.super_traits);
        allocator.free(self.methods);
        allocator.free(self.associated_types);
        if (self.where_clause) |wc| {
            wc.deinit(allocator);
            allocator.destroy(wc);
        }
    }
};

/// Trait method signature (no body in trait definition)
pub const TraitMethod = struct {
    name: []const u8,
    params: []const FnParam,
    return_type: ?*TypeExpr,
    is_async: bool,
    has_default_impl: bool,  // true if method has a default implementation
    default_body: ?*ast.BlockStmt,  // Default implementation if provided

    pub fn deinit(self: *TraitMethod, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.params);
        if (self.return_type) |rt| {
            allocator.destroy(rt);
        }
        if (self.default_body) |body| {
            allocator.destroy(body);
        }
    }
};

/// Function parameter
pub const FnParam = struct {
    name: []const u8,
    type_expr: *TypeExpr,
    is_mut: bool,
    is_self: bool,  // true for self/&self/&mut self
};

/// Associated type in a trait
/// Example: type Item in trait Iterator
pub const AssociatedType = struct {
    name: []const u8,
    bounds: []const []const u8,  // Trait bounds on this type
    default_type: ?*TypeExpr,  // Optional default type

    pub fn deinit(self: *AssociatedType, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bounds);
        if (self.default_type) |dt| {
            allocator.destroy(dt);
        }
    }
};

/// Trait implementation node
/// Example: impl Drawable for Circle { ... }
pub const ImplDecl = struct {
    node: Node,
    trait_name: ?[]const u8,  // None for inherent impl (impl MyType {})
    for_type: *TypeExpr,
    generic_params: []const GenericParam,
    methods: []const *FnDecl,
    associated_type_bindings: std.StringHashMap(*TypeExpr),
    where_clause: ?*WhereClause,

    pub fn init(
        trait_name: ?[]const u8,
        for_type: *TypeExpr,
        generic_params: []const GenericParam,
        methods: []const *FnDecl,
        where_clause: ?*WhereClause,
        loc: SourceLocation,
        allocator: std.mem.Allocator,
    ) ImplDecl {
        return .{
            .node = .{ .type = .ImplDecl, .loc = loc },
            .trait_name = trait_name,
            .for_type = for_type,
            .generic_params = generic_params,
            .methods = methods,
            .associated_type_bindings = std.StringHashMap(*TypeExpr).init(allocator),
            .where_clause = where_clause,
        };
    }

    pub fn deinit(self: *ImplDecl, allocator: std.mem.Allocator) void {
        if (self.trait_name) |tn| allocator.free(tn);
        allocator.destroy(self.for_type);
        allocator.free(self.generic_params);
        for (self.methods) |method| {
            allocator.destroy(method);
        }
        allocator.free(self.methods);
        
        var it = self.associated_type_bindings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.destroy(entry.value_ptr.*);
        }
        self.associated_type_bindings.deinit();
        
        if (self.where_clause) |wc| {
            wc.deinit(allocator);
            allocator.destroy(wc);
        }
    }
};

/// Extension declaration for adding methods to existing types
/// Example: extend string { fn is_email(&self): bool { ... } }
/// Unlike impl, extend doesn't implement a trait - it adds standalone methods
pub const ExtendDecl = struct {
    node: Node,
    /// The type being extended (e.g., "string", "int", "Vec<T>")
    target_type: *TypeExpr,
    /// Generic parameters for the extension (e.g., extend<T> Vec<T> { ... })
    generic_params: []const GenericParam,
    /// Methods being added to the type
    methods: []const *FnDecl,
    /// Where clause constraints
    where_clause: ?*WhereClause,

    pub fn init(
        target_type: *TypeExpr,
        generic_params: []const GenericParam,
        methods: []const *FnDecl,
        where_clause: ?*WhereClause,
        loc: SourceLocation,
    ) ExtendDecl {
        return .{
            .node = .{ .type = .ExtendDecl, .loc = loc },
            .target_type = target_type,
            .generic_params = generic_params,
            .methods = methods,
            .where_clause = where_clause,
        };
    }

    pub fn deinit(self: *ExtendDecl, allocator: std.mem.Allocator) void {
        allocator.destroy(self.target_type);
        allocator.free(self.generic_params);
        for (self.methods) |method| {
            allocator.destroy(method);
        }
        allocator.free(self.methods);
        if (self.where_clause) |wc| {
            wc.deinit(allocator);
            allocator.destroy(wc);
        }
    }
};

/// Where clause for complex trait bounds
/// Example: where T: Clone + Debug, U: Display
pub const WhereClause = struct {
    bounds: []const WhereBound,

    pub fn deinit(self: *WhereClause, allocator: std.mem.Allocator) void {
        for (self.bounds) |*bound| {
            bound.deinit(allocator);
        }
        allocator.free(self.bounds);
    }
};

/// Single bound in a where clause
pub const WhereBound = struct {
    type_param: []const u8,
    trait_bounds: []const []const u8,

    pub fn deinit(self: *WhereBound, allocator: std.mem.Allocator) void {
        allocator.free(self.type_param);
        for (self.trait_bounds) |bound| {
            allocator.free(bound);
        }
        allocator.free(self.trait_bounds);
    }
};

/// Generic parameter
pub const GenericParam = struct {
    name: []const u8,
    bounds: []const []const u8,  // Trait bounds
    default_type: ?*TypeExpr,

    pub fn deinit(self: *GenericParam, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.bounds) |bound| {
            allocator.free(bound);
        }
        allocator.free(self.bounds);
        if (self.default_type) |dt| {
            allocator.destroy(dt);
        }
    }
};

/// Type expression (used for type annotations)
pub const TypeExpr = union(enum) {
    Named: []const u8,  // Simple type name
    Generic: struct {
        base: []const u8,
        args: []const *TypeExpr,
    },
    Reference: struct {
        is_mut: bool,
        inner: *TypeExpr,
    },
    Pointer: struct {
        is_mut: bool,
        inner: *TypeExpr,
    },
    Array: struct {
        element: *TypeExpr,
        size: ?*Expr,  // None for slices
    },
    Tuple: []const *TypeExpr,
    Function: struct {
        params: []const *TypeExpr,
        return_type: ?*TypeExpr,
    },
    TraitObject: struct {  // dyn Trait
        trait_name: []const u8,
        bounds: []const []const u8,
    },
    SelfType,  // The Self type in traits/impls
    Nullable: *TypeExpr,  // Type? syntax for optional types

    pub fn deinit(self: *TypeExpr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Named => |name| allocator.free(name),
            .Generic => |gen| {
                allocator.free(gen.base);
                for (gen.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(gen.args);
            },
            .Reference, .Pointer => |ref| {
                ref.inner.deinit(allocator);
                allocator.destroy(ref.inner);
            },
            .Array => |arr| {
                arr.element.deinit(allocator);
                allocator.destroy(arr.element);
            },
            .Tuple => |tuple| {
                for (tuple) |t| {
                    t.deinit(allocator);
                    allocator.destroy(t);
                }
                allocator.free(tuple);
            },
            .Function => |func| {
                for (func.params) |param| {
                    param.deinit(allocator);
                    allocator.destroy(param);
                }
                allocator.free(func.params);
                if (func.return_type) |rt| {
                    rt.deinit(allocator);
                    allocator.destroy(rt);
                }
            },
            .TraitObject => |obj| {
                allocator.free(obj.trait_name);
                for (obj.bounds) |bound| {
                    allocator.free(bound);
                }
                allocator.free(obj.bounds);
            },
            .SelfType => {},
            .Nullable => |inner| {
                inner.deinit(allocator);
                allocator.destroy(inner);
            },
        }
    }
};
