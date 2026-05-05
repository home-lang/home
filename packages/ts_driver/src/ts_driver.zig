//! TS compiler driver — wires lex → parse → bind → emit.
//!
//! Phase 4.5 deliverable for TS_PARITY_PLAN: the single API surface
//! a CLI / LSP / bundler invokes to compile a TS source string into
//! JS output (plus diagnostics + the bound symbol table).
//!
//! Phase 4.5 ships single-file end-to-end compilation. Multi-file,
//! module-graph, and incremental flows are layered on top in Phase 5
//! once the driver is wired into the query DB.

const std = @import("std");
const ts_lexer = @import("ts_lexer");
const ts_parser = @import("ts_parser");
const hir_mod = @import("hir");
const string_interner = @import("string_interner");
const binder = @import("binder");
const ts_emit = @import("ts_emit");

pub const NodeId = hir_mod.NodeId;
pub const Hir = hir_mod.Hir;
pub const Token = ts_lexer.Token;

/// One unified diagnostic across all phases.
pub const Diagnostic = struct {
    pub const Phase = enum { lex, parse, bind, emit };
    phase: Phase,
    pos: u32,
    line: u32,
    message: []const u8,
};

/// Result of compiling a single source string. The caller takes
/// ownership of `js` (the emitted JavaScript) and `diagnostics`. The
/// supporting structures (HIR, interner, scope graph) stay live so
/// the LSP can walk them; call `Compilation.deinit` to release them.
pub const Compilation = struct {
    gpa: std.mem.Allocator,
    /// Original source (caller-owned slice; we keep a pointer for
    /// span->bytes lookups in tests / diagnostics). NOT freed by
    /// `deinit`.
    source: []const u8,
    interner: string_interner.Interner,
    hir: Hir,
    /// Tokens produced by the scanner — kept so spans can be
    /// re-resolved to source bytes.
    tokens: std.ArrayList(Token),
    /// Root node id of the parsed source file.
    root: NodeId,
    /// Bound module (symbols + scope graph). Owned via its own arena.
    module: *binder.Module,
    /// Emitted JavaScript text.
    js: []u8,
    /// All diagnostics from every phase, in source order.
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    /// True if any phase produced an error-level diagnostic.
    has_errors: bool,

    pub fn deinit(self: *Compilation) void {
        self.gpa.free(self.js);
        self.diagnostics.deinit(self.gpa);
        self.module.deinit();
        self.gpa.destroy(self.module);
        self.tokens.deinit(self.gpa);
        self.hir.deinit();
        self.interner.deinit();
    }

    /// Look up a symbol by name in the module-level scope. Returns
    /// null when unbound.
    pub fn lookupTopLevel(self: *Compilation, name: []const u8) ?*binder.Symbol {
        const id = self.interner.lookup(name) orelse return null;
        return self.module.root.values.get(id) orelse self.module.root.types.get(id) orelse self.module.root.namespaces.get(id);
    }
};

pub const CompileOptions = struct {
    /// File id for diagnostics + module identity.
    file_id: u32 = 0,
    /// JS emit options (indent, newline, semicolon style).
    emit: ts_emit.Options = .{},
    /// If true, errors during emit fall back to "best effort" — we
    /// emit what we have and record the diagnostic.
    continue_on_error: bool = true,
    /// Treat the source as `.tsx` — enables JSX parsing.
    is_tsx: bool = false,
};

pub const CompileError = error{
    OutOfMemory,
    LexError,
    ParseError,
    BindError,
    EmitError,
};

/// Compile a TS source string end-to-end. The caller owns the
/// returned `Compilation` and must call `deinit` on it.
pub fn compileSource(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: CompileOptions,
) CompileError!*Compilation {
    const c = gpa.create(Compilation) catch return error.OutOfMemory;
    errdefer gpa.destroy(c);

    c.* = .{
        .gpa = gpa,
        .source = source,
        .interner = undefined,
        .hir = undefined,
        .tokens = undefined,
        .root = hir_mod.none_node_id,
        .module = undefined,
        .js = &.{},
        .diagnostics = .empty,
        .has_errors = false,
    };

    c.interner = string_interner.Interner.init(gpa) catch return error.OutOfMemory;
    errdefer c.interner.deinit();

    c.hir = hir_mod.Hir.init(gpa) catch return error.OutOfMemory;
    errdefer c.hir.deinit();

    // ------ Lex ------
    var scanner = ts_lexer.Scanner.init(gpa, source);
    defer scanner.deinit(gpa);
    c.tokens = scanner.tokenize(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Lex error — record, continue with empty tokens.
            c.has_errors = true;
            return c;
        },
    };
    errdefer c.tokens.deinit(gpa);

    // Drain scanner diagnostics.
    for (scanner.diagnostics.items) |d| {
        try c.diagnostics.append(gpa, .{
            .phase = .lex,
            .pos = d.pos,
            .line = d.line,
            .message = try gpa.dupe(u8, d.message),
        });
        c.has_errors = true;
    }

    // ------ Parse ------
    var parser = ts_parser.Parser.init(gpa, &c.hir, &c.interner, source, c.tokens.items);
    parser.setTsx(options.is_tsx);
    defer parser.deinit();

    c.root = parser.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            c.has_errors = true;
            // Use a synthesized empty block as the root so downstream
            // phases have something safe to walk.
            var b = hir_mod.Builder.init(&c.hir);
            defer b.deinit();
            break :blk b.addBlock(.{ .start = 0, .end = 0 }, &.{}) catch hir_mod.none_node_id;
        },
    };
    for (parser.diagnostics.items) |d| {
        try c.diagnostics.append(gpa, .{
            .phase = .parse,
            .pos = d.pos,
            .line = d.line,
            .message = try gpa.dupe(u8, d.message),
        });
        c.has_errors = true;
    }

    // ------ Bind ------
    var bind = binder.Binder.init(gpa, &c.hir, &c.interner, options.file_id) catch return error.OutOfMemory;
    errdefer {
        bind.module.deinit();
        gpa.destroy(bind.module);
        bind.deinit();
    }

    bind.bindSourceFile(c.root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            c.has_errors = true;
        },
    };
    for (bind.diagnostics.items) |d| {
        try c.diagnostics.append(gpa, .{
            .phase = .bind,
            .pos = 0,
            .line = 0,
            .message = try gpa.dupe(u8, d.message),
        });
        c.has_errors = true;
    }
    c.module = bind.module;
    bind.deinit();
    // Own bind no longer drops module on errdefer.

    // ------ Emit ------
    var printer = ts_emit.Printer.init(gpa, &c.hir, &c.interner, options.emit);
    defer printer.deinit();
    if (c.root != hir_mod.none_node_id) {
        printer.printSourceFile(c.root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (!options.continue_on_error) return error.EmitError;
                try c.diagnostics.append(gpa, .{
                    .phase = .emit,
                    .pos = 0,
                    .line = 0,
                    .message = try gpa.dupe(u8, "emit error"),
                });
                c.has_errors = true;
            },
        };
    }
    c.js = printer.toOwnedSlice() catch return error.OutOfMemory;

    return c;
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "driver: empty source produces empty JS" {
    var c = try compileSource(T.allocator, "", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expectEqualStrings("", c.js);
    try T.expect(!c.has_errors);
}

test "driver: simple let binding round-trips" {
    var c = try compileSource(T.allocator, "let x = 42;", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expectEqualStrings("let x = 42;", c.js);
    try T.expect(!c.has_errors);
    // Symbol table is populated.
    const sym = c.lookupTopLevel("x") orelse return error.NoSymbol;
    try T.expect(sym.flags.is_let);
}

test "driver: type annotations erase in JS output" {
    var c = try compileSource(T.allocator, "let x: number = 1;", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expectEqualStrings("let x = 1;", c.js);
}

test "driver: function with generics" {
    var c = try compileSource(T.allocator, "function id<T>(x: T): T { return x; }", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "function id(x)") != null);
    try T.expect(std.mem.indexOf(u8, c.js, "return x;") != null);
    const sym = c.lookupTopLevel("id") orelse return error.NoSym;
    try T.expect(sym.flags.is_function);
}

test "driver: arrow function" {
    var c = try compileSource(T.allocator, "let inc = (n: number) => n + 1;", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "let inc = (n) => (n + 1);") != null);
}

test "driver: interfaces erase, classes don't" {
    var c = try compileSource(T.allocator,
        \\interface Greet { hi(): void; }
        \\class Hello { greet() { return "hi"; } }
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "Greet") == null);
    try T.expect(std.mem.indexOf(u8, c.js, "class Hello") != null);
    const cls = c.lookupTopLevel("Hello") orelse return error.NoCls;
    try T.expect(cls.flags.is_class);
}

test "driver: imports survive type-erasure" {
    var c = try compileSource(T.allocator, "import { useState, type FC } from \"react\";", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // Outer import is *not* type-only, so it emits.
    try T.expect(std.mem.indexOf(u8, c.js, "import {") != null);
    try T.expect(std.mem.indexOf(u8, c.js, "react") != null);
}

test "driver: type-only import erases entirely" {
    var c = try compileSource(T.allocator, "import type { FC } from \"react\";", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expectEqualStrings("", c.js);
}

test "driver: control flow round-trips" {
    var c = try compileSource(T.allocator,
        \\function abs(n: number): number {
        \\  if (n < 0) return -n;
        \\  return n;
        \\}
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "function abs") != null);
    try T.expect(std.mem.indexOf(u8, c.js, "if (") != null);
    try T.expect(std.mem.indexOf(u8, c.js, "return") != null);
}

test "driver: tsx self-closing emits createElement" {
    var c = try compileSource(T.allocator, "let v = <Foo bar=\"baz\" />;", .{ .is_tsx = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "React.createElement(Foo") != null);
    try T.expect(std.mem.indexOf(u8, c.js, "bar: \"baz\"") != null);
}

test "driver: tsx lowercase tag emits string" {
    var c = try compileSource(T.allocator, "let v = <div className=\"x\" />;", .{ .is_tsx = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "React.createElement(\"div\"") != null);
}

test "driver: tsx fragment" {
    var c = try compileSource(T.allocator, "let v = <>{a}{b}</>;", .{ .is_tsx = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "React.Fragment") != null);
}

test "driver: classes with constructors and methods" {
    var c = try compileSource(T.allocator,
        \\class Counter {
        \\  count: number = 0;
        \\  inc(): number { this.count = this.count + 1; return this.count; }
        \\}
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "class Counter") != null);
    try T.expect(std.mem.indexOf(u8, c.js, "inc(") != null);
}
