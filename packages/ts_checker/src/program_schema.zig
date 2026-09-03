//! Source-owned declaration type expressions, independent of consumer HIR IDs.
//! Parameter and declaration references use identities, never global spellings.
const std = @import("std");
const types = @import("types.zig");
pub const Primitive = types.Primitive;

pub const Parameter = struct {
    name: []const u8,
    constraint: ?*const Expression = null,
    default: ?*const Expression = null,
    variance: u8 = 0,
    is_const: bool = false,
};

pub const Member = struct {
    name: []const u8,
    type: *const Expression,
    optional: bool = false,
    readonly: bool = false,
    method: bool = false,
    visibility: types.MemberVisibility = .public,
};

pub const Element = struct { type: *const Expression, optional: bool = false, rest: bool = false };
pub const TypePredicate = struct { param_index: u16, target: *const Expression, is_asserts: bool };
pub const Function = struct {
    type_parameters: []Parameter = &.{},
    parameters: []const Element,
    result: *const Expression,
    this_type: ?*const Expression = null,
    predicate: ?TypePredicate = null,
    is_construct: bool = false,
};
pub const Reference = struct { declaration: *const Declaration, arguments: []const *const Expression };
pub const IndexedAccess = struct { object: *const Expression, index: *const Expression };
pub const Conditional = struct {
    check: *const Expression,
    extends_type: *const Expression,
    true_branch: *const Expression,
    false_branch: *const Expression,
};
pub const Mapped = struct {
    parameter: *const Parameter,
    constraint: *const Expression,
    template: *const Expression,
    readonly: u8,
    optional: u8,
};
pub const IndexSignature = struct { key: *const Expression, value: *const Expression };
pub const IndexedObject = struct { members: []const Member, indices: []const IndexSignature };
pub const Record = struct { key: *const Expression, value: *const Expression, readonly: bool = false };
pub const Expression = union(enum) {
    primitive: types.TypeId,
    /// A deliberately opaque leaf in an otherwise transferable declaration.
    /// Consumers lower it to `any`, retaining safe outer structure such as a
    /// contextual function signature without inventing the leaf shape.
    opaque_leaf,
    /// A standard-library object type whose concrete shape is owned by the
    /// consuming checker. Keeping the symbolic name avoids copying checker
    /// TypeIds across source-file type pools.
    builtin_object: []const u8,
    parameter: *const Parameter,
    string: []const u8,
    number: f64,
    boolean: bool,
    array: *const Expression,
    readonly_array: *const Expression,
    object: []const Member,
    indexed_object: IndexedObject,
    record: Record,
    tuple: []const Element,
    union_type: []const *const Expression,
    intersection: []const *const Expression,
    function: Function,
    reference: Reference,
    indexed_access: IndexedAccess,
    keyof: *const Expression,
    conditional: Conditional,
    mapped: Mapped,
    infer: *const Parameter,
    this_type: *const Expression,
    typeof_class: *const Declaration,
    unsupported,
};

pub const Declaration = struct {
    path: []const u8,
    position: u32,
    name: []const u8,
    parameters: []Parameter = &.{},
    body: ?*const Expression = null,
    is_class: bool = false,
    is_function: bool = false,
    /// This declaration preserves a callable shell by degrading at least one
    /// untransferable leaf. It is valid only as contextual function input.
    contextual_only: bool = false,
};

pub const Schema = struct {
    /// Owns the expression graph. Paths and string bytes remain borrowed from
    /// the prepared source owners, which must outlive this schema.
    arena: std.heap.ArenaAllocator,
    declaration: *const Declaration,

    pub fn deinit(self: *Schema, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Keep unsupported projections out of the concrete instantiator. Walk
    /// declaration graphs by identity, so recursive aliases terminate without
    /// truncating their bodies or imposing an arbitrary depth limit.
    pub fn isSupported(self: *const Schema, gpa: std.mem.Allocator) !bool {
        return declarationSupported(self.declaration, gpa);
    }

    pub fn declarationSupported(declaration: *const Declaration, gpa: std.mem.Allocator) !bool {
        var pending: std.ArrayListUnmanaged(*const Expression) = .empty;
        defer pending.deinit(gpa);
        var visited: std.AutoHashMapUnmanaged(*const Expression, void) = .empty;
        defer visited.deinit(gpa);
        try appendDeclaration(gpa, &pending, declaration);
        return pendingSupported(gpa, &pending, &visited, declaration.contextual_only, declaration.is_function);
    }

    /// Check one prospective leaf before it is embedded in a larger schema.
    /// This uses the same identity-aware traversal as whole declarations.
    pub fn expressionSupported(expression: *const Expression, gpa: std.mem.Allocator) !bool {
        var pending: std.ArrayListUnmanaged(*const Expression) = .empty;
        defer pending.deinit(gpa);
        var visited: std.AutoHashMapUnmanaged(*const Expression, void) = .empty;
        defer visited.deinit(gpa);
        try pending.append(gpa, expression);
        return pendingSupported(gpa, &pending, &visited, false, false);
    }

    fn pendingSupported(
        gpa: std.mem.Allocator,
        pending: *std.ArrayListUnmanaged(*const Expression),
        visited: *std.AutoHashMapUnmanaged(*const Expression, void),
        allow_opaque: bool,
        allow_readonly_record: bool,
    ) !bool {
        while (pending.pop()) |expr| {
            const entry = try visited.getOrPut(gpa, expr);
            if (entry.found_existing) continue;
            switch (expr.*) {
                .unsupported => if (!allow_opaque) return false,
                .opaque_leaf => if (!allow_opaque) return false,
                .primitive, .builtin_object, .parameter, .string, .number, .boolean => {},
                .array, .readonly_array, .keyof, .this_type => |element| try pending.append(gpa, element),
                .object => |members| for (members) |member| {
                    try pending.append(gpa, member.type);
                },
                .indexed_object => |object| {
                    for (object.members) |member| try pending.append(gpa, member.type);
                    for (object.indices) |index| {
                        try pending.append(gpa, index.key);
                        try pending.append(gpa, index.value);
                    }
                },
                .record => |record| {
                    if (allow_readonly_record and record.readonly) {
                        try pending.append(gpa, record.key);
                        try pending.append(gpa, record.value);
                    } else if (!allow_opaque) {
                        return false;
                    }
                },
                .tuple => |elements| for (elements) |element| {
                    try pending.append(gpa, element.type);
                },
                .union_type, .intersection => |members| try pending.appendSlice(gpa, members),
                .function => |function| {
                    for (function.type_parameters) |parameter| {
                        if (parameter.constraint) |constraint| try pending.append(gpa, constraint);
                        if (parameter.default) |default| try pending.append(gpa, default);
                    }
                    if (function.this_type) |receiver| try pending.append(gpa, receiver);
                    for (function.parameters) |param| try pending.append(gpa, param.type);
                    try pending.append(gpa, function.result);
                    if (function.predicate) |predicate| try pending.append(gpa, predicate.target);
                },
                .reference => |ref| {
                    try appendDeclaration(gpa, pending, ref.declaration);
                    try pending.appendSlice(gpa, ref.arguments);
                },
                .indexed_access => |indexed| {
                    try pending.append(gpa, indexed.object);
                    try pending.append(gpa, indexed.index);
                },
                .conditional => |conditional| {
                    try pending.append(gpa, conditional.check);
                    try pending.append(gpa, conditional.extends_type);
                    try pending.append(gpa, conditional.true_branch);
                    try pending.append(gpa, conditional.false_branch);
                },
                .mapped => |mapped| {
                    try pending.append(gpa, mapped.constraint);
                    try pending.append(gpa, mapped.template);
                },
                .infer => |parameter| {
                    if (parameter.constraint) |constraint| try pending.append(gpa, constraint);
                },
                .typeof_class => |class_declaration| try appendDeclaration(gpa, pending, class_declaration),
            }
        }
        return true;
    }

    fn appendDeclaration(gpa: std.mem.Allocator, pending: *std.ArrayListUnmanaged(*const Expression), declaration: *const Declaration) !void {
        if (declaration.body) |body| try pending.append(gpa, body);
        for (declaration.parameters) |param| {
            if (param.constraint) |constraint| try pending.append(gpa, constraint);
            if (param.default) |default| try pending.append(gpa, default);
        }
    }
};
