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
pub const Function = struct { parameters: []const Element, result: *const Expression, this_type: ?*const Expression = null };
pub const Reference = struct { declaration: *const Declaration, arguments: []const *const Expression };
pub const IndexedAccess = struct { object: *const Expression, index: *const Expression };
pub const IndexSignature = struct { key: *const Expression, value: *const Expression };
pub const IndexedObject = struct { members: []const Member, indices: []const IndexSignature };
pub const Expression = union(enum) {
    primitive: types.TypeId,
    parameter: *const Parameter,
    string: []const u8,
    number: f64,
    boolean: bool,
    array: *const Expression,
    readonly_array: *const Expression,
    object: []const Member,
    indexed_object: IndexedObject,
    tuple: []const Element,
    union_type: []const *const Expression,
    intersection: []const *const Expression,
    function: Function,
    reference: Reference,
    indexed_access: IndexedAccess,
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
        while (pending.pop()) |expr| {
            const entry = try visited.getOrPut(gpa, expr);
            if (entry.found_existing) continue;
            switch (expr.*) {
                .unsupported => return false,
                .primitive, .parameter, .string, .number, .boolean => {},
                .array, .readonly_array => |element| try pending.append(gpa, element),
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
                .tuple => |elements| for (elements) |element| {
                    try pending.append(gpa, element.type);
                },
                .union_type, .intersection => |members| try pending.appendSlice(gpa, members),
                .function => |function| {
                    if (function.this_type) |receiver| try pending.append(gpa, receiver);
                    for (function.parameters) |param| try pending.append(gpa, param.type);
                    try pending.append(gpa, function.result);
                },
                .reference => |ref| {
                    try appendDeclaration(gpa, &pending, ref.declaration);
                    try pending.appendSlice(gpa, ref.arguments);
                },
                .indexed_access => |indexed| {
                    try pending.append(gpa, indexed.object);
                    try pending.append(gpa, indexed.index);
                },
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
