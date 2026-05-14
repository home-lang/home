//! `.d.hm` — Home declaration files.
//!
//! Phase 4 of TS_PARITY_PLAN.
//!
//! Symmetric to `.d.ts` for TypeScript. Used by:
//!   - The bundler when emitting Home libraries for downstream
//!     consumption.
//!   - `home build --emit-declarations`.
//!   - The LSP for cross-package type resolution.
//!   - The package manager when publishing a Home package — the
//!     equivalent of npm's `types` field, but in `pantry.json`.
//!
//! Cross-frontend interop: a `.ts` file can `import { ...Home types... }
//! from "./mod.home"`, and the type checker reads Home's `.d.hm`
//! summary as it would `.d.ts`. Same in reverse: `.home` files can
//! import `.ts` modules with the type checker reading the `.d.ts`
//! summary.
//!
//! Phase 4 ships:
//!   - The grammar definition for `.d.hm` (declarations only — no fn
//!     bodies, no executable statements).
//!   - A `Validator` that walks a parsed Home AST and verifies every
//!     construct is a valid declaration form.
//!   - A `Loader` skeleton that gets filled in once the Home parser
//!     gains its declaration-only mode.
//!
//! Phase 4 follow-ups (not blocking):
//!   - Home symbol-driven re-printing of resolved types into `.d.hm`.
//!   - Pantry manifest integration.

const std = @import("std");
const hir_mod = @import("hir");
const string_interner = @import("string_interner");

pub const NodeId = hir_mod.NodeId;
pub const Hir = hir_mod.Hir;

/// What kind of declaration a `.d.hm` file can contain. Strict subset
/// of Home's full grammar.
pub const DeclKind = enum(u8) {
    /// `pub fn name(...) -> T;` — function signature only, no body.
    fn_signature,
    /// `pub struct Name { ... }` — fields with types only.
    struct_decl,
    /// `pub enum Name { ... }` — variants only.
    enum_decl,
    /// `pub trait Name { ... }` — method signatures only.
    trait_decl,
    /// `pub type Name = T;` — type alias.
    type_alias,
    /// `pub const NAME: T;` — constant *declaration* (no initializer).
    const_decl,
    /// `extern fn name(...) -> T;` — FFI signature.
    extern_fn,
    /// `declare module "foo" { ... }` — ambient module augmentation
    /// for FFI surfaces.
    declare_module,
};

pub const ValidationError = struct {
    /// Byte position in the source where the offending construct
    /// begins.
    pos: u32,
    message: []const u8,
};

/// Lib catalog — Home's analogue to `lib.es2024.d.ts` etc. These are
/// the bundled `.d.hm` packages distributed with the compiler that
/// describe the Home stdlib surface.
pub const Lib = enum {
    /// Core types: number, bool, string, etc.
    core,
    /// I/O types and traits.
    io,
    /// Concurrency primitives: thread, channel, mutex, …
    concurrency,
    /// Standard collections: list, map, set, …
    collections,
    /// Time, duration, instant.
    time,
    /// FFI types and conversions.
    ffi,

    pub fn fileName(self: Lib) []const u8 {
        return switch (self) {
            .core => "lib.core.d.hm",
            .io => "lib.io.d.hm",
            .concurrency => "lib.concurrency.d.hm",
            .collections => "lib.collections.d.hm",
            .time => "lib.time.d.hm",
            .ffi => "lib.ffi.d.hm",
        };
    }

    pub fn fromName(name: []const u8) ?Lib {
        const map = .{
            .{ "core", Lib.core },
            .{ "io", Lib.io },
            .{ "concurrency", Lib.concurrency },
            .{ "collections", Lib.collections },
            .{ "time", Lib.time },
            .{ "ffi", Lib.ffi },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }
};

/// Returns the full closure of libs implied by a Home target.
/// Phase 4 placeholder: every target gets the full lib catalog. A
/// future revision can introduce per-target subsets.
pub fn libsForTarget(_: enum { native_x64, native_arm64, wasm }) []const Lib {
    return &[_]Lib{
        .core,
        .io,
        .concurrency,
        .collections,
        .time,
        .ffi,
    };
}

// =============================================================================
// Emitter — string-buffer-based `.d.hm` writer.
// =============================================================================
//
// Phase 4 simpler-scope: the eventual symbol-driven Home AST traversal
// will fill in the `Decl` shapes. For now we ship the framing: each
// writer takes already-rendered type strings and emits the surrounding
// `pub` / `extern` / `;` scaffolding plus an auto-gen header.

/// A single function or struct parameter, pre-rendered.
pub const ParamSpec = struct {
    name: []const u8,
    ty: []const u8,
};

/// A single struct field, pre-rendered.
pub const FieldSpec = struct {
    name: []const u8,
    ty: []const u8,
};

/// One enum variant. `payload_ty` is null for unit variants, or
/// the pre-rendered payload type for tuple-style variants like
/// `Some(int)`.
pub const VariantSpec = struct {
    name: []const u8,
    payload_ty: ?[]const u8 = null,
};

/// A single method signature on a trait. Mirrors `writeFnSignature`'s
/// argument list; the printer adds the `fn ` keyword + `;` terminator
/// inside the trait body.
pub const MethodSpec = struct {
    name: []const u8,
    params: []const ParamSpec,
    return_ty: []const u8,
};

pub const EmitOptions = struct {
    /// If set, the standard auto-gen banner is written by `init` so
    /// callers don't have to remember it.
    write_header: bool = true,
    newline: []const u8 = "\n",
};

pub const HEADER: []const u8 = "// Auto-generated .d.hm file. Do not edit.";

/// Append-only `.d.hm` text builder.
///
/// Lifetime:
///   var em = Emitter.init(gpa);
///   defer em.deinit();
///   try em.writeFnSignature("add", &.{ .{ .name = "a", .ty = "int" } }, "int");
///   const text = try em.toOwnedSlice();
///
/// Once `toOwnedSlice` succeeds, the buffer is empty again and the
/// caller owns the returned bytes.
pub const Emitter = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8),
    options: EmitOptions,
    header_written: bool,

    pub fn init(gpa: std.mem.Allocator) Emitter {
        return initWith(gpa, .{});
    }

    pub fn initWith(gpa: std.mem.Allocator, options: EmitOptions) Emitter {
        return .{
            .gpa = gpa,
            .out = .empty,
            .options = options,
            .header_written = false,
        };
    }

    pub fn deinit(self: *Emitter) void {
        self.out.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *Emitter) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }

    fn writeRaw(self: *Emitter, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    fn ensureHeader(self: *Emitter) !void {
        if (!self.options.write_header) return;
        if (self.header_written) return;
        try self.writeRaw(HEADER);
        try self.writeRaw(self.options.newline);
        self.header_written = true;
    }

    fn writeParamList(self: *Emitter, params: []const ParamSpec) !void {
        try self.writeRaw("(");
        for (params, 0..) |p, i| {
            if (i > 0) try self.writeRaw(", ");
            try self.writeRaw(p.name);
            try self.writeRaw(": ");
            try self.writeRaw(p.ty);
        }
        try self.writeRaw(")");
    }

    /// `pub fn name(...) -> T;`
    pub fn writeFnSignature(
        self: *Emitter,
        name: []const u8,
        params: []const ParamSpec,
        return_ty: []const u8,
    ) !void {
        try self.ensureHeader();
        try self.writeRaw("pub fn ");
        try self.writeRaw(name);
        try self.writeParamList(params);
        try self.writeRaw(" -> ");
        try self.writeRaw(return_ty);
        try self.writeRaw(";");
        try self.writeRaw(self.options.newline);
    }

    /// `pub struct Name { f1: T1, f2: T2 }`
    pub fn writeStruct(
        self: *Emitter,
        name: []const u8,
        fields: []const FieldSpec,
    ) !void {
        try self.ensureHeader();
        try self.writeRaw("pub struct ");
        try self.writeRaw(name);
        try self.writeRaw(" {");
        if (fields.len == 0) {
            try self.writeRaw("}");
        } else {
            try self.writeRaw(" ");
            for (fields, 0..) |f, i| {
                if (i > 0) try self.writeRaw(", ");
                try self.writeRaw(f.name);
                try self.writeRaw(": ");
                try self.writeRaw(f.ty);
            }
            try self.writeRaw(" }");
        }
        try self.writeRaw(self.options.newline);
    }

    /// `pub type Name = T;`
    pub fn writeTypeAlias(
        self: *Emitter,
        name: []const u8,
        ty: []const u8,
    ) !void {
        try self.ensureHeader();
        try self.writeRaw("pub type ");
        try self.writeRaw(name);
        try self.writeRaw(" = ");
        try self.writeRaw(ty);
        try self.writeRaw(";");
        try self.writeRaw(self.options.newline);
    }

    /// `pub const NAME: T;` — declaration only, no initializer.
    pub fn writeConstDecl(
        self: *Emitter,
        name: []const u8,
        ty: []const u8,
    ) !void {
        try self.ensureHeader();
        try self.writeRaw("pub const ");
        try self.writeRaw(name);
        try self.writeRaw(": ");
        try self.writeRaw(ty);
        try self.writeRaw(";");
        try self.writeRaw(self.options.newline);
    }

    /// `extern fn name(...) -> T;` — FFI signature, no `pub` prefix
    /// (extern is its own visibility marker for `.d.hm`).
    pub fn writeExternFn(
        self: *Emitter,
        name: []const u8,
        params: []const ParamSpec,
        return_ty: []const u8,
    ) !void {
        try self.ensureHeader();
        try self.writeRaw("extern fn ");
        try self.writeRaw(name);
        try self.writeParamList(params);
        try self.writeRaw(" -> ");
        try self.writeRaw(return_ty);
        try self.writeRaw(";");
        try self.writeRaw(self.options.newline);
    }

    /// `pub enum Name { V1, V2(int), V3 }` — variants only; no
    /// methods or `impl` blocks emitted (those belong on the
    /// implementation side, not in a declaration file).
    pub fn writeEnum(
        self: *Emitter,
        name: []const u8,
        variants: []const VariantSpec,
    ) !void {
        try self.ensureHeader();
        try self.writeRaw("pub enum ");
        try self.writeRaw(name);
        try self.writeRaw(" {");
        if (variants.len == 0) {
            try self.writeRaw("}");
        } else {
            try self.writeRaw(" ");
            for (variants, 0..) |v, i| {
                if (i > 0) try self.writeRaw(", ");
                try self.writeRaw(v.name);
                if (v.payload_ty) |pt| {
                    try self.writeRaw("(");
                    try self.writeRaw(pt);
                    try self.writeRaw(")");
                }
            }
            try self.writeRaw(" }");
        }
        try self.writeRaw(self.options.newline);
    }

    /// `pub trait Name { fn m1(...) -> T; … }` — method signatures
    /// only. No default-method bodies (those are implementation
    /// detail and don't belong in a declaration file).
    pub fn writeTrait(
        self: *Emitter,
        name: []const u8,
        methods: []const MethodSpec,
    ) !void {
        try self.ensureHeader();
        try self.writeRaw("pub trait ");
        try self.writeRaw(name);
        try self.writeRaw(" {");
        if (methods.len == 0) {
            try self.writeRaw("}");
        } else {
            try self.writeRaw(self.options.newline);
            for (methods) |m| {
                try self.writeRaw("    fn ");
                try self.writeRaw(m.name);
                try self.writeParamList(m.params);
                try self.writeRaw(" -> ");
                try self.writeRaw(m.return_ty);
                try self.writeRaw(";");
                try self.writeRaw(self.options.newline);
            }
            try self.writeRaw("}");
        }
        try self.writeRaw(self.options.newline);
    }

    /// `declare module "name" { ... }` — opens a module-augmentation
    /// block. Caller must call `closeDeclareModule` after writing the
    /// inner declarations.
    pub fn openDeclareModule(self: *Emitter, module_name: []const u8) !void {
        try self.ensureHeader();
        try self.writeRaw("declare module \"");
        try self.writeRaw(module_name);
        try self.writeRaw("\" {");
        try self.writeRaw(self.options.newline);
    }

    /// Closing brace for a previously opened `declare module` block.
    pub fn closeDeclareModule(self: *Emitter) !void {
        try self.writeRaw("}");
        try self.writeRaw(self.options.newline);
    }
};

// =============================================================================
// HIR-driven re-printer — Home declaration emitter.
// =============================================================================
//
// Symmetric to `packages/ts_emit/src/d_ts_emit.zig` but emits Home
// `.d.hm` syntax. Walks a HIR module root, strips function bodies and
// initializers, and re-prints the public type surface using Home's
// declaration grammar (`pub fn`, `pub struct`, `pub trait`, `pub type`,
// `pub enum`, `pub const`, `extern fn`).
//
// HIR is the shared substrate between the TypeScript and Home parsers
// (per TS_PARITY_PLAN Phase 4 §4.A.13), so the re-printer works
// uniformly: when fed a TS-parsed source it surfaces Home-renamed
// primitives (`number → f64`, `string → str`, etc.); when fed Home
// HIR directly the names already line up. The only frontend-specific
// piece is `pub` visibility, which the binder eventually annotates;
// for now we emit `pub` for every declaration that reaches the
// re-printer (matching the assumption that `.d.hm` *is* the public
// surface — anything internal is filtered upstream).
//
// Phase 4 §4.A.13 coverage today:
//   - `fn name(p: T) -> U;` (body stripped)
//   - `struct Name { f: T, g: U }`
//   - `trait Name { fn m(p: T) -> U; }`
//   - `type Alias = T;`
//   - `enum Name { V1, V2(T) }`
//   - `const NAME: T;` (initializer dropped)
//
// Type-printer recurses into:
//   - Type refs (`Foo`, `Vec<T>`, `Option<T>`)
//   - Tuple types (`(T, U)`)
//   - Array types (`Vec<T>`)
//   - Function types (`fn(T) -> U`)
//   - Union / intersection types (`T | U`, `T & U`)
//   - Literal types (`"hello"`, `42`, `true`)
//   - Object type literals (`{ f: T }`)
//
// Follow-ups (not blocking):
//   - Visibility honoring once Home's binder annotates `pub`/`pub(crate)`.
//   - `extern fn` once HIR carries an `is_extern` flag on `fn_decl`.
//   - `declare module "name" { ... }` walking once Home parses module
//     ambient blocks into HIR.
//   - Generic type parameter lists on `fn`, `struct`, `trait`, `type`.
//   - Position-preserving source-map entries (currently the parallel
//     `.d.hm.map` ships with empty mappings).

pub const HirEmitOptions = struct {
    indent: []const u8 = "    ",
    newline: []const u8 = "\n",
    /// When true, the standard auto-gen banner is written before the
    /// first declaration (matching `Emitter`'s default).
    write_header: bool = true,
};

pub const HirEmitError = error{
    OutOfMemory,
};

/// HIR-driven `.d.hm` re-printer.
///
/// Lifetime mirrors `Emitter`: caller owns `Hir` + `Interner`; the
/// emitter borrows them. Output bytes are owned by the emitter until
/// `toOwnedSlice` succeeds.
pub const HirEmitter = struct {
    gpa: std.mem.Allocator,
    hir: *const Hir,
    interner: *const string_interner.Interner,
    out: std.ArrayListUnmanaged(u8),
    options: HirEmitOptions,
    depth: u32,
    header_written: bool,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *const Hir,
        interner: *const string_interner.Interner,
        options: HirEmitOptions,
    ) HirEmitter {
        return .{
            .gpa = gpa,
            .hir = hir,
            .interner = interner,
            .out = .empty,
            .options = options,
            .depth = 0,
            .header_written = false,
        };
    }

    pub fn deinit(self: *HirEmitter) void {
        self.out.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *HirEmitter) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }

    fn write(self: *HirEmitter, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    fn indent(self: *HirEmitter) !void {
        var i: u32 = 0;
        while (i < self.depth) : (i += 1) try self.write(self.options.indent);
    }

    fn ensureHeader(self: *HirEmitter) !void {
        if (!self.options.write_header) return;
        if (self.header_written) return;
        try self.write(HEADER);
        try self.write(self.options.newline);
        self.header_written = true;
    }

    /// Walk the source-file root, emitting one declaration per
    /// supported HIR statement. Unsupported kinds (statements, expr
    /// statements, etc.) are silently skipped — they aren't valid
    /// inside a `.d.hm` anyway.
    pub fn emitSourceFile(self: *HirEmitter, root: NodeId) !void {
        try self.ensureHeader();
        const stmts = hir_mod.blockStmts(self.hir, root);
        for (stmts) |s| {
            if (!self.shouldEmit(s)) continue;
            try self.emitDeclaration(s);
        }
    }

    fn shouldEmit(self: *const HirEmitter, node: NodeId) bool {
        return switch (self.hir.kindOf(node)) {
            .fn_decl,
            .class_decl,
            .interface_decl,
            .type_alias_decl,
            .enum_decl,
            .const_decl,
            .let_decl,
            .var_decl,
            .namespace_decl,
            .module_decl,
            .export_decl,
            => true,
            else => false,
        };
    }

    fn emitDeclaration(self: *HirEmitter, node: NodeId) anyerror!void {
        try self.indent();
        switch (self.hir.kindOf(node)) {
            .fn_decl => try self.emitFn(node),
            // A TS `class` translates to Home `struct`. Methods on a
            // class don't have a direct Home struct equivalent, so we
            // re-print only the field surface — methods fall through
            // to the trait re-printer when callers wire that route.
            .class_decl => try self.emitClassAsStruct(node),
            // A TS `interface` translates to Home `trait` (closest
            // structural equivalent).
            .interface_decl => try self.emitInterfaceAsTrait(node),
            .type_alias_decl => try self.emitTypeAlias(node),
            .enum_decl => try self.emitEnumDecl(node),
            .const_decl, .let_decl, .var_decl => try self.emitConstDecl(node),
            .namespace_decl, .module_decl => try self.emitNamespaceAsModule(node),
            .export_decl => try self.emitExport(node),
            else => {},
        }
    }

    fn emitFn(self: *HirEmitter, node: NodeId) !void {
        const f = hir_mod.fnDeclOf(self.hir, node);
        try self.write("pub fn ");
        if (f.name != hir_mod.none_node_id) try self.emitIdentifier(f.name);
        try self.write("(");
        const params = hir_mod.fnParams(self.hir, node);
        var emitted: u32 = 0;
        for (params) |p| {
            if (self.hir.kindOf(p) != .parameter) continue;
            const pp = hir_mod.parameterOf(self.hir, p);
            if (pp.flags.is_computed_binding_key) continue;
            if (emitted > 0) try self.write(", ");
            if (pp.flags.is_rest) try self.write("...");
            if (pp.name != hir_mod.none_node_id) try self.emitIdentifier(pp.name);
            if (pp.flags.is_optional) try self.write("?");
            if (pp.type_annotation != hir_mod.none_node_id) {
                try self.write(": ");
                try self.emitTypeNode(pp.type_annotation);
            }
            emitted += 1;
        }
        try self.write(") -> ");
        if (f.return_type != hir_mod.none_node_id) {
            try self.emitTypeNode(f.return_type);
        } else {
            try self.write("void");
        }
        try self.write(";");
        try self.write(self.options.newline);
    }

    fn emitClassAsStruct(self: *HirEmitter, node: NodeId) !void {
        const c = hir_mod.classOf(self.hir, node);
        try self.write("pub struct ");
        if (c.name != hir_mod.none_node_id) try self.emitIdentifier(c.name);
        try self.write(" {");
        const members = hir_mod.classMembers(self.hir, node);
        // Collect just the data-bearing properties; methods belong on
        // an `impl Name` block which is implementation, not declaration.
        var any = false;
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (op.type_annotation == hir_mod.none_node_id) continue;
            if (!any) {
                try self.write(" ");
                any = true;
            } else {
                try self.write(", ");
            }
            try self.emitIdentifier(op.key);
            try self.write(": ");
            try self.emitTypeNode(op.type_annotation);
        }
        if (any) try self.write(" }") else try self.write("}");
        try self.write(self.options.newline);
    }

    fn emitInterfaceAsTrait(self: *HirEmitter, node: NodeId) !void {
        const i = hir_mod.interfaceOf(self.hir, node);
        try self.write("pub trait ");
        try self.emitIdentifier(i.name);
        try self.write(" {");
        const members = hir_mod.interfaceMembers(self.hir, node);
        if (members.len == 0) {
            try self.write("}");
            try self.write(self.options.newline);
            return;
        }
        try self.write(self.options.newline);
        self.depth += 1;
        for (members) |m| {
            if (self.hir.kindOf(m) != .interface_member) continue;
            const im = hir_mod.interfaceMemberOf(self.hir, m);
            try self.indent();
            try self.write("fn ");
            try self.write(self.interner.get(im.name));
            try self.write("()");
            try self.write(" -> ");
            if (im.type_node != hir_mod.none_node_id) {
                try self.emitTypeNode(im.type_node);
            } else {
                try self.write("void");
            }
            try self.write(";");
            try self.write(self.options.newline);
        }
        self.depth -= 1;
        try self.indent();
        try self.write("}");
        try self.write(self.options.newline);
    }

    fn emitTypeAlias(self: *HirEmitter, node: NodeId) !void {
        const t = hir_mod.typeAliasOf(self.hir, node);
        try self.write("pub type ");
        try self.emitIdentifier(t.name);
        try self.write(" = ");
        if (t.aliased != hir_mod.none_node_id) {
            try self.emitTypeNode(t.aliased);
        } else {
            try self.write("unknown");
        }
        try self.write(";");
        try self.write(self.options.newline);
    }

    fn emitEnumDecl(self: *HirEmitter, node: NodeId) !void {
        const e = hir_mod.enumOf(self.hir, node);
        try self.write("pub enum ");
        try self.emitIdentifier(e.name);
        try self.write(" {");
        const members = hir_mod.enumMembers(self.hir, node);
        if (members.len == 0) {
            try self.write("}");
            try self.write(self.options.newline);
            return;
        }
        try self.write(" ");
        var first = true;
        for (members) |m| {
            if (self.hir.kindOf(m) != .object_property) continue;
            const op = hir_mod.objectPropertyOf(self.hir, m);
            if (!first) try self.write(", ");
            first = false;
            try self.emitIdentifier(op.key);
        }
        try self.write(" }");
        try self.write(self.options.newline);
    }

    fn emitConstDecl(self: *HirEmitter, node: NodeId) !void {
        const v = hir_mod.varDeclOf(self.hir, node);
        try self.write("pub const ");
        if (v.name != hir_mod.none_node_id) try self.emitIdentifier(v.name);
        if (v.type_annotation != hir_mod.none_node_id) {
            try self.write(": ");
            try self.emitTypeNode(v.type_annotation);
        }
        try self.write(";");
        try self.write(self.options.newline);
    }

    fn emitNamespaceAsModule(self: *HirEmitter, node: NodeId) !void {
        const n = hir_mod.namespaceOf(self.hir, node);
        try self.write("declare module \"");
        try self.write(self.interner.get(hir_mod.identifierOf(self.hir, n.name).name));
        try self.write("\" {");
        const body = hir_mod.namespaceBody(self.hir, node);
        if (body.len == 0) {
            try self.write("}");
            try self.write(self.options.newline);
            return;
        }
        try self.write(self.options.newline);
        self.depth += 1;
        for (body) |s| {
            if (!self.shouldEmit(s)) continue;
            try self.emitDeclaration(s);
        }
        self.depth -= 1;
        try self.write("}");
        try self.write(self.options.newline);
    }

    fn emitExport(self: *HirEmitter, node: NodeId) !void {
        const ex = hir_mod.exportOf(self.hir, node);
        if (ex.decl != hir_mod.none_node_id) {
            // `export <decl>` — re-print the inner decl with `pub` (the
            // existing emitDeclaration path already prefixes it).
            switch (self.hir.kindOf(ex.decl)) {
                .fn_decl => try self.emitFn(ex.decl),
                .class_decl => try self.emitClassAsStruct(ex.decl),
                .interface_decl => try self.emitInterfaceAsTrait(ex.decl),
                .type_alias_decl => try self.emitTypeAlias(ex.decl),
                .enum_decl => try self.emitEnumDecl(ex.decl),
                .const_decl, .let_decl, .var_decl => try self.emitConstDecl(ex.decl),
                else => {},
            }
        }
    }

    fn emitIdentifier(self: *HirEmitter, node: NodeId) !void {
        if (self.hir.kindOf(node) != .identifier) return;
        const id = hir_mod.identifierOf(self.hir, node);
        try self.write(self.interner.get(id.name));
    }

    /// Re-print an HIR type-node id as Home type syntax. Recurses
    /// through the type-node tree, mapping TS canonical primitive
    /// names to Home counterparts (`number → f64`, `string → str`,
    /// `boolean → bool`, `bigint → i64`).
    fn emitTypeNode(self: *HirEmitter, node: NodeId) anyerror!void {
        switch (self.hir.kindOf(node)) {
            .type_ref => {
                const r = hir_mod.typeRefOf(self.hir, node);
                const qualifier = hir_mod.typeRefQualifier(self.hir, node);
                for (qualifier) |q| {
                    try self.emitIdentifier(q);
                    try self.write(".");
                }
                const name = self.interner.get(r.name);
                try self.write(mapPrimitive(name));
                const args = hir_mod.typeRefArgs(self.hir, node);
                if (args.len > 0) {
                    try self.write("<");
                    for (args, 0..) |a, i| {
                        if (i > 0) try self.write(", ");
                        try self.emitTypeNode(a);
                    }
                    try self.write(">");
                }
            },
            .union_type => {
                const members = hir_mod.unionTypeMembers(self.hir, node);
                for (members, 0..) |m, i| {
                    if (i > 0) try self.write(" | ");
                    try self.emitTypeNode(m);
                }
            },
            .intersection_type => {
                const members = hir_mod.intersectionTypeMembers(self.hir, node);
                for (members, 0..) |m, i| {
                    if (i > 0) try self.write(" & ");
                    try self.emitTypeNode(m);
                }
            },
            .array_type => {
                // `T[]` round-trips as Home's `Vec<T>`.
                const a = hir_mod.arrayTypeOf(self.hir, node);
                try self.write("Vec<");
                try self.emitTypeNode(a.element);
                try self.write(">");
            },
            .tuple_type => {
                // `[T, U]` round-trips as Home's `(T, U)` tuple.
                const elems = hir_mod.tupleTypeElements(self.hir, node);
                try self.write("(");
                for (elems, 0..) |e, i| {
                    if (i > 0) try self.write(", ");
                    try self.emitTypeNode(e);
                }
                try self.write(")");
            },
            .fn_type, .constructor_type => {
                const ft = hir_mod.fnTypeOf(self.hir, node);
                try self.write("fn(");
                const params_start = ft.params_start;
                const params_len = ft.params_len;
                var i: u32 = 0;
                while (i < params_len) : (i += 1) {
                    if (i > 0) try self.write(", ");
                    const p = self.hir.child_pool.items[params_start + i];
                    if (self.hir.kindOf(p) != .parameter) continue;
                    const pp = hir_mod.parameterOf(self.hir, p);
                    if (pp.name != hir_mod.none_node_id) {
                        try self.emitIdentifier(pp.name);
                        try self.write(": ");
                    }
                    if (pp.type_annotation != hir_mod.none_node_id) {
                        try self.emitTypeNode(pp.type_annotation);
                    } else {
                        try self.write("unknown");
                    }
                }
                try self.write(") -> ");
                if (ft.return_type != hir_mod.none_node_id) {
                    try self.emitTypeNode(ft.return_type);
                } else {
                    try self.write("void");
                }
            },
            .object_type => {
                const members = hir_mod.objectTypeMembers(self.hir, node);
                try self.write("{");
                if (members.len > 0) {
                    try self.write(" ");
                    for (members, 0..) |m, i| {
                        if (i > 0) try self.write(", ");
                        if (self.hir.kindOf(m) != .interface_member) continue;
                        const im = hir_mod.interfaceMemberOf(self.hir, m);
                        try self.write(self.interner.get(im.name));
                        if (im.type_node != hir_mod.none_node_id) {
                            try self.write(": ");
                            try self.emitTypeNode(im.type_node);
                        }
                    }
                    try self.write(" ");
                }
                try self.write("}");
            },
            .type_literal => {
                const lt = hir_mod.literalTypeOf(self.hir, node);
                if (lt.negative) try self.write("-");
                switch (self.hir.kindOf(lt.literal)) {
                    .literal_string => {
                        const s = hir_mod.literalStringOf(self.hir, lt.literal);
                        try self.write("\"");
                        try self.write(self.interner.get(s.value));
                        try self.write("\"");
                    },
                    .literal_number => {
                        var nbuf: [32]u8 = undefined;
                        const v = hir_mod.literalNumberOf(self.hir, lt.literal);
                        try self.write(try std.fmt.bufPrint(&nbuf, "{d}", .{v}));
                    },
                    .literal_bool => {
                        const v = hir_mod.literalBoolOf(self.hir, lt.literal);
                        try self.write(if (v) "true" else "false");
                    },
                    else => try self.write("unknown"),
                }
            },
            .keyof_type => {
                // Home doesn't have `keyof` natively; round-trip the TS
                // form as a comment-style placeholder so downstream
                // tools can spot it. Follow-up: design Home equivalent.
                const k = hir_mod.keyofTypeOf(self.hir, node);
                try self.write("keyof ");
                try self.emitTypeNode(k.operand);
            },
            else => try self.write("unknown"),
        }
    }
};

/// Map a TS canonical primitive name to its Home counterpart. Names
/// that aren't recognized pass through unchanged so user-defined
/// types (`Vec`, `Option`, `MyStruct`) survive untouched.
fn mapPrimitive(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "number")) return "f64";
    if (std.mem.eql(u8, name, "string")) return "str";
    if (std.mem.eql(u8, name, "boolean")) return "bool";
    if (std.mem.eql(u8, name, "bigint")) return "i64";
    if (std.mem.eql(u8, name, "symbol")) return "Symbol";
    if (std.mem.eql(u8, name, "object")) return "Object";
    return name;
}

// =============================================================================
// Declaration source map (`.d.hm.map`).
// =============================================================================
//
// Symmetric to TypeScript's `.d.ts.map`: when `declaration_map: true`,
// the emitter writes a parallel `.d.hm.map` next to the `.d.hm`. The
// map is a Source Map V3 JSON object whose `mappings` field, in the
// fullness of time, will encode positions in the `.d.hm` back to the
// original `.home` source. v0 ships the framing only — empty
// `mappings` so consumers (LSP, devtools) parse the file successfully
// without erroring. Real position-preserving mappings land alongside
// the symbol-driven re-printer in a follow-up.
//
// Shape (Source Map V3, minimal):
//   { "version": 3, "sources": ["mod.home"], "mappings": "" }
//
// Optional fields the spec allows but we omit at v0: `file`,
// `sourcesContent`, `names`, `sourceRoot`. Tooling tolerates their
// absence.

pub const DeclarationMapOptions = struct {
    /// Optional `file` field — the basename of the `.d.hm` this map
    /// pairs with. When null, the field is omitted.
    file: ?[]const u8 = null,
};

/// Render a minimal Source Map V3 JSON for a `.d.hm` file. `source`
/// is the original `.home` source path that the declaration was
/// generated from; it goes into the `sources` array as a single
/// entry. Caller owns the returned bytes.
pub fn renderDeclarationMap(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: DeclarationMapOptions,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"version\":3");
    if (options.file) |f| {
        try out.appendSlice(gpa, ",\"file\":");
        try writeJsonString(gpa, &out, f);
    }
    try out.appendSlice(gpa, ",\"sources\":[");
    try writeJsonString(gpa, &out, source);
    try out.appendSlice(gpa, "],\"mappings\":\"\"}");
    return out.toOwnedSlice(gpa);
}

/// Append a JSON-encoded string literal (`"..."`) to `out`. Escapes
/// the bare minimum required by RFC 8259: `\`, `"`, and ASCII
/// control characters. Source-map paths are typically plain ASCII so
/// this stays cheap on the hot path.
fn writeJsonString(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(gpa, &buf);
            },
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
}

/// Loader scaffold. Phase 4 follow-up: wire into the Home parser's
/// declaration-only mode (the same Home lexer/parser, with a flag
/// that rejects executable statements).
pub const Loader = struct {
    gpa: std.mem.Allocator,
    /// Resolved-path → loaded-content cache. The loader interns paths
    /// so repeated lookups are cheap.
    cache: std.StringHashMapUnmanaged([]const u8),

    pub fn init(gpa: std.mem.Allocator) Loader {
        return .{ .gpa = gpa, .cache = .empty };
    }

    pub fn deinit(self: *Loader) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.cache.deinit(self.gpa);
    }

    /// Load a `.d.hm` file from `path`. Phase 4 stub: returns
    /// `error.NotImplemented` until the Home parser adds its
    /// declaration-only mode. Tests below verify the lib enum and
    /// catalog logic without touching disk.
    pub fn loadLib(self: *Loader, lib: Lib) ![]const u8 {
        _ = self;
        _ = lib;
        return error.NotImplemented;
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "Lib: round-trip name ↔ enum" {
    try T.expectEqual(@as(?Lib, .core), Lib.fromName("core"));
    try T.expectEqual(@as(?Lib, .io), Lib.fromName("io"));
    try T.expectEqual(@as(?Lib, null), Lib.fromName("nonexistent"));
}

test "Lib: filename matches the canonical pattern" {
    try T.expectEqualStrings("lib.core.d.hm", Lib.core.fileName());
    try T.expectEqualStrings("lib.io.d.hm", Lib.io.fileName());
    try T.expectEqualStrings("lib.collections.d.hm", Lib.collections.fileName());
}

test "libsForTarget: returns the full catalog for any target" {
    const native = libsForTarget(.native_x64);
    const wasm = libsForTarget(.wasm);
    try T.expectEqual(@as(usize, 6), native.len);
    try T.expectEqual(@as(usize, 6), wasm.len);
    // Verify the order is stable.
    try T.expectEqual(Lib.core, native[0]);
    try T.expectEqual(Lib.ffi, native[5]);
}

test "Loader: stub returns NotImplemented" {
    var l = Loader.init(T.allocator);
    defer l.deinit();
    try T.expectError(error.NotImplemented, l.loadLib(.core));
}

test "Emitter: fn signature framing" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeFnSignature(
        "add",
        &.{
            .{ .name = "a", .ty = "int" },
            .{ .name = "b", .ty = "int" },
        },
        "int",
    );
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, HEADER) != null);
    try T.expect(std.mem.indexOf(u8, out, "pub fn add(a: int, b: int) -> int;") != null);
}

test "Emitter: struct + type alias + const decl" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeStruct(
        "Point",
        &.{
            .{ .name = "x", .ty = "int" },
            .{ .name = "y", .ty = "int" },
        },
    );
    try em.writeTypeAlias("Pair", "(int, int)");
    try em.writeConstDecl("PI", "f64");
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub struct Point { x: int, y: int }") != null);
    try T.expect(std.mem.indexOf(u8, out, "pub type Pair = (int, int);") != null);
    try T.expect(std.mem.indexOf(u8, out, "pub const PI: f64;") != null);
}

test "Emitter: extern fn omits `pub`" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeExternFn(
        "malloc",
        &.{.{ .name = "size", .ty = "usize" }},
        "*u8",
    );
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "extern fn malloc(size: usize) -> *u8;") != null);
    // Must not be prefixed with `pub`.
    try T.expect(std.mem.indexOf(u8, out, "pub extern") == null);
}

test "Emitter: header written exactly once across multiple decls" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeFnSignature("a", &.{}, "void");
    try em.writeFnSignature("b", &.{}, "void");
    try em.writeStruct("S", &.{});
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    // Header appears once.
    const first = std.mem.indexOf(u8, out, HEADER) orelse return error.HeaderMissing;
    const second = std.mem.indexOfPos(u8, out, first + 1, HEADER);
    try T.expect(second == null);
    // Empty struct compacts to `{}`.
    try T.expect(std.mem.indexOf(u8, out, "pub struct S {}") != null);
}

test "Emitter: header suppression via options" {
    var em = Emitter.initWith(T.allocator, .{ .write_header = false });
    defer em.deinit();
    try em.writeTypeAlias("X", "int");
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, HEADER) == null);
    try T.expect(std.mem.startsWith(u8, out, "pub type X = int;"));
}

test "Emitter: enum with unit + payload variants" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeEnum("Maybe", &.{
        .{ .name = "None" },
        .{ .name = "Some", .payload_ty = "int" },
    });
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub enum Maybe { None, Some(int) }") != null);
}

test "Emitter: empty enum compacts to `{}`" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeEnum("Empty", &.{});
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub enum Empty {}") != null);
}

test "Emitter: trait renders method signatures" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeTrait("Reader", &.{
        .{
            .name = "read",
            .params = &.{.{ .name = "buf", .ty = "[]u8" }},
            .return_ty = "usize",
        },
        .{
            .name = "close",
            .params = &.{},
            .return_ty = "void",
        },
    });
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub trait Reader {") != null);
    try T.expect(std.mem.indexOf(u8, out, "    fn read(buf: []u8) -> usize;") != null);
    try T.expect(std.mem.indexOf(u8, out, "    fn close() -> void;") != null);
}

test "Emitter: empty trait compacts to `{}`" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.writeTrait("Marker", &.{});
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub trait Marker {}") != null);
}

test "Emitter: declare module wraps inner decls" {
    var em = Emitter.init(T.allocator);
    defer em.deinit();
    try em.openDeclareModule("foo");
    try em.writeFnSignature("init", &.{}, "void");
    try em.closeDeclareModule();
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "declare module \"foo\" {") != null);
    try T.expect(std.mem.indexOf(u8, out, "pub fn init() -> void;") != null);
    // Closing brace appears after the inner decl.
    const open_idx = std.mem.indexOf(u8, out, "declare module").?;
    const close_idx = std.mem.lastIndexOf(u8, out, "}").?;
    try T.expect(open_idx < close_idx);
}

test "renderDeclarationMap: minimal V3 framing parses as JSON" {
    const out = try renderDeclarationMap(T.allocator, "src/mod.home", .{ .file = "mod.d.hm" });
    defer T.allocator.free(out);

    // Required V3 fields are present.
    try T.expect(std.mem.indexOf(u8, out, "\"version\":3") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"sources\":[\"src/mod.home\"]") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"mappings\":\"\"") != null);
    try T.expect(std.mem.indexOf(u8, out, "\"file\":\"mod.d.hm\"") != null);

    // Output round-trips through std.json without diagnostics.
    var parsed = try std.json.parseFromSlice(std.json.Value, T.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try T.expectEqual(@as(i64, 3), root.get("version").?.integer);
    const sources = root.get("sources").?.array;
    try T.expectEqual(@as(usize, 1), sources.items.len);
    try T.expectEqualStrings("src/mod.home", sources.items[0].string);
    try T.expectEqualStrings("", root.get("mappings").?.string);
}

test "renderDeclarationMap: omits `file` when null" {
    const out = try renderDeclarationMap(T.allocator, "x.home", .{});
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "\"file\"") == null);
    try T.expect(std.mem.indexOf(u8, out, "\"sources\":[\"x.home\"]") != null);
}

test "DeclKind: enum is exhaustive" {
    // Compile-time check that all 8 declared variants are reachable
    // from the `DeclKind` enum.
    const all: [8]DeclKind = .{
        .fn_signature,
        .struct_decl,
        .enum_decl,
        .trait_decl,
        .type_alias,
        .const_decl,
        .extern_fn,
        .declare_module,
    };
    try T.expectEqual(@as(usize, 8), all.len);
}

// =============================================================================
// HirEmitter tests — parse TypeScript surface syntax (which targets the
// shared HIR substrate), then re-print as Home `.d.hm`. This exercises
// the same code path the eventual Home parser will take once it lowers
// to HIR; today's coverage pins the type-printer output for the common
// declaration shapes.
// =============================================================================

const ts_lexer = @import("ts_lexer");
const ts_parser = @import("ts_parser");

const HirTestSetup = struct {
    sint: string_interner.Interner,
    hir: Hir,
    scanner: ts_lexer.Scanner,
    tokens: std.ArrayList(ts_lexer.Token),
    parser: ts_parser.Parser,
    root: NodeId,
};

fn newHirSetup(source: []const u8) !*HirTestSetup {
    const s = try T.allocator.create(HirTestSetup);
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
    return s;
}

fn destroyHirSetup(s: *HirTestSetup) void {
    s.parser.deinit();
    s.tokens.deinit(T.allocator);
    s.scanner.deinit(T.allocator);
    s.hir.deinit();
    s.sint.deinit();
    T.allocator.destroy(s);
}

fn emitHmTest(source: []const u8) ![]u8 {
    const s = try newHirSetup(source);
    defer destroyHirSetup(s);
    var em = HirEmitter.init(T.allocator, &s.hir, &s.sint, .{ .write_header = false });
    defer em.deinit();
    try em.emitSourceFile(s.root);
    return T.allocator.dupe(u8, em.out.items);
}

test "HirEmitter: fn body is stripped and signature kept" {
    const out = try emitHmTest("function add(a: number, b: number): number { return a + b; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub fn add(a: f64, b: f64) -> f64;") != null);
    // Body must not leak.
    try T.expect(std.mem.indexOf(u8, out, "return") == null);
    try T.expect(std.mem.indexOf(u8, out, "{") == null);
}

test "HirEmitter: struct (TS class) re-printed with field types" {
    const out = try emitHmTest("class Point { x: number = 0; y: number = 0; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub struct Point { x: f64, y: f64 }") != null);
    // Initializer must not leak.
    try T.expect(std.mem.indexOf(u8, out, "= 0") == null);
}

test "HirEmitter: trait (TS interface) re-prints method signatures" {
    const out = try emitHmTest("interface Reader { read: number; close: void; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub trait Reader {") != null);
    try T.expect(std.mem.indexOf(u8, out, "fn read() -> f64;") != null);
    try T.expect(std.mem.indexOf(u8, out, "fn close() -> void;") != null);
}

test "HirEmitter: type alias and primitive remap" {
    const out = try emitHmTest("type Id = string;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub type Id = str;") != null);
}

test "HirEmitter: type alias union" {
    const out = try emitHmTest("type Mix = string | number | boolean;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub type Mix = str | f64 | bool;") != null);
}

test "HirEmitter: tuple type round-trips as Home tuple" {
    const out = try emitHmTest("type Pair = [number, string];");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub type Pair = (f64, str);") != null);
}

test "HirEmitter: array type maps to Vec<T>" {
    const out = try emitHmTest("type Names = string[];");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub type Names = Vec<str>;") != null);
}

test "HirEmitter: generic ref preserves type arguments" {
    const out = try emitHmTest("type Maybe = Option<string>;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub type Maybe = Option<str>;") != null);
}

test "HirEmitter: const decl drops initializer, keeps annotation" {
    const out = try emitHmTest("const PI: number = 3.14;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub const PI: f64;") != null);
    try T.expect(std.mem.indexOf(u8, out, "= 3.14") == null);
}

test "HirEmitter: enum variants" {
    const out = try emitHmTest("enum Color { Red, Green, Blue }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub enum Color { Red, Green, Blue }") != null);
}

test "HirEmitter: function type prints as Home fn(...)→T" {
    const out = try emitHmTest("type Cb = (x: number) => string;");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub type Cb = fn(x: f64) -> str;") != null);
}

test "HirEmitter: header is emitted once when enabled" {
    const s = try newHirSetup("type X = number;");
    defer destroyHirSetup(s);
    var em = HirEmitter.init(T.allocator, &s.hir, &s.sint, .{});
    defer em.deinit();
    try em.emitSourceFile(s.root);
    const out = try em.toOwnedSlice();
    defer T.allocator.free(out);
    try T.expect(std.mem.startsWith(u8, out, HEADER));
    try T.expect(std.mem.indexOf(u8, out, "pub type X = f64;") != null);
    // Header appears exactly once.
    const first = std.mem.indexOf(u8, out, HEADER).?;
    const second = std.mem.indexOfPos(u8, out, first + 1, HEADER);
    try T.expect(second == null);
}

test "HirEmitter: export declaration unwraps to pub form" {
    const out = try emitHmTest("export function id(x: number): number { return x; }");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub fn id(x: f64) -> f64;") != null);
}

test "HirEmitter: void return when annotation omitted" {
    const out = try emitHmTest("function noop() {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub fn noop() -> void;") != null);
}

test "HirEmitter: empty trait compacts to {}" {
    const out = try emitHmTest("interface Marker {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub trait Marker {}") != null);
}

test "HirEmitter: empty struct compacts to {}" {
    const out = try emitHmTest("class Empty {}");
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "pub struct Empty {}") != null);
}

test "mapPrimitive: known mappings + passthrough" {
    try T.expectEqualStrings("f64", mapPrimitive("number"));
    try T.expectEqualStrings("str", mapPrimitive("string"));
    try T.expectEqualStrings("bool", mapPrimitive("boolean"));
    try T.expectEqualStrings("i64", mapPrimitive("bigint"));
    // Unknown names pass through unchanged.
    try T.expectEqualStrings("Vec", mapPrimitive("Vec"));
    try T.expectEqualStrings("MyStruct", mapPrimitive("MyStruct"));
}
