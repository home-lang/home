//! Source-owned declaration type expressions, independent of consumer HIR IDs.
//! Parameter and declaration references use identities, never global spellings.
const std = @import("std");
const types = @import("types.zig");
pub const Primitive = types.Primitive;
/// Source projectors decode raw parser text before creating semantic strings.
pub const appendCookedStringText = @import("string_literal.zig").appendCookedStringText;

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
    /// The setter parameter type for a paired accessor. Reads use `type`.
    write_type: ?*const Expression = null,
    optional: bool = false,
    readonly: bool = false,
    method: bool = false,
    visibility: types.MemberVisibility = .public,
};

pub const Element = struct { type: *const Expression, name: ?[]const u8 = null, optional: bool = false, rest: bool = false };
pub const TypePredicate = struct { param_index: u16, target: *const Expression, is_asserts: bool };
pub const Function = struct {
    type_parameters: []Parameter = &.{},
    parameters: []const Element,
    result: *const Expression,
    this_type: ?*const Expression = null,
    predicate: ?TypePredicate = null,
    is_construct: bool = false,
    has_literal_types: bool = false,
    construct_visibility: types.MemberVisibility = .public,
};
pub const Reference = struct {
    declaration: *const Declaration,
    arguments: []const *const Expression,
    projection_only: bool = false,
    /// This edge is retained solely to contextually type a callable input.
    /// Its target may contain source-owned utility machinery that is not
    /// admissible as the importing file's general-purpose type.
    contextual_projection: bool = false,
    /// Resolve individual readable members from the source declaration on
    /// demand. This is used for filtered homomorphic return types whose whole
    /// mapped/conditional object must not be materialized across checker
    /// pools.
    contextual_deferred_read: bool = false,
    /// Proven source expression whose complete readable-key surface survives
    /// this contextual utility projection.
    contextual_read: ?*const Expression = null,
    /// Source keys made optional by the contextual utility projection.
    contextual_read_optional_keys: ?*const Expression = null,
    /// The contextual utility projection makes every source key optional.
    contextual_read_optional_all: bool = false,
    /// Structurally preserved open string-index value contributed by an
    /// intersection such as `Record<string, unknown>`.
    contextual_read_string_index: ?*const Expression = null,
};
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
pub const IndexSignature = struct { name: []const u8 = "", key: *const Expression, value: *const Expression, readonly: bool = false };
pub const IndexedObject = struct { members: []const Member, indices: []const IndexSignature };
pub const Record = struct { key: *const Expression, value: *const Expression, readonly: bool = false };
pub const UtilityKind = enum { partial, required, readonly, pick, omit, extract, exclude };
pub const Utility = struct {
    kind: UtilityKind,
    source: *const Expression,
    keys: ?*const Expression = null,
};

pub const BuiltinReference = struct {
    name: []const u8,
    arguments: []const *const Expression,
};

/// Standard-library object identities that can be materialized in every
/// checker from their stable spelling instead of copying source-owned TypeIds.
pub const builtin_object_type_names = [_][]const u8{
    "Animation",        "ArrayBuffer",         "ArrayBufferView",
    "AsyncGenerator",   "AsyncIterable",       "AsyncIterableIterator",
    "AsyncIterator",    "AsyncIteratorObject", "BigInt64Array",
    "BigUint64Array",   "Boolean",             "Date",
    "Document",         "Element",             "Error",
    "ErrorConstructor", "Event",               "Float16Array",
    "Float32Array",     "Float64Array",        "Function",
    "Generator",        "HTMLElement",         "Int16Array",
    "Int32Array",       "Int8Array",           "Iterable",
    "IterableIterator", "Iterator",            "IteratorObject",
    "Node",             "Number",              "Object",
    "PromiseLike",      "RangeError",          "RegExp",
    "RegExpExecArray",  "RegExpMatchArray",    "SharedArrayBuffer",
    "SyntaxError",      "TypeError",           "Uint16Array",
    "Uint32Array",      "Uint8Array",          "Uint8ClampedArray",
    "Window",           "Worker",
};

/// Standard-library generic identities whose concrete instantiations can be
/// reconstructed from type arguments in every consuming checker.
pub const builtin_generic_type_names = [_][]const u8{
    "AsyncGenerator",
    "Generator",
    "Map",
    "Promise",
    "PromiseLike",
    "ReadonlyMap",
    "ReadonlySet",
    "Set",
    "WeakMap",
    "WeakSet",
};

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
    /// A parameterized standard-library type. The symbolic identity and its
    /// source-owned arguments cross the Program boundary together; the
    /// consumer reconstructs its canonical local instantiation.
    builtin_reference: BuiltinReference,
    parameter: *const Parameter,
    string: []const u8,
    number: f64,
    boolean: bool,
    array: *const Expression,
    readonly_array: *const Expression,
    object: []const Member,
    /// A source class's constructor value. Its inferred name belongs to the
    /// value, including when that value is nested inside a union.
    class_value: struct { name: []const u8, members: []const Member },
    indexed_object: IndexedObject,
    record: Record,
    utility: Utility,
    tuple: []const Element,
    union_type: []const *const Expression,
    intersection: []const *const Expression,
    function: Function,
    reference: Reference,
    /// Implicit derived constructors retain the source-owned base class and
    /// its type arguments, independently of the derived instance surface.
    inherited_constructors: Reference,
    indexed_access: IndexedAccess,
    keyof: *const Expression,
    conditional: Conditional,
    mapped: Mapped,
    infer: *const Parameter,
    /// The polymorphic `this` keyword used in method return and parameter
    /// types. This is distinct from the `ThisType<T>` contextual marker.
    polymorphic_this,
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
    /// Constructor parameter graphs are independent of the instance surface.
    /// Their placeholder return type is replaced with the imported instance.
    constructors: ?*const Expression = null,
    is_abstract_class: bool = false,
    is_interface: bool = false,
    /// Own members remain distinct from heritage when collecting overloads.
    /// This expression is also reachable through `body`.
    interface_own_body: ?*const Expression = null,
    is_function: bool = false,
    /// Keep a class constructor value distinct from its instance declaration.
    value_side: bool = false,
    /// This declaration preserves a callable shell by degrading at least one
    /// untransferable leaf. It is valid only as contextual function input.
    contextual_only: bool = false,
    /// Set only on a checker-local copy reached through a contextual edge.
    /// It permits exact utility/index scaffolding while keeping unsupported
    /// object-property leaves opaque.
    contextual_projection: bool = false,
};

pub const Schema = struct {
    /// Owns the expression graph. Paths and string bytes remain borrowed from
    /// the prepared source owners, which must outlive this schema.
    arena: std.heap.ArenaAllocator,
    declaration: *const Declaration,
    shared_graph: ?*SharedGraph = null,

    pub const SharedGraph = struct {
        arena: std.heap.ArenaAllocator,
        references: usize = 1,

        pub fn release(self: *SharedGraph, gpa: std.mem.Allocator) void {
            std.debug.assert(self.references > 0);
            self.references -= 1;
            if (self.references == 0) {
                self.arena.deinit();
                gpa.destroy(self);
            }
        }
    };

    pub fn deinit(self: *Schema, gpa: std.mem.Allocator) void {
        if (self.shared_graph) |graph| graph.release(gpa) else self.arena.deinit();
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

    /// Closed primitive domains and finite property literals have exact
    /// concrete representations. Symbolic domains still need mapped lowering;
    /// finite keys must never be widened into an open index signature.
    pub fn recordIndexKeySupported(key: *const Expression, gpa: std.mem.Allocator) !bool {
        var visited: std.AutoHashMapUnmanaged(*const Expression, void) = .empty;
        defer visited.deinit(gpa);
        var active_parameters: std.AutoHashMapUnmanaged(*const Parameter, void) = .empty;
        defer active_parameters.deinit(gpa);
        var bindings: std.AutoHashMapUnmanaged(*const Parameter, *const Expression) = .empty;
        defer bindings.deinit(gpa);
        return recordKeySupported(key, gpa, &visited, &active_parameters, &bindings);
    }

    fn recordKeySupported(
        key: *const Expression,
        gpa: std.mem.Allocator,
        visited: *std.AutoHashMapUnmanaged(*const Expression, void),
        active_parameters: *std.AutoHashMapUnmanaged(*const Parameter, void),
        bindings: *std.AutoHashMapUnmanaged(*const Parameter, *const Expression),
    ) !bool {
        const entry = try visited.getOrPut(gpa, key);
        if (entry.found_existing) return false;
        defer _ = visited.remove(key);
        return switch (key.*) {
            .primitive => |primitive| primitive == types.Primitive.any or
                primitive == types.Primitive.string_t or
                primitive == types.Primitive.number_t or
                primitive == types.Primitive.symbol_t or
                primitive == types.Primitive.never,
            .string, .number => true,
            .union_type => |members| blk: {
                for (members) |member| if (!try recordKeySupported(member, gpa, visited, active_parameters, bindings)) break :blk false;
                break :blk true;
            },
            .parameter => |parameter| blk: {
                const parameter_entry = try active_parameters.getOrPut(gpa, parameter);
                if (parameter_entry.found_existing) break :blk false;
                defer _ = active_parameters.remove(parameter);
                const value = bindings.get(parameter) orelse parameter.constraint orelse break :blk false;
                break :blk try recordKeySupported(value, gpa, visited, active_parameters, bindings);
            },
            .reference => |reference| blk: {
                if (reference.projection_only or reference.contextual_projection or
                    reference.declaration.contextual_only or reference.declaration.is_class or reference.declaration.is_function)
                    break :blk false;
                if (reference.arguments.len > reference.declaration.parameters.len) break :blk false;
                const body = reference.declaration.body orelse break :blk false;
                var nested: std.AutoHashMapUnmanaged(*const Parameter, *const Expression) = .empty;
                defer nested.deinit(gpa);
                var binding_iterator = bindings.iterator();
                while (binding_iterator.next()) |binding| try nested.put(gpa, binding.key_ptr.*, binding.value_ptr.*);
                for (reference.declaration.parameters, 0..) |*parameter, index| {
                    const value = if (index < reference.arguments.len)
                        reference.arguments[index]
                    else
                        parameter.default orelse break :blk false;
                    try nested.put(gpa, parameter, value);
                }
                break :blk try recordKeySupported(body, gpa, visited, active_parameters, &nested);
            },
            else => false,
        };
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
                .primitive, .builtin_object, .parameter, .string, .number, .boolean, .polymorphic_this => {},
                .builtin_reference => |reference| try pending.appendSlice(gpa, reference.arguments),
                .array, .readonly_array, .keyof, .this_type => |element| try pending.append(gpa, element),
                .object => |members| for (members) |member| {
                    try pending.append(gpa, member.type);
                    if (member.write_type) |write_type| try pending.append(gpa, write_type);
                },
                .class_value => |value| for (value.members) |member| {
                    try pending.append(gpa, member.type);
                    if (member.write_type) |write_type| try pending.append(gpa, write_type);
                },
                .indexed_object => |object| {
                    for (object.members) |member| {
                        try pending.append(gpa, member.type);
                        if (member.write_type) |write_type| try pending.append(gpa, write_type);
                    }
                    for (object.indices) |index| {
                        try pending.append(gpa, index.key);
                        try pending.append(gpa, index.value);
                    }
                },
                .record => |record| {
                    if ((allow_readonly_record and record.readonly) or try recordIndexKeySupported(record.key, gpa)) {
                        try pending.append(gpa, record.key);
                        try pending.append(gpa, record.value);
                    } else if (!allow_opaque) {
                        return false;
                    }
                },
                .utility => |utility| {
                    if (utility.kind != .extract and utility.kind != .exclude and utility.kind != .pick and utility.kind != .omit and !allow_opaque) return false;
                    try pending.append(gpa, utility.source);
                    if (utility.keys) |keys| try pending.append(gpa, keys);
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
                    if (ref.contextual_projection) {
                        if (!allow_opaque) return false;
                        try pending.appendSlice(gpa, ref.arguments);
                        if (ref.contextual_read) |read| try pending.append(gpa, read);
                        continue;
                    }
                    if (ref.projection_only and !allow_opaque) return false;
                    try appendDeclaration(gpa, pending, ref.declaration);
                    try pending.appendSlice(gpa, ref.arguments);
                },
                .inherited_constructors => |ref| {
                    if (!ref.declaration.is_class or ref.arguments.len > ref.declaration.parameters.len) return false;
                    for (ref.declaration.parameters[ref.arguments.len..]) |parameter| {
                        const default = parameter.default orelse return false;
                        try pending.append(gpa, default);
                    }
                    const constructors = ref.declaration.constructors orelse return false;
                    try pending.append(gpa, constructors);
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
        if (declaration.interface_own_body) |own| try pending.append(gpa, own);
        for (declaration.parameters) |param| {
            if (param.constraint) |constraint| try pending.append(gpa, constraint);
            if (param.default) |default| try pending.append(gpa, default);
        }
    }
};
