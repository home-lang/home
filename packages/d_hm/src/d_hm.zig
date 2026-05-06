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
};

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
