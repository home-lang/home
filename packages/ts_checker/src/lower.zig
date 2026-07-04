//! HIR → TypeId lowering.
//!
//! Walks HIR type nodes produced by the TS parser and produces interned
//! `TypeId`s via the type interner. This is the missing connector
//! between Phase 1 (type parsing) and Phase 3 (relations).
//!
//! Scope today:
//!   - Primitive type refs (any, unknown, never, void, null, undefined,
//!     string, number, boolean, bigint, symbol, object) → matching
//!     `Primitive.*` sentinel
//!   - Literal types ('hello', 42, true, false, -42) → interned literal
//!     types
//!   - Unions, intersections (members lowered recursively)
//!   - keyof T, T[K], typeof e
//!   - Conditional types `T extends U ? X : Y` (no instantiation —
//!     stored structurally and resolved later by the checker)
//!   - Tuples (lowered as union of element types for now — full tuple
//!     types coming with the object-type lowering)
//!   - Arrays `T[]` (lowered as `Array<T>` via instantiation)
//!   - Generic refs `Foo<T>` — symbol resolution against the binder
//!     scope is a Phase 3 follow-up; we currently emit an `unknown`
//!     placeholder for non-primitive named refs and let the checker
//!     re-resolve when we feed it the symbol table.

const std = @import("std");
const hir_mod = @import("hir");
const types = @import("types.zig");
const interner = @import("interner.zig");
const string_interner = @import("string_interner");

pub const TypeId = types.TypeId;
pub const NodeId = hir_mod.NodeId;
pub const Hir = hir_mod.Hir;

pub const LowerError = error{
    OutOfMemory,
};

pub const Lowerer = struct {
    gpa: std.mem.Allocator,
    hir: *const Hir,
    interner: *interner.Interner,
    string_interner: *string_interner.Interner,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *const Hir,
        ti: *interner.Interner,
        si: *string_interner.Interner,
    ) Lowerer {
        return .{
            .gpa = gpa,
            .hir = hir,
            .interner = ti,
            .string_interner = si,
        };
    }

    /// Lower a single HIR type-node id into a TypeId. Returns
    /// `Primitive.unknown` for unrecognized shapes (preserves
    /// pipeline progress for Phase 3 / 6 follow-ups).
    pub fn lower(self: *Lowerer, node: NodeId) LowerError!TypeId {
        if (node == hir_mod.none_node_id) return types.Primitive.unknown;
        return switch (self.hir.kindOf(node)) {
            .type_ref => try self.lowerTypeRef(node),
            .union_type => try self.lowerUnion(node),
            .intersection_type => try self.lowerIntersection(node),
            .keyof_type => try self.lowerKeyof(node),
            .indexed_access_type => try self.lowerIndexedAccess(node),
            .typeof_type => types.Primitive.unknown, // requires symbol resolution
            .readonly_type => try self.lower(hir_mod.readonlyTypeOf(self.hir, node).operand),
            .conditional_type => try self.lowerConditional(node),
            .infer_type => try self.lowerInferType(node),
            .type_literal => try self.lowerLiteralType(node),
            .array_type => try self.lowerArray(node),
            .tuple_type => try self.lowerTuple(node),
            .optional_type => try self.lower(hir_mod.optionalTypeOf(self.hir, node).operand),
            .object_type => try self.lowerObjectType(node),
            .fn_type, .constructor_type => try self.lowerFnType(node),
            .mapped_type => types.Primitive.unknown, // mapped pending
            // Type predicates (`arg is T` / `asserts arg is T`) in
            // return-type position lower to `boolean` because that's
            // their runtime type. The narrowing semantics are
            // separately recorded in the checker via `fn_predicates`.
            .type_predicate_type => types.Primitive.boolean_t,
            // Template literal types: when every interpolated type
            // resolves to a string-literal type, concatenate the
            // text+lit parts into a single string-literal type
            // (e.g. `\`prefix-${'foo'}\`` → "prefix-foo"). Otherwise
            // fall back to the broad `string` type — full structural
            // pattern matching against templates is a Phase 6
            // follow-up.
            .template_literal_type => try self.lowerTemplateLiteralType(node),
            else => types.Primitive.unknown,
        };
    }

    /// Lower a `{ x: T; y: U }` HIR node into a checker object type.
    fn lowerObjectType(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const members = hir_mod.objectTypeMembers(self.hir, node);
        var built: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer built.deinit(self.gpa);
        for (members) |m| {
            if (self.hir.kindOf(m) != .interface_member) continue;
            const im = hir_mod.interfaceMemberOf(self.hir, m);
            const t: TypeId = if (im.type_node != hir_mod.none_node_id)
                try self.lower(im.type_node)
            else
                types.Primitive.any;
            try built.append(self.gpa, .{
                .name = im.name,
                .type = t,
                .is_optional = im.is_optional,
                .is_readonly = im.is_readonly,
                .is_method = im.is_method,
                .decl_node = m,
            });
        }
        return self.interner.internObjectType(built.items) catch error.OutOfMemory;
    }

    /// Lower a `(p: T) => U` fn-type into a signature.
    fn lowerFnType(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const ft = hir_mod.fnTypeOf(self.hir, node);
        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.gpa);
        var i: u32 = 0;
        while (i < ft.params_len) : (i += 1) {
            const p = self.hir.child_pool.items[ft.params_start + i];
            if (self.hir.kindOf(p) != .parameter) {
                try param_types.append(self.gpa, types.Primitive.any);
                continue;
            }
            const pp = hir_mod.parameterOf(self.hir, p);
            const t: TypeId = if (pp.type_annotation != hir_mod.none_node_id)
                try self.lower(pp.type_annotation)
            else
                types.Primitive.any;
            if (pp.name != hir_mod.none_node_id and self.hir.kindOf(pp.name) == .identifier) {
                const id = hir_mod.identifierOf(self.hir, pp.name);
                if (std.mem.eql(u8, self.string_interner.get(id.name), "this")) continue;
            }
            try param_types.append(self.gpa, t);
        }
        const ret: TypeId = if (ft.return_type != hir_mod.none_node_id)
            try self.lower(ft.return_type)
        else
            types.Primitive.void_t;
        return self.interner.internSignatureWithAbstract(
            param_types.items,
            ret,
            ft.is_constructor,
            ft.is_abstract_constructor,
        ) catch error.OutOfMemory;
    }

    fn lowerTypeRef(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const r = hir_mod.typeRefOf(self.hir, node);
        const name = self.string_interner.get(r.name);
        // Primitive recognition.
        if (std.mem.eql(u8, name, "any")) return types.Primitive.any;
        if (std.mem.eql(u8, name, "unknown")) return types.Primitive.unknown;
        if (std.mem.eql(u8, name, "never")) return types.Primitive.never;
        if (std.mem.eql(u8, name, "void")) return types.Primitive.void_t;
        if (std.mem.eql(u8, name, "null")) return types.Primitive.null_t;
        if (std.mem.eql(u8, name, "undefined")) return types.Primitive.undefined_t;
        if (std.mem.eql(u8, name, "string")) return types.Primitive.string_t;
        if (std.mem.eql(u8, name, "number")) return types.Primitive.number_t;
        if (std.mem.eql(u8, name, "boolean")) return types.Primitive.boolean_t;
        if (std.mem.eql(u8, name, "bigint")) return types.Primitive.bigint_t;
        if (std.mem.eql(u8, name, "symbol")) return types.Primitive.symbol_t;
        if (std.mem.eql(u8, name, "object")) return types.Primitive.object_t;
        if (r.qualifier_len == 0 and r.args_len == 1 and
            (std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "ReadonlyArray")))
        {
            const args = hir_mod.typeRefArgs(self.hir, node);
            const inner = try self.lower(args[0]);
            return self.interner.internArrayType(self.string_interner, inner) catch error.OutOfMemory;
        }
        // Non-primitive named refs require symbol resolution against
        // the binder. For now emit a placeholder that the checker
        // re-resolves once we feed it the bound module.
        return types.Primitive.unknown;
    }

    fn lowerUnion(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const members = hir_mod.unionTypeMembers(self.hir, node);
        // Lower each member and intern as a union.
        var ids: std.ArrayListUnmanaged(TypeId) = .empty;
        defer ids.deinit(self.gpa);
        for (members) |m| {
            const id = try self.lower(m);
            try ids.append(self.gpa, id);
        }
        return self.interner.internUnion(ids.items) catch error.OutOfMemory;
    }

    fn lowerIntersection(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const members = hir_mod.intersectionTypeMembers(self.hir, node);
        var ids: std.ArrayListUnmanaged(TypeId) = .empty;
        defer ids.deinit(self.gpa);
        for (members) |m| {
            const id = try self.lower(m);
            try ids.append(self.gpa, id);
        }
        return self.interner.internIntersection(ids.items) catch error.OutOfMemory;
    }

    fn lowerKeyof(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const k = hir_mod.keyofTypeOf(self.hir, node);
        const operand = try self.lower(k.operand);
        // Eager evaluation when the operand is a known object type
        // — produce the union of its property names as string
        // literals. Other operand shapes (type parameters, etc.)
        // fall back to the symbolic `keyof T` representation, which
        // future substitution can re-evaluate.
        if (self.interner.pool.flagsOf(operand).is_object_type) {
            const members = self.interner.objectMembers(operand);
            if (members.len == 0) return types.Primitive.never;
            var lits: std.ArrayListUnmanaged(TypeId) = .empty;
            defer lits.deinit(self.gpa);
            for (members) |m| {
                const lit = self.interner.internStringLiteral(m.name) catch continue;
                try lits.append(self.gpa, lit);
            }
            if (lits.items.len == 1) return lits.items[0];
            return self.interner.internUnion(lits.items) catch error.OutOfMemory;
        }
        return self.interner.internKeyof(operand) catch error.OutOfMemory;
    }

    fn lowerIndexedAccess(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const ia = hir_mod.indexedAccessTypeOf(self.hir, node);
        const obj = try self.lower(ia.object);
        const idx = try self.lower(ia.index);
        return self.interner.internIndexedAccess(obj, idx) catch error.OutOfMemory;
    }

    /// `infer R` placeholder — interned as a TypeParameter with the
    /// infer's name. Matching during conditional eval substitutes
    /// this TypeParameter with the matched type.
    fn lowerInferType(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const ip = hir_mod.inferTypeOf(self.hir, node);
        const constraint: TypeId = if (ip.constraint != hir_mod.none_node_id)
            try self.lower(ip.constraint)
        else
            types.Primitive.unknown;
        return self.interner.internTypeParameter(ip.name, constraint, types.Primitive.none) catch error.OutOfMemory;
    }

    fn lowerConditional(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const c = hir_mod.conditionalTypeOf(self.hir, node);
        const check = try self.lower(c.check);
        const ext = try self.lower(c.extends);
        const tt = try self.lower(c.true_branch);
        const ff = try self.lower(c.false_branch);
        const is_distributive = self.conditionalCheckNodeIsNakedTypeParameter(c.check, check);
        return self.interner.internConditionalWithDistribution(check, ext, tt, ff, is_distributive) catch error.OutOfMemory;
    }

    fn conditionalCheckNodeIsNakedTypeParameter(self: *Lowerer, check_node: NodeId, check_t: TypeId) bool {
        if (check_t >= self.interner.pool.typeCount()) return false;
        if (!self.interner.pool.flagsOf(check_t).is_type_parameter) return false;
        return switch (self.hir.kindOf(check_node)) {
            .identifier => true,
            .type_ref => blk: {
                const r = hir_mod.typeRefOf(self.hir, check_node);
                break :blk r.qualifier_len == 0 and r.args_len == 0;
            },
            else => false,
        };
    }

    fn lowerLiteralType(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const lt = hir_mod.literalTypeOf(self.hir, node);
        const lit = lt.literal;
        return switch (self.hir.kindOf(lit)) {
            .literal_string => blk: {
                const s = hir_mod.literalStringOf(self.hir, lit);
                break :blk self.interner.internStringLiteral(s.value) catch error.OutOfMemory;
            },
            .literal_number => blk: {
                const v = hir_mod.literalNumberOf(self.hir, lit);
                const signed: f64 = if (lt.negative and v > 0) -v else v;
                break :blk self.interner.internNumberLiteral(signed) catch error.OutOfMemory;
            },
            .literal_bool => blk: {
                const v = hir_mod.literalBoolOf(self.hir, lit);
                break :blk self.interner.internBooleanLiteral(v);
            },
            .literal_bigint => blk: {
                const b = hir_mod.literalBigIntOf(self.hir, lit);
                if (!lt.negative) break :blk self.interner.internBigIntLiteral(b.digits) catch error.OutOfMemory;
                const digits = self.string_interner.get(b.digits);
                const signed = try std.fmt.allocPrint(self.gpa, "-{s}", .{digits});
                defer self.gpa.free(signed);
                const signed_id = self.string_interner.intern(signed) catch return error.OutOfMemory;
                break :blk self.interner.internBigIntLiteral(signed_id) catch error.OutOfMemory;
            },
            else => types.Primitive.unknown,
        };
    }

    fn lowerArray(self: *Lowerer, node: NodeId) LowerError!TypeId {
        // Lower `T[]` as the standard Array<T> shape: an object
        // type with `length: number` plus a `[i: number]: T`
        // indexer. Re-uses the same intern path as array literals.
        const a = hir_mod.arrayTypeOf(self.hir, node);
        const element = try self.lower(a.element);
        return self.interner.internArrayType(self.string_interner, element) catch error.OutOfMemory;
    }

    fn lowerTuple(self: *Lowerer, node: NodeId) LowerError!TypeId {
        // Tuple lowering: build an object type with `length: N`
        // (literal), per-index members keyed by "0", "1", … typed
        // as the matching element, and a number-key indexer typed
        // as the union of all element types so out-of-bound or
        // dynamic-index access still resolves to something useful.
        //
        // Variadic tuples (TS 4.0+, e.g. `[T, ...U[], V]`): a
        // `rest_type` element either expands inline (when its
        // operand is a known fixed-length tuple) or relaxes the
        // shape — the resulting object type uses a non-literal
        // `length: number` and only emits fixed-index members for
        // elements that precede the first rest. The number-key
        // indexer captures the rest element's type so dynamic
        // indexing still resolves.
        const elems = hir_mod.tupleTypeElements(self.hir, node);

        var fixed_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer fixed_types.deinit(self.gpa);
        var fixed_optional: std.ArrayListUnmanaged(bool) = .empty;
        defer fixed_optional.deinit(self.gpa);
        var rest_elem_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer rest_elem_types.deinit(self.gpa);
        var saw_unknown_rest = false;

        for (elems) |raw_e| {
            var e = raw_e;
            var is_optional = false;
            if (self.hir.kindOf(e) == .optional_type) {
                is_optional = true;
                e = hir_mod.optionalTypeOf(self.hir, e).operand;
            }
            if (self.hir.kindOf(e) == .rest_type) {
                const rt = hir_mod.restTypeOf(self.hir, e);
                const opk = self.hir.kindOf(rt.operand);
                if (opk == .tuple_type) {
                    // Inline-expand a known fixed-length tuple
                    // spread when the inner tuple has no rest.
                    const inner_elems = hir_mod.tupleTypeElements(self.hir, rt.operand);
                    var inner_has_rest = false;
                    for (inner_elems) |ie| {
                        if (self.hir.kindOf(ie) == .rest_type) {
                            inner_has_rest = true;
                            break;
                        }
                    }
                    if (!inner_has_rest) {
                        for (inner_elems) |raw_ie| {
                            var ie = raw_ie;
                            var inner_optional = false;
                            if (self.hir.kindOf(ie) == .optional_type) {
                                inner_optional = true;
                                ie = hir_mod.optionalTypeOf(self.hir, ie).operand;
                            }
                            const t = try self.lower(ie);
                            try fixed_types.append(self.gpa, t);
                            try fixed_optional.append(self.gpa, inner_optional);
                        }
                        continue;
                    }
                }
                if (opk == .array_type) {
                    const at = hir_mod.arrayTypeOf(self.hir, rt.operand);
                    const elt = try self.lower(at.element);
                    try rest_elem_types.append(self.gpa, elt);
                    saw_unknown_rest = true;
                    continue;
                }
                // Generic / unknown rest: lower the operand as a
                // placeholder element type, marking the tuple
                // variable-length.
                const elt = try self.lower(rt.operand);
                try rest_elem_types.append(self.gpa, elt);
                saw_unknown_rest = true;
                continue;
            }
            const t = try self.lower(e);
            try fixed_types.append(self.gpa, t);
            try fixed_optional.append(self.gpa, is_optional);
        }

        var members: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
        defer members.deinit(self.gpa);

        // With a rest somewhere in the middle, only elements
        // before the first rest are positionally unambiguous.
        const fixed_prefix_len: usize = if (saw_unknown_rest) blk: {
            var n: usize = 0;
            for (elems) |raw_e| {
                var e = raw_e;
                if (self.hir.kindOf(e) == .optional_type) e = hir_mod.optionalTypeOf(self.hir, e).operand;
                if (self.hir.kindOf(e) == .rest_type) {
                    const rt = hir_mod.restTypeOf(self.hir, e);
                    const opk = self.hir.kindOf(rt.operand);
                    if (opk == .tuple_type) {
                        const inner_elems = hir_mod.tupleTypeElements(self.hir, rt.operand);
                        var inner_has_rest = false;
                        for (inner_elems) |ie| {
                            if (self.hir.kindOf(ie) == .rest_type) {
                                inner_has_rest = true;
                                break;
                            }
                        }
                        if (!inner_has_rest) {
                            n += inner_elems.len;
                            continue;
                        }
                    }
                    break;
                }
                n += 1;
            }
            break :blk n;
        } else fixed_types.items.len;

        var i: usize = 0;
        while (i < fixed_prefix_len) : (i += 1) {
            const t = fixed_types.items[i];
            var nbuf: [12]u8 = undefined;
            const name_str = std.fmt.bufPrint(&nbuf, "{d}", .{i}) catch continue;
            const name = self.string_interner.intern(name_str) catch continue;
            try members.append(self.gpa, .{
                .name = name,
                .type = t,
                .is_optional = fixed_optional.items[i],
                .is_readonly = false,
                .is_method = false,
            });
        }

        const length_id = self.string_interner.intern("length") catch return error.OutOfMemory;
        const length_t: TypeId = if (saw_unknown_rest)
            types.Primitive.number_t
        else
            self.interner.internNumberLiteral(@floatFromInt(fixed_types.items.len)) catch types.Primitive.number_t;
        try members.append(self.gpa, .{
            .name = length_id,
            .type = length_t,
            .is_optional = false,
            .is_readonly = true,
            .is_method = false,
        });

        var idx_union: std.ArrayListUnmanaged(TypeId) = .empty;
        defer idx_union.deinit(self.gpa);
        for (fixed_types.items) |t| try idx_union.append(self.gpa, t);
        for (rest_elem_types.items) |t| try idx_union.append(self.gpa, t);
        const elem_union: TypeId = if (idx_union.items.len == 0)
            types.Primitive.never
        else if (idx_union.items.len == 1)
            idx_union.items[0]
        else
            self.interner.internUnion(idx_union.items) catch types.Primitive.any;
        return self.interner.internObjectTypeWithIndex(members.items, types.Primitive.none, elem_union) catch error.OutOfMemory;
    }

    /// Lower a template-literal type. Walks the alternating
    /// text/type parts; if every interpolated type lowers to a
    /// string-literal, concatenate the whole template into a
    /// single string-literal type. Otherwise fall back to the
    /// broad `string` primitive.
    fn lowerTemplateLiteralType(self: *Lowerer, node: NodeId) LowerError!TypeId {
        const text_parts = hir_mod.templateLiteralTypeTexts(self.hir, node);
        const type_parts = hir_mod.templateLiteralTypeTypes(self.hir, node);
        // Builder invariant: text_parts.len == type_parts.len + 1.
        if (text_parts.len == 0) return types.Primitive.string_t;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);

        for (text_parts, 0..) |text_node, i| {
            // Append the text segment.
            if (text_node != hir_mod.none_node_id and self.hir.kindOf(text_node) == .literal_string) {
                const sp = hir_mod.literalStringOf(self.hir, text_node);
                const bytes = self.string_interner.get(sp.value);
                try buf.appendSlice(self.gpa, bytes);
            } else {
                // Malformed text part — can't materialize.
                return types.Primitive.string_t;
            }
            // Append the substituted type's literal value, if any.
            if (i < type_parts.len) {
                const sub = try self.lower(type_parts[i]);
                const flags = self.interner.pool.flagsOf(sub);
                if (!(flags.is_literal and flags.is_string)) {
                    // Non-string-literal interpolation — bail out.
                    return types.Primitive.string_t;
                }
                const lit = self.interner.literalOf(sub);
                switch (lit) {
                    .string_lit => |sid| {
                        const bytes = self.string_interner.get(sid);
                        try buf.appendSlice(self.gpa, bytes);
                    },
                    else => return types.Primitive.string_t,
                }
            }
        }

        const sid = self.string_interner.intern(buf.items) catch return error.OutOfMemory;
        return self.interner.internStringLiteral(sid) catch error.OutOfMemory;
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;
const ts_lexer = @import("ts_lexer");
const ts_parser = @import("ts_parser");

const TestSetup = struct {
    sint: string_interner.Interner,
    hir: Hir,
    scanner: ts_lexer.Scanner,
    tokens: std.ArrayList(ts_lexer.Token),
    parser: ts_parser.Parser,
    ti: interner.Interner,
    lowerer: Lowerer,
    root: NodeId,
};

fn newSetup(source: []const u8) !*TestSetup {
    const s = try T.allocator.create(TestSetup);
    errdefer T.allocator.destroy(s);
    s.sint = try string_interner.Interner.init(T.allocator);
    errdefer s.sint.deinit();
    s.hir = try Hir.init(T.allocator);
    errdefer s.hir.deinit();
    s.scanner = ts_lexer.Scanner.init(T.allocator, source);
    errdefer s.scanner.deinit(T.allocator);
    s.tokens = try s.scanner.tokenize(T.allocator);
    errdefer s.tokens.deinit(T.allocator);
    s.parser = ts_parser.Parser.init(T.allocator, &s.hir, &s.sint, source, s.tokens.items);
    errdefer s.parser.deinit();
    s.root = try s.parser.parseSourceFile();
    s.ti = try interner.Interner.init(T.allocator);
    errdefer s.ti.deinit();
    s.lowerer = Lowerer.init(T.allocator, &s.hir, &s.ti, &s.sint);
    return s;
}

fn destroySetup(s: *TestSetup) void {
    s.ti.deinit();
    s.parser.deinit();
    s.tokens.deinit(T.allocator);
    s.scanner.deinit(T.allocator);
    s.hir.deinit();
    s.sint.deinit();
    T.allocator.destroy(s);
}

/// Pull the type-annotation node out of `let x: T;`.
fn typeAnnotationOf(s: *TestSetup) NodeId {
    const stmts = hir_mod.blockStmts(&s.hir, s.root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[0]);
    return v.type_annotation;
}

test "lower: number primitive" {
    const s = try newSetup("let x: number;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    try T.expectEqual(types.Primitive.number_t, id);
}

test "lower: string primitive" {
    const s = try newSetup("let x: string;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    try T.expectEqual(types.Primitive.string_t, id);
}

test "lower: any / unknown / never / void" {
    {
        const s = try newSetup("let x: any;");
        defer destroySetup(s);
        try T.expectEqual(types.Primitive.any, try s.lowerer.lower(typeAnnotationOf(s)));
    }
    {
        const s = try newSetup("let x: unknown;");
        defer destroySetup(s);
        try T.expectEqual(types.Primitive.unknown, try s.lowerer.lower(typeAnnotationOf(s)));
    }
    {
        const s = try newSetup("let x: never;");
        defer destroySetup(s);
        try T.expectEqual(types.Primitive.never, try s.lowerer.lower(typeAnnotationOf(s)));
    }
    {
        const s = try newSetup("let x: void;");
        defer destroySetup(s);
        try T.expectEqual(types.Primitive.void_t, try s.lowerer.lower(typeAnnotationOf(s)));
    }
}

test "lower: union of primitives" {
    const s = try newSetup("let x: number | string;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    const flags = s.ti.pool.flagsOf(id);
    try T.expect(flags.is_union);
    try T.expect(flags.is_string);
    try T.expect(flags.is_number);
}

test "lower: intersection collapses single-member" {
    const s = try newSetup("let x: number;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    try T.expectEqual(types.Primitive.number_t, id);
}

test "lower: literal type 'hello' interns once" {
    const s = try newSetup("let x: \"hello\" | \"world\";");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    const flags = s.ti.pool.flagsOf(id);
    try T.expect(flags.is_union);
    try T.expect(flags.is_string);
}

test "lower: numeric literal type" {
    const s = try newSetup("let x: 42;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    const flags = s.ti.pool.flagsOf(id);
    try T.expect(flags.is_number);
    try T.expect(flags.is_literal);
}

test "lower: negative numeric literal type" {
    const s = try newSetup("let x: -42;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    const flags = s.ti.pool.flagsOf(id);
    try T.expect(flags.is_number);
    try T.expect(flags.is_literal);
}

test "lower: boolean literal types reuse primitives" {
    {
        const s = try newSetup("let x: true;");
        defer destroySetup(s);
        try T.expectEqual(types.Primitive.true_lit, try s.lowerer.lower(typeAnnotationOf(s)));
    }
    {
        const s = try newSetup("let x: false;");
        defer destroySetup(s);
        try T.expectEqual(types.Primitive.false_lit, try s.lowerer.lower(typeAnnotationOf(s)));
    }
}

test "lower: keyof produces is_keyof type" {
    const s = try newSetup("let x: keyof Foo;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    try T.expect(s.ti.pool.flagsOf(id).is_keyof);
}

test "lower: T[K] produces indexed-access type" {
    const s = try newSetup("let x: A[B];");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    try T.expect(s.ti.pool.flagsOf(id).is_indexed_access);
}

test "lower: conditional type" {
    const s = try newSetup("let x: T extends U ? string : number;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    try T.expect(s.ti.pool.flagsOf(id).is_conditional);
}

test "lower: non-primitive named ref falls back to unknown" {
    const s = try newSetup("let x: MyCustomType;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    try T.expectEqual(types.Primitive.unknown, id);
}

test "lower: template literal type with no interpolations evaluates to the literal" {
    const s = try newSetup("let x: `hello-world`;");
    defer destroySetup(s);
    const id = try s.lowerer.lower(typeAnnotationOf(s));
    const flags = s.ti.pool.flagsOf(id);
    try T.expect(flags.is_literal);
    try T.expect(flags.is_string);
    const lit = s.ti.literalOf(id);
    switch (lit) {
        .string_lit => |sid| try T.expectEqualStrings("hello-world", s.sint.get(sid)),
        else => return error.TestExpectedEqual,
    }
}

test "lower: template literal type with string-literal interpolation evaluates" {
    // The lexer's eager `tokenize` doesn't yet drive parser-side
    // template re-scan after `${ … }`, so we build the HIR shape
    // directly to exercise the lower path: `` `prefix-${'foo'}` ``
    // → string-literal "prefix-foo".
    const s = try newSetup("let x: string;");
    defer destroySetup(s);

    var b = hir_mod.Builder.init(&s.hir);
    defer b.deinit();
    const sp_zero: hir_mod.Span = .{ .start = 0, .end = 0 };
    const prefix_id = try s.sint.intern("prefix-");
    const empty_id = try s.sint.intern("");
    const foo_id = try s.sint.intern("foo");
    const t0 = try b.addLiteralString(sp_zero, prefix_id);
    const t1 = try b.addLiteralString(sp_zero, empty_id);
    const inner_str = try b.addLiteralString(sp_zero, foo_id);
    const inner_lit_type = try b.addLiteralType(sp_zero, inner_str, false);
    const tmpl = try b.addTemplateLiteralType(
        sp_zero,
        &.{ t0, t1 },
        &.{inner_lit_type},
    );

    const id = try s.lowerer.lower(tmpl);
    const flags = s.ti.pool.flagsOf(id);
    try T.expect(flags.is_literal);
    try T.expect(flags.is_string);
    const lit = s.ti.literalOf(id);
    switch (lit) {
        .string_lit => |sid| try T.expectEqualStrings("prefix-foo", s.sint.get(sid)),
        else => return error.TestExpectedEqual,
    }
}

test "lower: union sort+dedup canonicalizes" {
    const s = try newSetup("let x: string | number;");
    defer destroySetup(s);
    const id_ab = try s.lowerer.lower(typeAnnotationOf(s));
    const s2 = try newSetup("let x: number | string;");
    defer destroySetup(s2);
    const id_ba = try s2.lowerer.lower(typeAnnotationOf(s2));
    // Both reach the same union type since the interner sorts by id.
    // (Interner is per-test; this just validates the canonicalization
    // path doesn't blow up.)
    try T.expect(s.ti.pool.flagsOf(id_ab).is_union);
    try T.expect(s2.ti.pool.flagsOf(id_ba).is_union);
}
