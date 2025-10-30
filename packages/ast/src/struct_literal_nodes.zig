const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeType = ast.NodeType;
const SourceLocation = ast.SourceLocation;
const Expr = ast.Expr;

/// Struct literal expression
/// Supports both explicit and shorthand field initialization
pub const StructLiteralExpr = struct {
    node: Node,
    type_name: []const u8,
    fields: []const FieldInit,
    is_anonymous: bool,  // true for anonymous structs

    pub fn init(
        type_name: []const u8,
        fields: []const FieldInit,
        is_anonymous: bool,
        loc: SourceLocation,
    ) StructLiteralExpr {
        return .{
            .node = .{ .type = .StructLiteral, .loc = loc },
            .type_name = type_name,
            .fields = fields,
            .is_anonymous = is_anonymous,
        };
    }

    pub fn deinit(self: *StructLiteralExpr, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        for (self.fields) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.fields);
    }
};

/// Field initialization in struct literal
pub const FieldInit = struct {
    name: []const u8,
    value: *Expr,
    is_shorthand: bool,  // true if using shorthand syntax (field instead of field: field)
    loc: SourceLocation,

    pub fn init(
        name: []const u8,
        value: *Expr,
        is_shorthand: bool,
        loc: SourceLocation,
    ) FieldInit {
        return .{
            .name = name,
            .value = value,
            .is_shorthand = is_shorthand,
            .loc = loc,
        };
    }

    pub fn deinit(self: *FieldInit, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (!self.is_shorthand) {
            allocator.destroy(self.value);
        }
    }
};

/// Struct update syntax (..other_struct)
pub const StructUpdate = struct {
    base: *Expr,
    fields: []const FieldInit,
    loc: SourceLocation,

    pub fn init(
        base: *Expr,
        fields: []const FieldInit,
        loc: SourceLocation,
    ) StructUpdate {
        return .{
            .base = base,
            .fields = fields,
            .loc = loc,
        };
    }

    pub fn deinit(self: *StructUpdate, allocator: std.mem.Allocator) void {
        allocator.destroy(self.base);
        for (self.fields) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.fields);
    }
};

/// Tuple struct literal
pub const TupleStructLiteral = struct {
    node: Node,
    type_name: []const u8,
    values: []const *Expr,

    pub fn init(
        type_name: []const u8,
        values: []const *Expr,
        loc: SourceLocation,
    ) TupleStructLiteral {
        return .{
            .node = .{ .type = .TupleStructLiteral, .loc = loc },
            .type_name = type_name,
            .values = values,
        };
    }

    pub fn deinit(self: *TupleStructLiteral, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        for (self.values) |val| {
            allocator.destroy(val);
        }
        allocator.free(self.values);
    }
};

/// Anonymous struct literal
pub const AnonymousStruct = struct {
    node: Node,
    fields: []const FieldInit,

    pub fn init(
        fields: []const FieldInit,
        loc: SourceLocation,
    ) AnonymousStruct {
        return .{
            .node = .{ .type = .AnonymousStruct, .loc = loc },
            .fields = fields,
        };
    }

    pub fn deinit(self: *AnonymousStruct, allocator: std.mem.Allocator) void {
        for (self.fields) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.fields);
    }
};

/// Field punning validator
pub const FieldPunning = struct {
    /// Check if a field can use shorthand syntax
    pub fn canUseShorthand(field_name: []const u8, value_expr: *Expr) bool {
        // Shorthand is valid if the value is an identifier with the same name
        return switch (value_expr.*) {
            .Identifier => |id| std.mem.eql(u8, id.name, field_name),
            else => false,
        };
    }

    /// Suggest shorthand for a field
    pub fn suggestShorthand(field_name: []const u8, value_expr: *Expr) ?[]const u8 {
        if (canUseShorthand(field_name, value_expr)) {
            return field_name;
        }
        return null;
    }
};

/// Struct literal patterns
pub const StructLiteralPattern = enum {
    /// User { name: name, age: age }
    Explicit,
    
    /// User { name, age }
    Shorthand,
    
    /// User { name, age: 25 }
    Mixed,
    
    /// User { ..other }
    Update,
    
    /// User { name, ..other }
    UpdateWithFields,
    
    /// .{ x: 10, y: 20 }
    Anonymous,
    
    /// Point(10, 20)
    Tuple,

    pub fn toString(self: StructLiteralPattern) []const u8 {
        return switch (self) {
            .Explicit => "explicit",
            .Shorthand => "shorthand",
            .Mixed => "mixed",
            .Update => "update",
            .UpdateWithFields => "update_with_fields",
            .Anonymous => "anonymous",
            .Tuple => "tuple",
        };
    }
};

/// Struct literal builder helper
pub const StructLiteralBuilder = struct {
    allocator: std.mem.Allocator,
    type_name: ?[]const u8,
    fields: std.ArrayList(FieldInit),

    pub fn init(allocator: std.mem.Allocator, type_name: ?[]const u8) StructLiteralBuilder {
        return .{
            .allocator = allocator,
            .type_name = type_name,
            .fields = std.ArrayList(FieldInit).init(allocator),
        };
    }

    pub fn deinit(self: *StructLiteralBuilder) void {
        self.fields.deinit();
    }

    pub fn addField(
        self: *StructLiteralBuilder,
        name: []const u8,
        value: *Expr,
        is_shorthand: bool,
        loc: SourceLocation,
    ) !void {
        try self.fields.append(FieldInit.init(name, value, is_shorthand, loc));
    }

    pub fn addShorthand(
        self: *StructLiteralBuilder,
        name: []const u8,
        loc: SourceLocation,
    ) !void {
        // Create identifier expression for shorthand
        const id_expr = try self.allocator.create(Expr);
        id_expr.* = .{ .Identifier = .{
            .node = .{ .type = .Identifier, .loc = loc },
            .name = name,
        }};
        
        try self.addField(name, id_expr, true, loc);
    }

    pub fn build(self: *StructLiteralBuilder, loc: SourceLocation) !StructLiteralExpr {
        const type_name = self.type_name orelse "";
        const is_anonymous = self.type_name == null;
        
        return StructLiteralExpr.init(
            type_name,
            try self.fields.toOwnedSlice(self.allocator),
            is_anonymous,
            loc,
        );
    }
};
