const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const SourceLocation = ast.SourceLocation;
const Expr = ast.Expr;

/// Multiple dispatch function declaration
/// Multiple functions with same name but different parameter types
pub const MultiDispatchFn = struct {
    name: []const u8,
    variants: []const FnVariant,
    loc: SourceLocation,

    pub const FnVariant = struct {
        params: []const DispatchParam,
        return_type: ?[]const u8,
        body: *ast.BlockStmt,
        specificity: usize,  // For dispatch ordering
        loc: SourceLocation,
    };

    pub fn init(
        name: []const u8,
        variants: []const FnVariant,
        loc: SourceLocation,
    ) MultiDispatchFn {
        return .{
            .name = name,
            .variants = variants,
            .loc = loc,
        };
    }

    pub fn deinit(self: *MultiDispatchFn, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.variants) |*variant| {
            for (variant.params) |*param| {
                param.deinit(allocator);
            }
            allocator.free(variant.params);
            if (variant.return_type) |rt| {
                allocator.free(rt);
            }
            allocator.destroy(variant.body);
        }
        allocator.free(self.variants);
    }
};

/// Parameter in a dispatch function
pub const DispatchParam = struct {
    name: []const u8,
    type_constraint: TypeConstraint,
    is_mut: bool,

    pub const TypeConstraint = union(enum) {
        Concrete: []const u8,           // Specific type: Circle
        Trait: []const u8,              // Trait bound: Shape
        Generic: []const u8,            // Generic: T
        Union: []const []const u8,      // Union: Circle | Rectangle
        Any,                            // Any type
    };

    pub fn init(
        name: []const u8,
        type_constraint: TypeConstraint,
        is_mut: bool,
    ) DispatchParam {
        return .{
            .name = name,
            .type_constraint = type_constraint,
            .is_mut = is_mut,
        };
    }

    pub fn deinit(self: *DispatchParam, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        switch (self.type_constraint) {
            .Concrete => |t| allocator.free(t),
            .Trait => |t| allocator.free(t),
            .Generic => |t| allocator.free(t),
            .Union => |types| {
                for (types) |t| {
                    allocator.free(t);
                }
                allocator.free(types);
            },
            .Any => {},
        }
    }
};

/// Dispatch table for runtime method selection
pub const DispatchTable = struct {
    function_name: []const u8,
    entries: std.ArrayList(DispatchEntry),
    allocator: std.mem.Allocator,

    pub const DispatchEntry = struct {
        signature: []const []const u8,  // Type signature
        variant_index: usize,            // Which variant to call
        specificity: usize,              // For ordering
    };

    pub fn init(allocator: std.mem.Allocator, function_name: []const u8) DispatchTable {
        return .{
            .function_name = function_name,
            .entries = std.ArrayList(DispatchEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DispatchTable) void {
        for (self.entries.items) |*entry| {
            for (entry.signature) |type_name| {
                self.allocator.free(type_name);
            }
            self.allocator.free(entry.signature);
        }
        self.entries.deinit();
        self.allocator.free(self.function_name);
    }

    pub fn addEntry(
        self: *DispatchTable,
        signature: []const []const u8,
        variant_index: usize,
        specificity: usize,
    ) !void {
        try self.entries.append(.{
            .signature = signature,
            .variant_index = variant_index,
            .specificity = specificity,
        });
        
        // Sort by specificity (most specific first)
        std.sort.insertion(DispatchEntry, self.entries.items, {}, compareSpecificity);
    }

    fn compareSpecificity(_: void, a: DispatchEntry, b: DispatchEntry) bool {
        return a.specificity > b.specificity;
    }

    /// Find best matching variant for given argument types
    pub fn findMatch(self: *const DispatchTable, arg_types: []const []const u8) ?usize {
        for (self.entries.items) |entry| {
            if (entry.signature.len != arg_types.len) continue;
            
            var matches = true;
            for (entry.signature, arg_types) |sig_type, arg_type| {
                if (!typeMatches(sig_type, arg_type)) {
                    matches = false;
                    break;
                }
            }
            
            if (matches) {
                return entry.variant_index;
            }
        }
        return null;
    }

    fn typeMatches(signature_type: []const u8, argument_type: []const u8) bool {
        // Exact match
        if (std.mem.eql(u8, signature_type, argument_type)) {
            return true;
        }
        
        // TODO: Check subtype relationships, trait implementations, etc.
        return false;
    }
};

/// Dispatch resolver - determines which variant to call
pub const DispatchResolver = struct {
    allocator: std.mem.Allocator,
    dispatch_tables: std.StringHashMap(DispatchTable),

    pub fn init(allocator: std.mem.Allocator) DispatchResolver {
        return .{
            .allocator = allocator,
            .dispatch_tables = std.StringHashMap(DispatchTable).init(allocator),
        };
    }

    pub fn deinit(self: *DispatchResolver) void {
        var it = self.dispatch_tables.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.dispatch_tables.deinit();
    }

    /// Register a multi-dispatch function
    pub fn registerFunction(
        self: *DispatchResolver,
        multi_fn: *MultiDispatchFn,
    ) !void {
        var table = DispatchTable.init(self.allocator, multi_fn.name);
        
        for (multi_fn.variants, 0..) |variant, i| {
            const signature = try self.extractSignature(variant.params);
            const specificity = self.calculateSpecificity(variant.params);
            
            try table.addEntry(signature, i, specificity);
        }
        
        try self.dispatch_tables.put(multi_fn.name, table);
    }

    /// Resolve which variant to call for given argument types
    pub fn resolve(
        self: *const DispatchResolver,
        function_name: []const u8,
        arg_types: []const []const u8,
    ) ?usize {
        const table = self.dispatch_tables.get(function_name) orelse return null;
        return table.findMatch(arg_types);
    }

    fn extractSignature(self: *DispatchResolver, params: []const DispatchParam) ![]const []const u8 {
        var signature = try self.allocator.alloc([]const u8, params.len);
        
        for (params, 0..) |param, i| {
            signature[i] = switch (param.type_constraint) {
                .Concrete => |t| try self.allocator.dupe(u8, t),
                .Trait => |t| try self.allocator.dupe(u8, t),
                .Generic => |t| try self.allocator.dupe(u8, t),
                .Any => try self.allocator.dupe(u8, "Any"),
                .Union => try self.allocator.dupe(u8, "Union"),
            };
        }
        
        return signature;
    }

    fn calculateSpecificity(self: *DispatchResolver, params: []const DispatchParam) usize {
        _ = self;
        var specificity: usize = 0;
        
        for (params) |param| {
            specificity += switch (param.type_constraint) {
                .Concrete => 100,      // Most specific
                .Trait => 50,          // Medium specific
                .Union => 25,          // Less specific
                .Generic => 10,        // Generic
                .Any => 1,             // Least specific
            };
        }
        
        return specificity;
    }
};

/// Dispatch call site
/// Represents a call that needs runtime dispatch
pub const DispatchCall = struct {
    node: Node,
    function_name: []const u8,
    arguments: []const *Expr,
    resolved_variant: ?usize,  // Filled in during type checking

    pub fn init(
        function_name: []const u8,
        arguments: []const *Expr,
        loc: SourceLocation,
    ) DispatchCall {
        return .{
            .node = .{ .type = .DispatchCall, .loc = loc },
            .function_name = function_name,
            .arguments = arguments,
            .resolved_variant = null,
        };
    }

    pub fn deinit(self: *DispatchCall, allocator: std.mem.Allocator) void {
        allocator.free(self.function_name);
        for (self.arguments) |arg| {
            allocator.destroy(arg);
        }
        allocator.free(self.arguments);
    }
};

/// Dispatch ambiguity error
pub const DispatchAmbiguity = struct {
    function_name: []const u8,
    arg_types: []const []const u8,
    matching_variants: []const usize,
    loc: SourceLocation,

    pub fn format(self: *const DispatchAmbiguity, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "Ambiguous dispatch for function '{s}' with arguments ({s}). Matching variants: {any}",
            .{ self.function_name, self.arg_types, self.matching_variants },
        );
    }
};

/// Dispatch validator
pub const DispatchValidator = struct {
    /// Check for ambiguous dispatch
    pub fn checkAmbiguity(
        variants: []const MultiDispatchFn.FnVariant,
    ) !void {
        // Check if any two variants have overlapping signatures
        for (variants, 0..) |v1, i| {
            for (variants[i + 1 ..], i + 1..) |v2, _| {
                if (signaturesOverlap(v1.params, v2.params)) {
                    if (v1.specificity == v2.specificity) {
                        return error.AmbiguousDispatch;
                    }
                }
            }
        }
    }

    fn signaturesOverlap(
        params1: []const DispatchParam,
        params2: []const DispatchParam,
    ) bool {
        if (params1.len != params2.len) return false;
        
        for (params1, params2) |p1, p2| {
            if (!typesOverlap(p1.type_constraint, p2.type_constraint)) {
                return false;
            }
        }
        
        return true;
    }

    fn typesOverlap(
        t1: DispatchParam.TypeConstraint,
        t2: DispatchParam.TypeConstraint,
    ) bool {
        // Simplified overlap check
        return switch (t1) {
            .Any => true,
            .Concrete => |c1| switch (t2) {
                .Any => true,
                .Concrete => |c2| std.mem.eql(u8, c1, c2),
                else => false,
            },
            else => false,
        };
    }

    /// Validate that all variants are compatible
    pub fn validateVariants(
        variants: []const MultiDispatchFn.FnVariant,
    ) !void {
        if (variants.len == 0) {
            return error.NoVariants;
        }

        // Check return type compatibility
        const first_return = variants[0].return_type;
        for (variants[1..]) |variant| {
            if (first_return) |fr| {
                if (variant.return_type) |vr| {
                    if (!std.mem.eql(u8, fr, vr)) {
                        // Different return types - might be OK if they share a common supertype
                        // For now, we'll allow it
                    }
                }
            }
        }
    }
};

/// Dispatch patterns
pub const DispatchPattern = enum {
    /// fn(Circle, Circle)
    ConcreteTypes,
    
    /// fn(T: Shape, U: Shape)
    TraitBounds,
    
    /// fn(T, T) - Same type
    SameType,
    
    /// fn(Circle | Rectangle, Shape)
    UnionTypes,
    
    /// fn(Any, Any)
    AnyTypes,

    pub fn toString(self: DispatchPattern) []const u8 {
        return switch (self) {
            .ConcreteTypes => "concrete_types",
            .TraitBounds => "trait_bounds",
            .SameType => "same_type",
            .UnionTypes => "union_types",
            .AnyTypes => "any_types",
        };
    }
};
