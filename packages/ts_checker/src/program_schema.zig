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
pub const Function = struct { parameters: []const Element, result: *const Expression };
pub const Reference = struct { declaration: *const Declaration, arguments: []const *const Expression };
pub const Expression = union(enum) {
    primitive: types.TypeId,
    parameter: *const Parameter,
    string: []const u8,
    number: f64,
    boolean: bool,
    array: *const Expression,
    readonly_array: *const Expression,
    object: []const Member,
    tuple: []const Element,
    union_type: []const *const Expression,
    intersection: []const *const Expression,
    function: Function,
    reference: Reference,
    unsupported,
};

pub const Declaration = struct {
    path: []const u8,
    position: u32,
    name: []const u8,
    parameters: []Parameter = &.{},
    body: ?*const Expression = null,
    is_class: bool = false,
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
};
