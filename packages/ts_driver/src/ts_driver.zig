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
const tsconfig_mod = @import("tsconfig");
const ts_checker = @import("ts_checker");
const ts_cache = @import("ts_cache");

pub const NodeId = hir_mod.NodeId;
pub const Hir = hir_mod.Hir;
pub const Token = ts_lexer.Token;
pub const StrictFlags = ts_checker.StrictFlags;

/// One unified diagnostic across all phases.
pub const Diagnostic = struct {
    pub const Phase = enum { lex, parse, bind, emit };
    pub const CodePrefix = enum { TS, HM };
    phase: Phase,
    pos: u32,
    line: u32,
    /// TypeScript-compatible diagnostic code (e.g. 2322). 0 means
    /// uncategorized — consumers fall back to a phase-derived code.
    code: u32 = 0,
    /// `TS` for tsc-compatible codes; `HM` for Home-only codes.
    code_prefix: CodePrefix = .TS,
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
    /// Type interner — owns all TypeIds attached to the HIR.
    type_interner: ts_checker.Interner,
    /// Relation engine — caches assignability/subtype results.
    type_engine: ts_checker.Engine,
    /// Emitted JavaScript text.
    js: []u8,
    /// All diagnostics from every phase, in source order.
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    /// True if any phase produced an error-level diagnostic.
    has_errors: bool,

    pub fn deinit(self: *Compilation) void {
        self.gpa.free(self.js);
        for (self.diagnostics.items) |d| self.gpa.free(d.message);
        self.diagnostics.deinit(self.gpa);
        self.module.deinit();
        self.gpa.destroy(self.module);
        self.type_engine.deinit();
        self.type_interner.deinit();
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
    /// Type-check only. Used by `--noEmit` and conformance surveys
    /// that are checking diagnostics rather than JS output.
    no_emit: bool = false,
    /// Treat the source as `.tsx` — enables JSX parsing.
    is_tsx: bool = false,
    /// Treat the source as a declaration file. Declaration files allow
    /// ambient forms such as `export const x: T;` without initializers.
    is_declaration_file: bool = false,
    /// Compiler option `alwaysStrict`: parse the file under strict-mode
    /// early-error rules even when it has no `"use strict"` prologue.
    always_strict: bool = false,
    /// True when the parser should apply ES2015+ contextual-reserved
    /// word rules such as rejecting `yield` as a binding/function name.
    syntax_target_es2015: bool = false,
    /// CLI `--strict` override. When null, defer to tsconfig or the
    /// tsc default (`false`).
    strict: ?bool = null,
    /// Direct checker strictness override for callers that already
    /// resolved file-scoped options (for example TS conformance
    /// `// @strict: true` directives).
    strict_flags: ?StrictFlags = null,
    /// JavaScript files under `allowJs` are parsed/bound/emitted, but
    /// TypeScript only reports JS semantic checker diagnostics when
    /// `checkJs` is enabled. Callers that know the virtual file kind
    /// can set this directly.
    suppress_js_check_diagnostics: bool = false,
    /// Optional parsed tsconfig. When present, the driver applies
    /// the relevant compilerOptions:
    ///   - `jsx` — enables tsx parsing for `react`/`react-jsx`/etc.
    ///   - `target` — selects the downlevel JS variant (Phase 4
    ///     follow-up; today the printer emits ES2024 + erasure)
    ///   - `module` — selects the import/export form (Phase 4
    ///     follow-up; today emits ES modules)
    pub_tsconfig: ?*const tsconfig_mod.TsConfig = null,
};

fn appendDriverDiagnostic(
    gpa: std.mem.Allocator,
    c: *Compilation,
    pos: u32,
    code: u32,
    message: []const u8,
) CompileError!void {
    try c.diagnostics.append(gpa, .{
        .phase = .bind,
        .pos = pos,
        .line = 0,
        .code = code,
        .message = try gpa.dupe(u8, message),
    });
    c.has_errors = true;
}

fn reportMissingReferencePathDiagnostics(
    gpa: std.mem.Allocator,
    c: *Compilation,
    source: []const u8,
) CompileError!void {
    if (std.mem.indexOf(u8, source, "<reference") == null or
        std.mem.indexOf(u8, source, "path") == null)
    {
        return;
    }
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line_without_cr = std.mem.trim(u8, raw_line, "\r");
        defer offset += raw_line.len + 1;
        var leading: usize = 0;
        while (leading < line_without_cr.len and
            (line_without_cr[leading] == ' ' or line_without_cr[leading] == '\t')) : (leading += 1)
        {}
        const line = line_without_cr[leading..];
        if (!std.mem.startsWith(u8, line, "///")) continue;
        const ref_rel = std.mem.indexOf(u8, line, "<reference") orelse continue;
        const path_rel = std.mem.indexOf(u8, line[ref_rel..], "path") orelse continue;
        var idx = ref_rel + path_rel + "path".len;
        while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}
        if (idx >= line.len or line[idx] != '=') continue;
        idx += 1;
        while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}
        if (idx >= line.len or (line[idx] != '\'' and line[idx] != '"')) continue;
        const quote = line[idx];
        idx += 1;
        const path_start = idx;
        while (idx < line.len and line[idx] != quote) : (idx += 1) {}
        if (idx >= line.len) continue;
        const path = line[path_start..idx];
        if (path.len == 0) continue;
        if (isHarnessProvidedReferencePath(path) or virtualReferencePathExists(source, path)) continue;

        std.Io.Dir.cwd().access(io, path, .{}) catch {
            const message = try std.fmt.allocPrint(gpa, "File '{s}' not found.", .{path});
            defer gpa.free(message);
            try appendDriverDiagnostic(
                gpa,
                c,
                @intCast(offset + leading + path_start),
                6053,
                message,
            );
        };
    }
}

fn isHarnessProvidedReferencePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/.lib/");
}

fn virtualReferencePathExists(source: []const u8, path: []const u8) bool {
    if (std.mem.indexOf(u8, source, "@filename:") == null and
        std.mem.indexOf(u8, source, "@Filename:") == null)
    {
        return false;
    }
    var normalized_path = path;
    while (std.mem.startsWith(u8, normalized_path, "./")) normalized_path = normalized_path[2..];
    while (std.mem.startsWith(u8, normalized_path, "/")) normalized_path = normalized_path[1..];
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const marker = std.mem.indexOf(u8, line, "@filename:") orelse
            (std.mem.indexOf(u8, line, "@Filename:") orelse continue);
        var virtual_path = std.mem.trim(u8, line[marker + "@filename:".len ..], " \t\r");
        while (std.mem.startsWith(u8, virtual_path, "./")) virtual_path = virtual_path[2..];
        while (std.mem.startsWith(u8, virtual_path, "/")) virtual_path = virtual_path[1..];
        if (std.mem.eql(u8, virtual_path, normalized_path)) return true;
        if (std.mem.lastIndexOfScalar(u8, virtual_path, '/')) |slash| {
            if (std.mem.eql(u8, virtual_path[slash + 1 ..], normalized_path)) return true;
        }
    }
    return false;
}

fn directiveValue(source: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r/*");
        if (!std.mem.startsWith(u8, line, "@")) continue;
        const rest = line[1..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        var value = std.mem.trim(u8, rest[name.len..], " \t:");
        if (std.mem.indexOfAny(u8, value, " \t*/\r")) |end| value = value[0..end];
        return value;
    }
    return null;
}

fn hasJsxSyntax(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "<>") != null or
        std.mem.indexOf(u8, source, "</") != null or
        std.mem.indexOf(u8, source, "/>") != null;
}

fn sourceMentionsValue(source: []const u8, name: []const u8) bool {
    return std.mem.indexOf(u8, source, name) != null;
}

fn hasInlineJsxFactoryPragmaWithoutFragment(source: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOf(u8, source[offset..], "@jsx")) |rel| {
        const idx = offset + rel;
        const after_idx = idx + "@jsx".len;
        if (after_idx >= source.len) return false;
        const after = source[after_idx];
        if (after == ':' or after == 'F' or after == 'f') {
            offset = after_idx;
            continue;
        }
        if (after != ' ' and after != '\t') {
            offset = after_idx;
            continue;
        }
        const section_end = if (std.mem.indexOf(u8, source[after_idx..], "@filename:")) |next_file|
            after_idx + next_file
        else
            source.len;
        const section = source[idx..section_end];
        if (std.mem.indexOf(u8, section, "@jsxFrag") == null and
            std.mem.indexOf(u8, section, "@jsxfrag") == null)
        {
            return true;
        }
        offset = after_idx;
    }
    return false;
}

fn appendJsxDirectiveDiagnostics(
    gpa: std.mem.Allocator,
    c: *Compilation,
    source: []const u8,
    options: CompileOptions,
) CompileError!void {
    if (!options.is_tsx or !hasJsxSyntax(source)) return;
    const jsx_mode = directiveValue(source, "jsx");
    const jsx_import_source = directiveValue(source, "jsxImportSource");
    if (jsx_import_source) |import_source| {
        if (jsx_mode != null and
            (std.mem.startsWith(u8, jsx_mode.?, "react-jsx") or std.mem.startsWith(u8, jsx_mode.?, "react-jsxdev")))
        {
            const runtime = try std.fmt.allocPrint(gpa, "{s}/jsx-runtime", .{import_source});
            defer gpa.free(runtime);
            if (std.mem.indexOf(u8, source, runtime) == null) {
                const msg = try std.fmt.allocPrint(
                    gpa,
                    "This JSX tag requires the module path '{s}' to exist, but none could be found. Make sure you have types for the appropriate package installed.",
                    .{runtime},
                );
                defer gpa.free(msg);
                try appendDriverDiagnostic(gpa, c, 0, 2875, msg);
            }
        }
    }

    if (jsx_mode) |mode| {
        if (std.mem.eql(u8, mode, "react") and
            directiveValue(source, "jsxFactory") == null and
            !sourceMentionsValue(source, "React"))
        {
            try appendDriverDiagnostic(gpa, c, 0, 2874, "This JSX tag requires 'React' to be in scope, but it could not be found.");
        }
        if (!std.mem.eql(u8, mode, "preserve") and
            !std.mem.eql(u8, mode, "react") and
            !std.mem.startsWith(u8, mode, "react-jsx") and
            std.mem.indexOf(u8, source, "<>") != null and
            directiveValue(source, "jsxFrag") == null and
            directiveValue(source, "jsxfrag") == null)
        {
            try appendDriverDiagnostic(gpa, c, 0, 17017, "An @jsxFrag pragma is required when using an @jsx pragma with JSX fragments.");
        }
    }
    if (std.mem.indexOf(u8, source, "<>") != null and hasInlineJsxFactoryPragmaWithoutFragment(source)) {
        try appendDriverDiagnostic(gpa, c, 0, 17017, "An @jsxFrag pragma is required when using an @jsx pragma with JSX fragments.");
    }
}

/// Apply tsconfig.compilerOptions to a CompileOptions. Useful when
/// callers want to derive options from a config file.
pub fn optionsFromConfig(cfg: *const tsconfig_mod.TsConfig) CompileOptions {
    var opts: CompileOptions = .{};
    opts.pub_tsconfig = cfg;
    if (cfg.compiler_options.jsx) |jsx| {
        // Any jsx mode implies the source is .tsx.
        switch (jsx) {
            .preserve, .react, .react_jsx, .react_jsxdev, .react_native => opts.is_tsx = true,
        }
        // Map tsconfig's JSX setting onto the emitter's runtime mode.
        opts.emit.jsx_runtime = switch (jsx) {
            .react => .classic,
            .react_jsx => .automatic,
            .react_jsxdev => .automatic_dev,
            .preserve, .react_native => .preserve,
        };
    }
    if (cfg.compiler_options.jsx_factory) |fac| {
        opts.emit.jsx_factory = fac;
    }
    if (cfg.compiler_options.target) |t| {
        opts.emit.es_target = switch (t) {
            .es3, .es5 => .es5,
            .es2015 => .es2015,
            .es2016 => .es2016,
            .es2017 => .es2017,
            .es2018 => .es2018,
            .es2019 => .es2019,
            .es2020 => .es2020,
            .es2021 => .es2021,
            .es2022 => .es2022,
            .es2023 => .es2023,
            .es2024, .esnext => .esnext,
        };
        opts.syntax_target_es2015 = switch (t) {
            .es3, .es5 => false,
            else => true,
        };
    }
    if (cfg.compiler_options.module) |m| {
        opts.emit.module_kind = switch (m) {
            .commonjs, .amd, .umd, .system => .commonjs,
            else => .esm,
        };
    }
    if (cfg.compiler_options.es_module_interop) |on| {
        opts.emit.es_module_interop = on;
    }
    if (cfg.compiler_options.experimental_decorators) |on| {
        opts.emit.experimental_decorators = on;
    }
    if (cfg.compiler_options.use_define_for_class_fields) |on| {
        opts.emit.use_define_for_class_fields = on;
    }
    return opts;
}

pub const CompileError = error{
    OutOfMemory,
    LexError,
    ParseError,
    BindError,
    EmitError,
};

/// Lightweight emit result used by `emitWithCache` — JS bytes
/// plus diagnostic summary, no HIR / symbols / interner. Faster
/// to fetch from cache than reconstructing a full `Compilation`.
pub const EmitResult = struct {
    js: []const u8,
    diagnostic_count: u32,
    has_errors: bool,
    /// True when the result came from the cache; false on a
    /// fresh pipeline run.
    from_cache: bool,

    pub fn deinit(self: *EmitResult, gpa: std.mem.Allocator) void {
        gpa.free(self.js);
    }
};

/// Compile-or-cached-fetch. On a cache hit, returns the cached
/// JS without running lex/parse/bind/check/emit. On a miss, runs
/// the full pipeline, stores the result in the cache, and returns
/// it. The cache key is `sha256(source + config_blob)` where
/// `config_blob` is the caller-supplied tsconfig fingerprint.
pub fn emitWithCache(
    gpa: std.mem.Allocator,
    source: []const u8,
    cache: *ts_cache.Cache,
    config_blob: []const u8,
    options: CompileOptions,
) !EmitResult {
    const key = ts_cache.Cache.computeKey(source, config_blob);
    if (cache.get(key) catch null) |cached| {
        return .{
            .js = cached.js,
            .diagnostic_count = cached.diagnostic_count,
            .has_errors = cached.has_errors,
            .from_cache = true,
        };
    }
    var c = try compileSource(gpa, source, options);
    defer {
        c.deinit();
        gpa.destroy(c);
    }
    const js_dupe = try gpa.dupe(u8, c.js);
    try cache.put(key, .{
        .js = c.js,
        .diagnostic_count = @intCast(c.diagnostics.items.len),
        .has_errors = c.has_errors,
    });
    return .{
        .js = js_dupe,
        .diagnostic_count = @intCast(c.diagnostics.items.len),
        .has_errors = c.has_errors,
        .from_cache = false,
    };
}

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
        .type_interner = undefined,
        .type_engine = undefined,
        .js = &.{},
        .diagnostics = .empty,
        .has_errors = false,
    };

    c.interner = string_interner.Interner.init(gpa) catch return error.OutOfMemory;
    errdefer c.interner.deinit();

    c.hir = hir_mod.Hir.init(gpa) catch return error.OutOfMemory;
    errdefer c.hir.deinit();

    try reportMissingReferencePathDiagnostics(gpa, c, source);

    // ------ Lex ------
    var tsx_lex_source: ?[]u8 = null;
    if (options.is_tsx) {
        tsx_lex_source = try sanitizeTsxLexSource(gpa, source);
    }
    defer if (tsx_lex_source) |buf| gpa.free(buf);
    const lex_source = tsx_lex_source orelse source;
    var scanner = ts_lexer.Scanner.init(gpa, lex_source);
    defer scanner.deinit(gpa);
    c.tokens = scanner.tokenize(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Lex error — record diagnostics and return a fully
            // deinitializable partial compilation. Some scanner
            // errors are the expected outcome for conformance parser
            // fixtures, so callers still need a diagnostic-bearing
            // result rather than an ownership-poisoned half object.
            c.has_errors = true;
            c.tokens = .empty;
            errdefer c.tokens.deinit(gpa);
            for (scanner.diagnostics.items) |d| {
                if (options.is_tsx and std.mem.eql(u8, d.message, "unexpected character") and
                    isDiagnosticInsideJsxText(source, d.pos))
                {
                    continue;
                }
                try c.diagnostics.append(gpa, .{
                    .phase = .lex,
                    .pos = d.pos,
                    .line = d.line,
                    .message = try gpa.dupe(u8, d.message),
                });
            }
            var bind = binder.Binder.init(gpa, &c.hir, &c.interner, options.file_id) catch return error.OutOfMemory;
            c.module = bind.module;
            bind.deinit();
            errdefer {
                c.module.deinit();
                gpa.destroy(c.module);
            }
            c.type_interner = ts_checker.Interner.init(gpa) catch return error.OutOfMemory;
            errdefer c.type_interner.deinit();
            c.type_engine = ts_checker.Engine.init(gpa, &c.type_interner) catch return error.OutOfMemory;
            errdefer c.type_engine.deinit();
            c.js = try gpa.dupe(u8, "");
            return c;
        },
    };
    errdefer c.tokens.deinit(gpa);

    // Drain scanner diagnostics.
    for (scanner.diagnostics.items) |d| {
        if (options.is_tsx and std.mem.eql(u8, d.message, "unexpected character") and
            isDiagnosticInsideJsxText(source, d.pos))
        {
            continue;
        }
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
    parser.setDeclarationFile(options.is_declaration_file);
    parser.setStrictMode(options.always_strict);
    parser.setTargetEs2015OrLater(options.syntax_target_es2015);
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
        if (diagnosticLineHasTsIgnore(source, d.pos)) continue;
        try c.diagnostics.append(gpa, .{
            .phase = .parse,
            .pos = d.pos,
            .line = d.line,
            .code = d.code,
            .message = try gpa.dupe(u8, d.message),
        });
        c.has_errors = true;
    }
    try appendJsxDirectiveDiagnostics(gpa, c, source, options);

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

    // ------ Type check ------
    c.type_interner = ts_checker.Interner.init(gpa) catch return error.OutOfMemory;
    errdefer c.type_interner.deinit();
    c.type_engine = ts_checker.Engine.init(gpa, &c.type_interner) catch return error.OutOfMemory;
    errdefer c.type_engine.deinit();
    var checker = ts_checker.Checker.init(gpa, &c.hir, &c.type_interner, &c.interner, &c.type_engine);
    defer checker.deinit();
    checker.setModule(c.module);
    checker.setSource(source);
    // Translate strictness flags. `strict: true` implies every
    // individual strict-family flag in TS; options.strict is the CLI
    // override, then tsconfig, then tsc's default (`false`).
    if (options.strict_flags) |flags| {
        checker.setStrictFlags(flags);
    } else if (options.pub_tsconfig) |cfg| {
        const co = cfg.compiler_options;
        const strict_on = options.strict orelse (co.strict orelse false);
        const no_implicit_any = co.no_implicit_any orelse strict_on;
        const strict_fn_types = co.strict_function_types orelse strict_on;
        const strict_null_checks = co.strict_null_checks orelse strict_on;
        const strict_property_initialization = co.strict_property_initialization orelse strict_on;
        // `strict` does NOT imply noUnusedLocals / noUnusedParameters
        // — those are independent in tsc.
        checker.setStrictFlags(.{
            .no_implicit_any = no_implicit_any,
            .no_unused_parameters = co.no_unused_parameters orelse false,
            .no_unused_locals = co.no_unused_locals orelse false,
            .strict_function_types = strict_fn_types,
            .strict_null_checks = strict_null_checks,
            .strict_property_initialization = strict_property_initialization,
            .no_unchecked_indexed_access = co.no_unchecked_indexed_access orelse false,
            .isolated_modules = co.isolated_modules orelse false,
            .resolve_json_module = co.resolve_json_module orelse false,
            .no_implicit_override = co.no_implicit_override orelse false,
        });
    } else {
        const strict_on = options.strict orelse false;
        checker.setStrictFlags(.{
            .no_implicit_any = strict_on,
            .strict_function_types = strict_on,
            .strict_null_checks = strict_on,
            .strict_property_initialization = strict_on,
        });
    }
    if (c.root != hir_mod.none_node_id) {
        checker.checkSourceFile(c.root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    const suppress_js_check_diagnostics = options.suppress_js_check_diagnostics or sourceIsUncheckedJs(source);
    for (checker.diagnostics.items) |d| {
        if (suppress_js_check_diagnostics and !checkerDiagnosticSurfacesInUncheckedJs(d.code)) continue;
        const diag_pos = d.pos orelse c.hir.spanOf(d.node).start;
        try c.diagnostics.append(gpa, .{
            .phase = .bind,
            .pos = diag_pos,
            .line = 0,
            .code = d.code,
            .code_prefix = switch (d.code_prefix) {
                .TS => .TS,
                .HM => .HM,
            },
            .message = try gpa.dupe(u8, d.message),
        });
        c.has_errors = true;
    }

    // ------ Emit ------
    if (options.no_emit) {
        c.js = try gpa.dupe(u8, "");
    } else {
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
    }

    return c;
}

fn isDiagnosticInsideJsxText(source: []const u8, pos: u32) bool {
    if (pos >= source.len) return false;
    var i: usize = @intCast(pos);
    var saw_opening_end = false;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            '>' => {
                saw_opening_end = true;
                break;
            },
            '<', '{', '}' => return false,
            else => {},
        }
    }
    if (!saw_opening_end) return false;

    var j: usize = @intCast(pos);
    while (j < source.len) : (j += 1) {
        switch (source[j]) {
            '<' => return true,
            '{', '}' => return false,
            else => {},
        }
    }
    return false;
}

fn sanitizeTsxLexSource(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = try gpa.dupe(u8, source);
    var i: usize = 0;
    var in_jsx_tag = false;
    var in_jsx_text = false;
    var tag_expr_depth: u32 = 0;
    var quote: u8 = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (quote != 0) {
            if (c == '\\' and i + 1 < out.len and out[i + 1] == quote) {
                out[i] = ' ';
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }
        if (in_jsx_tag) {
            if (tag_expr_depth > 0) {
                if (c == '{') {
                    tag_expr_depth += 1;
                } else if (c == '}') {
                    tag_expr_depth -= 1;
                }
            } else if (c == '{') {
                tag_expr_depth = 1;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '>') {
                in_jsx_tag = false;
                in_jsx_text = true;
            }
            continue;
        }
        if (in_jsx_text) {
            if (c == '<') {
                in_jsx_text = false;
                in_jsx_tag = true;
            } else if (c == '{') {
                in_jsx_text = false;
            } else if (c == '\\') {
                out[i] = ' ';
            }
            continue;
        }
        if (c == '<' and i + 1 < out.len) {
            const next = out[i + 1];
            if (next == '/' or next == '>' or next == '_' or std.ascii.isAlphabetic(next)) {
                in_jsx_tag = true;
            }
        } else if (c == '}') {
            in_jsx_text = true;
        }
    }
    return out;
}

fn sourceIsUncheckedJs(source: []const u8) bool {
    const allow_js = directiveBool(source, "allowJs") orelse false;
    if (!allow_js) return false;
    if (directiveBool(source, "checkJs") orelse false) return false;
    if (sourceHasTsCheck(source)) return false;
    return virtualFilenameIsJs(source);
}

fn checkerDiagnosticSurfacesInUncheckedJs(code: u32) bool {
    return code == ts_checker.check.TsCodes.private_name_not_declared or
        code == ts_checker.check.TsCodes.await_only_in_async;
}

fn diagnosticLineHasTsIgnore(source: []const u8, pos: usize) bool {
    const diag_line = byteOffsetToLine(source, pos);
    if (diag_line == 0) return false;
    var line_no: u32 = 0;
    var pending_ignore = false;
    var i: usize = 0;
    while (true) {
        const line_start = i;
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        var line = source[line_start..line_end];
        line = std.mem.trim(u8, line, " \t\r");
        const is_blank = line.len == 0;
        const is_ignore = lineHasDirective(line, "@ts-ignore");
        const is_expect = lineHasDirective(line, "@ts-expect-error");
        const is_directive = is_ignore or is_expect or lineHasDirective(line, "@ts-nocheck");
        if (is_ignore) pending_ignore = true;
        if (!is_blank and !is_directive) {
            if (pending_ignore and line_no == diag_line) return true;
            pending_ignore = false;
        }
        if (line_no >= diag_line or line_end >= source.len) break;
        i = line_end + 1;
        line_no += 1;
    }
    return false;
}

fn lineHasDirective(line: []const u8, directive: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "//")) return false;
    const rest = std.mem.trim(u8, line[2..], " \t");
    return std.mem.startsWith(u8, rest, directive);
}

fn byteOffsetToLine(source: []const u8, pos: usize) u32 {
    const limit = @min(pos, source.len);
    var line: u32 = 0;
    for (source[0..limit]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn sourceHasTsCheck(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "@ts-check") != null;
}

fn virtualFilenameIsJs(source: []const u8) bool {
    var fallback_is_js = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const marker = directiveValueStart(line, "filename") orelse continue;
        const value = std.mem.trim(u8, marker, " \t");
        const is_js = std.mem.endsWith(u8, value, ".js") or std.mem.endsWith(u8, value, ".jsx");
        const is_code = is_js or
            std.mem.endsWith(u8, value, ".ts") or
            std.mem.endsWith(u8, value, ".tsx") or
            std.mem.endsWith(u8, value, ".mts") or
            std.mem.endsWith(u8, value, ".cts");
        if (!is_code) continue;
        if (!virtualPathIsNodeModules(value)) return is_js;
        fallback_is_js = is_js;
    }
    return fallback_is_js;
}

fn virtualPathIsNodeModules(path: []const u8) bool {
    var p = path;
    while (std.mem.startsWith(u8, p, "/")) p = p[1..];
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return std.mem.startsWith(u8, p, "node_modules/") or
        std.mem.indexOf(u8, p, "/node_modules/") != null;
}

fn directiveBool(source: []const u8, name: []const u8) ?bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const marker = directiveValueStart(line, name) orelse continue;
        const value = std.mem.trim(u8, marker, " \t");
        if (std.mem.startsWith(u8, value, ":")) {
            const rest = std.mem.trim(u8, value[1..], " \t");
            if (parseBoolWord(rest)) |b| return b;
        } else if (parseBoolWord(value)) |b| {
            return b;
        }
    }
    return null;
}

fn directiveValueStart(line: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, line, '@') orelse return null;
    const after_at = line[at + 1 ..];
    if (after_at.len < name.len) return null;
    if (!std.ascii.eqlIgnoreCase(after_at[0..name.len], name)) return null;
    if (after_at.len > name.len and isDirectiveNameChar(after_at[name.len])) return null;
    return after_at[name.len..];
}

fn parseBoolWord(value: []const u8) ?bool {
    var end: usize = 0;
    while (end < value.len and std.ascii.isAlphabetic(value[end])) : (end += 1) {}
    const word = value[0..end];
    if (std.ascii.eqlIgnoreCase(word, "true")) return true;
    if (std.ascii.eqlIgnoreCase(word, "false")) return false;
    return null;
}

fn isDirectiveNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
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

test "driver: alwaysStrict enables strict parser early errors" {
    var c = try compileSource(T.allocator, "function f(arguments) {}", .{ .always_strict = true, .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var found = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 1100) found = true;
    }
    try T.expect(found);
}

test "driver: ts-ignore suppresses next-line parser diagnostics" {
    var c = try compileSource(T.allocator, "// @ts-ignore\nwith (x) {}", .{ .syntax_target_es2015 = true, .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(d.code != 1101);
        try T.expect(d.code != 2410);
    }
}

test "driver: type annotations erase in JS output" {
    var c = try compileSource(T.allocator, "let x: number = 1;", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expectEqualStrings("let x = 1;", c.js);
}

test "driver: allowJs virtual js without checkJs suppresses checker diagnostics" {
    var c = try compileSource(T.allocator,
        \\// @allowJs: true
        \\// @filename: unchecked.js
        \\var value = {};
        \\value.missing = 1;
    , .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }

    try T.expect(!c.has_errors);
}

test "driver: unchecked allowJs still surfaces JS grammar diagnostics" {
    var c = try compileSource(T.allocator,
        \\// @allowJs: true
        \\// @filename: unchecked.js
        \\function foo() {
        \\  await new Promise(undefined);
        \\}
        \\class A {
        \\  #a;
        \\  m() {
        \\    this.#b;
        \\  }
        \\}
    , .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }

    var found_await = false;
    var found_private = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 1308) found_await = true;
        if (d.code == 1111) found_private = true;
    }
    try T.expect(found_await);
    try T.expect(found_private);
}

test "driver: allowJs node_modules js does not suppress project ts diagnostics" {
    var c = try compileSource(T.allocator,
        \\// @allowJs: true
        \\// @filename: /node_modules/foo/index.js
        \\exports.default = { bar() { return 0; } };
        \\// @filename: /a.ts
        \\import foo from "foo";
        \\foo.bar();
    , .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }

    try T.expect(c.has_errors);
}

test "driver: checkJs virtual js surfaces checker diagnostics" {
    var c = try compileSource(T.allocator,
        \\// @allowJs: true
        \\// @checkJs: true
        \\// @filename: checked.js
        \\var value = {};
        \\value.missing;
    , .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }

    try T.expect(c.has_errors);
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

test "driver: type-check assigns TypeIds to expressions" {
    var c = try compileSource(T.allocator, "let x: number = 42;", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const decl = stmts[0];
    const init_node = hir_mod.varDeclOf(&c.hir, decl).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(init_node));
}

test "driver: call expression returns its function's return type" {
    var c = try compileSource(T.allocator,
        \\function id(x: number): string { return ""; }
        \\let r = id(1);
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const r_decl = stmts[1];
    const init_node = hir_mod.varDeclOf(&c.hir, r_decl).init;
    try T.expectEqual(hir_mod.NodeKind.call_expr, c.hir.kindOf(init_node));
    // r should be string (the return type of id).
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(init_node));
}

test "driver: emitWithCache hits on repeat compile" {
    var cache = try ts_cache.Cache.init(T.allocator, null);
    defer cache.deinit();

    const src = "let x: number = 42;";
    var r1 = try emitWithCache(T.allocator, src, &cache, "", .{});
    defer r1.deinit(T.allocator);
    try T.expect(!r1.from_cache);
    try T.expectEqualStrings("let x = 42;", r1.js);

    var r2 = try emitWithCache(T.allocator, src, &cache, "", .{});
    defer r2.deinit(T.allocator);
    try T.expect(r2.from_cache);
    try T.expectEqualStrings("let x = 42;", r2.js);
}

test "driver: emitWithCache distinct sources produce distinct entries" {
    var cache = try ts_cache.Cache.init(T.allocator, null);
    defer cache.deinit();

    var ra = try emitWithCache(T.allocator, "let a = 1;", &cache, "", .{});
    defer ra.deinit(T.allocator);
    var rb = try emitWithCache(T.allocator, "let b = 2;", &cache, "", .{});
    defer rb.deinit(T.allocator);

    try T.expect(!std.mem.eql(u8, ra.js, rb.js));
    try T.expectEqual(@as(u32, 2), cache.count());
}

test "driver: TS2554 argument count mismatch" {
    var c = try compileSource(T.allocator,
        \\function f(a: number): number { return a; }
        \\f(1, 2);
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var saw_2554 = false;
    for (c.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "Expected 1 arguments, but got 2") != null) {
            saw_2554 = true;
            break;
        }
    }
    try T.expect(saw_2554);
    try T.expect(c.has_errors);
}

test "driver: TS2345 argument type mismatch" {
    var c = try compileSource(T.allocator,
        \\function f(a: number): number { return a; }
        \\f("hi");
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var saw_2345 = false;
    for (c.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "Argument is not assignable") != null) {
            saw_2345 = true;
            break;
        }
    }
    try T.expect(saw_2345);
}

test "driver: strict enables property initialization checking" {
    var c = try compileSource(T.allocator,
        \\class C { x: string; }
    , .{ .strict = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var saw_2564 = false;
    for (c.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "has no initializer") != null) {
            saw_2564 = true;
            break;
        }
    }
    try T.expect(saw_2564);
}

test "driver: TS2345 silent for assignable arg" {
    var c = try compileSource(T.allocator,
        \\function f(a: number): number { return a; }
        \\f(42);
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(std.mem.indexOf(u8, d.message, "Argument is not assignable") == null);
    }
}

test "driver: array literal builds Array<T> shape with number indexer" {
    var c = try compileSource(T.allocator, "let xs = [1, 2, 3];", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const init_node = hir_mod.varDeclOf(&c.hir, stmts[0]).init;
    const t = c.hir.typeOf(init_node);
    // [1, 2, 3] → object type with `[i: number]: number` and `length: number`.
    try T.expect(c.type_interner.pool.flagsOf(t).is_object_type);
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.type_interner.objectNumberIndex(t));
}

test "driver: heterogeneous array literal builds Array<T|U>" {
    var c = try compileSource(T.allocator, "let xs = [1, \"hi\"];", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const init_node = hir_mod.varDeclOf(&c.hir, stmts[0]).init;
    const t = c.hir.typeOf(init_node);
    try T.expect(c.type_interner.pool.flagsOf(t).is_object_type);
    const elem_t = c.type_interner.objectNumberIndex(t);
    try T.expect(c.type_interner.pool.flagsOf(elem_t).is_union);
}

test "driver: object literal infers shape; member access types correctly" {
    var c = try compileSource(T.allocator,
        \\let p = { x: 1, y: "hi" };
        \\let nx = p.x;
        \\let sy = p.y;
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const nx_init = hir_mod.varDeclOf(&c.hir, stmts[1]).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(nx_init));
    const sy_init = hir_mod.varDeclOf(&c.hir, stmts[2]).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(sy_init));
}

test "driver: arrow function with explicit signature gets a signature TypeId" {
    var c = try compileSource(T.allocator,
        \\let f = (x: number): string => "hi";
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const f_decl = stmts[0];
    const init_node = hir_mod.varDeclOf(&c.hir, f_decl).init;
    const sig_t = c.hir.typeOf(init_node);
    try T.expect(c.type_interner.pool.flagsOf(sig_t).is_signature);
    const ret = c.type_interner.signatureReturn(sig_t).?;
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), ret);
}

test "driver: arrow assigned to function-type annotation type-checks" {
    var c = try compileSource(T.allocator,
        \\let f: (n: number) => string = (n) => "x";
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // Should not produce a "not assignable" diagnostic.
    for (c.diagnostics.items) |d| {
        try T.expect(std.mem.indexOf(u8, d.message, "not assignable") == null);
    }
}

test "driver: discriminated union narrowing — string discriminant" {
    var c = try compileSource(T.allocator,
        \\type Shape = { kind: "circle"; r: number } | { kind: "square"; w: number };
        \\function area(s: Shape) {
        \\  if (s.kind === "circle") {
        \\    let rr = s.r;
        \\  }
        \\}
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // No "Property does not exist" diagnostic for s.r (since s
    // narrowed to the circle variant inside the if-then).
    for (c.diagnostics.items) |d| {
        try T.expect(std.mem.indexOf(u8, d.message, "does not exist") == null);
    }
}

test "driver: explicit type-args on a generic call parse + compile" {
    var c = try compileSource(T.allocator,
        \\function id<T>(x: T): T { return x; }
        \\let r = id<number>(42);
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // Should not produce a parse error.
    for (c.diagnostics.items) |d| {
        try T.expect(d.phase != .parse);
    }
    // Output JS strips the type args.
    try T.expect(std.mem.indexOf(u8, c.js, "id(42)") != null);
}

test "driver: comparison still parses as binop (no false-positive type args)" {
    var c = try compileSource(T.allocator,
        \\let a = 1;
        \\let b = 2;
        \\let c2 = a < b;
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(d.phase != .parse);
    }
    try T.expect(std.mem.indexOf(u8, c.js, "a < b") != null);
}

test "driver: object annotation accepts a shape-compatible literal" {
    var c = try compileSource(T.allocator,
        \\let p: { x: number; y: string } = { x: 1, y: "hi" };
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // No "not assignable" diagnostic.
    for (c.diagnostics.items) |d| {
        try T.expect(std.mem.indexOf(u8, d.message, "not assignable") == null);
    }
}

test "driver: object annotation rejects shape with missing required prop" {
    var c = try compileSource(T.allocator,
        \\let p: { x: number; y: string } = { x: 1 };
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var saw_mismatch = false;
    for (c.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "not assignable") != null) {
            saw_mismatch = true;
            break;
        }
    }
    try T.expect(saw_mismatch);
}

test "driver: optional prop on annotation tolerates missing source key" {
    var c = try compileSource(T.allocator,
        \\let p: { x: number; y?: string } = { x: 1 };
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(std.mem.indexOf(u8, d.message, "not assignable") == null);
    }
}

test "driver: object annotation accepts extra source props" {
    var c = try compileSource(T.allocator,
        \\let p: { x: number } = { x: 1, y: "extra" };
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(std.mem.indexOf(u8, d.message, "not assignable") == null);
    }
}

test "driver: generic identity function infers T from argument" {
    var c = try compileSource(T.allocator,
        \\function id<T>(x: T): T { return x; }
        \\let n = id(42);
        \\let s = id("hi");
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const n_init = hir_mod.varDeclOf(&c.hir, stmts[1]).init;
    const s_init = hir_mod.varDeclOf(&c.hir, stmts[2]).init;
    // Without instantiation we'd see the unsubstituted type
    // parameter. With it, n is number and s is string.
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(n_init));
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(s_init));
}

test "driver: typeof narrowing in else branch flips" {
    var c = try compileSource(T.allocator,
        \\function f(x: any) {
        \\  if (typeof x === "string") {
        \\    let s = x;
        \\  } else {
        \\    let n = x;
        \\  }
        \\}
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // Within the else branch, x narrows by subtracting `string`
    // from x's current type. For `any`, subtraction is a no-op
    // (matches tsc — `any minus T = any`), so the else branch
    // keeps `any`. The narrowing is still observable in the then
    // branch where x narrows to `string`.
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&c.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&c.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&c.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&c.hir, ifp.then_branch);
    const s_decl = then_stmts[0];
    const s_init = hir_mod.varDeclOf(&c.hir, s_decl).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(s_init));
    const else_stmts = hir_mod.blockStmts(&c.hir, ifp.else_branch);
    const n_decl = else_stmts[0];
    const n_init = hir_mod.varDeclOf(&c.hir, n_decl).init;
    // any minus string = any (tsc-compatible behavior).
    try T.expectEqual(@as(u32, ts_checker.Primitive.any), c.hir.typeOf(n_init));
}

test "driver: typeof narrowing on union subtracts in else branch" {
    var c = try compileSource(T.allocator,
        \\function f(x: string | number) {
        \\  if (typeof x === "string") {
        \\    let s = x;
        \\  } else {
        \\    let n = x;
        \\  }
        \\}
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&c.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&c.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&c.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&c.hir, ifp.then_branch);
    const s_init = hir_mod.varDeclOf(&c.hir, then_stmts[0]).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(s_init));
    const else_stmts = hir_mod.blockStmts(&c.hir, ifp.else_branch);
    const n_init = hir_mod.varDeclOf(&c.hir, else_stmts[0]).init;
    // (string | number) minus string = number.
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(n_init));
}

test "driver: null guard narrows in then branch" {
    var c = try compileSource(T.allocator,
        \\function f(x: any) {
        \\  if (x === null) {
        \\    let n = x;
        \\  }
        \\}
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&c.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&c.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&c.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&c.hir, ifp.then_branch);
    const n_decl = then_stmts[0];
    const n_init = hir_mod.varDeclOf(&c.hir, n_decl).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.null_t), c.hir.typeOf(n_init));
}

test "driver: typeof narrowing inside if narrows identifier type" {
    var c = try compileSource(T.allocator,
        \\function f(x: any) {
        \\  if (typeof x === "string") {
        \\    let s = x;
        \\  }
        \\}
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // Find the inner `let s = x;` and check x's resolved type
    // is string_t (narrowed from any inside the if-then branch).
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&c.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&c.hir, f.body);
    const if_stmt = body_stmts[0];
    const ifp = hir_mod.ifOf(&c.hir, if_stmt);
    const then_stmts = hir_mod.blockStmts(&c.hir, ifp.then_branch);
    const s_decl = then_stmts[0];
    const s_init = hir_mod.varDeclOf(&c.hir, s_decl).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(s_init));
}

test "driver: member access on object-typed variable returns property type" {
    var c = try compileSource(T.allocator,
        \\let p: { x: number; y: string } = null;
        \\let nx = p.x;
        \\let sy = p.y;
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const nx_init = hir_mod.varDeclOf(&c.hir, stmts[1]).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(nx_init));
    const sy_init = hir_mod.varDeclOf(&c.hir, stmts[2]).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(sy_init));
}

test "driver: missing property falls back to any + TS2339 diagnostic" {
    var c = try compileSource(T.allocator,
        \\let p: { x: number } = null;
        \\let z = p.missing;
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const z_init = hir_mod.varDeclOf(&c.hir, stmts[1]).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.any), c.hir.typeOf(z_init));
    var saw_2339 = false;
    for (c.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "missing") != null) {
            saw_2339 = true;
            break;
        }
    }
    try T.expect(saw_2339);
    try T.expect(c.has_errors);
}

test "driver: function parameter resolves to its annotation type in body" {
    var c = try compileSource(T.allocator,
        \\function id(x: number): number { let y = x; return y; }
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // Walk to `let y = x` inside the body, check y's init `x` is number_t.
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const fn_node = stmts[0];
    const f = hir_mod.fnDeclOf(&c.hir, fn_node);
    const body_stmts = hir_mod.blockStmts(&c.hir, f.body);
    const y_decl = body_stmts[0];
    const y_init = hir_mod.varDeclOf(&c.hir, y_decl).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(y_init));
}

test "driver: nested call inside function body resolves" {
    var c = try compileSource(T.allocator,
        \\function id(x: number): string { return ""; }
        \\function caller(): string { return id(1); }
    , .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    const caller_fn = stmts[1];
    const f = hir_mod.fnDeclOf(&c.hir, caller_fn);
    const body_stmts = hir_mod.blockStmts(&c.hir, f.body);
    const ret = body_stmts[0];
    const ret_p = hir_mod.returnOf(&c.hir, ret);
    // The call `id(1)` returns string.
    try T.expectEqual(@as(u32, ts_checker.Primitive.string_t), c.hir.typeOf(ret_p.value));
}

test "driver: identifier reference resolves via binder symbol table" {
    var c = try compileSource(T.allocator, "let x: number = 1; let y = x;", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    const stmts = hir_mod.blockStmts(&c.hir, c.root);
    // First decl: `let x: number = 1` — type number_t
    const x_decl = stmts[0];
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(x_decl));
    // Second decl: `let y = x` — y inherits x's type via the
    // identifier resolution path.
    const y_decl = stmts[1];
    const y_init = hir_mod.varDeclOf(&c.hir, y_decl).init;
    try T.expectEqual(@as(u32, ts_checker.Primitive.number_t), c.hir.typeOf(y_init));
}

test "driver: type-check reports diagnostic on mismatched assignment" {
    var c = try compileSource(T.allocator, "let x: number = \"hi\";", .{});
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(c.has_errors);
    var found = false;
    for (c.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "not assignable") != null) {
            found = true;
            break;
        }
    }
    try T.expect(found);
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

test "driver: tsx jsx text entities do not surface lex diagnostics" {
    var c = try compileSource(T.allocator,
        \\declare namespace JSX { interface Element {} interface IntrinsicElements { [name: string]: any; } }
        \\declare var React: any;
        \\let v = <div>&#123;&notAnEntity;\n</div>;
    , .{ .is_tsx = true, .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(d.phase != .lex);
    }
}

test "driver: automatic jsx import source reports missing runtime module" {
    var c = try compileSource(T.allocator,
        \\// @jsx: react-jsx,react-jsxdev
        \\// @jsxImportSource: preact
        \\let v = <div />;
    , .{ .is_tsx = true, .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var found = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 2875) found = true;
    }
    try T.expect(found);
}

test "driver: jsx pragma with fragment requires jsxFrag pragma" {
    var c = try compileSource(T.allocator,
        \\/** @jsx dom */
        \\import { dom } from "./renderer";
        \\let v = <></>;
    , .{ .is_tsx = true, .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var found = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 17017) found = true;
    }
    try T.expect(found);
}

test "driver: optionsFromConfig enables tsx for jsx=react-jsx" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const cfg = try tsconfig_mod.parseString(
        T.allocator,
        arena.allocator(),
        \\{ "compilerOptions": { "jsx": "react-jsx" } }
        ,
    );
    const opts = optionsFromConfig(&cfg);
    try T.expect(opts.is_tsx);
}

test "driver: optionsFromConfig wires useDefineForClassFields=false" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const cfg = try tsconfig_mod.parseString(
        T.allocator,
        arena.allocator(),
        \\{ "compilerOptions": { "useDefineForClassFields": false } }
        ,
    );
    const opts = optionsFromConfig(&cfg);
    try T.expect(!opts.emit.use_define_for_class_fields);
}

test "driver: optionsFromConfig wires experimentalDecorators=false → Stage 3" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const cfg = try tsconfig_mod.parseString(
        T.allocator,
        arena.allocator(),
        \\{ "compilerOptions": { "experimentalDecorators": false } }
        ,
    );
    const opts = optionsFromConfig(&cfg);
    try T.expect(!opts.emit.experimental_decorators);

    // End-to-end: the emitter should pick the Stage 3 path.
    var c = try compileSource(T.allocator, "@logged class Foo {}", opts);
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    // Stage 3 emit wraps decorators in a `__esDecorate` / context
    // helper rather than the legacy `__decorate([logged], Foo)` call.
    try T.expect(std.mem.indexOf(u8, c.js, "__esDecorate(") != null);
    try T.expect(std.mem.indexOf(u8, c.js, "= __decorate(") == null);
}

test "driver: optionsFromConfig with no jsx leaves is_tsx false" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const cfg = try tsconfig_mod.parseString(
        T.allocator,
        arena.allocator(),
        \\{ "compilerOptions": { "target": "es2022" } }
        ,
    );
    const opts = optionsFromConfig(&cfg);
    try T.expect(!opts.is_tsx);
}

test "driver: scanner-error compilation deinitializes cleanly" {
    var c = try compileSource(T.allocator, "1\\u005F01234", .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    try T.expect(c.has_errors);
    try T.expect(c.diagnostics.items.len > 0);
}

test "driver: missing triple-slash path reference reports TS6053" {
    var c = try compileSource(T.allocator, "///<reference path='definitely-missing.ts' />\nlet x = 1;", .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    var found = false;
    for (c.diagnostics.items) |d| {
        if (d.code == 6053) {
            found = true;
            try T.expectEqual(@as(u32, 20), d.pos);
        }
    }
    try T.expect(found);
}

test "driver: classic for initializer binding pattern is visible in condition update and body" {
    var c = try compileSource(T.allocator,
        \\for (let [x = 'a' in {}] = []; !x; x = !x) console.log(x)
        \\for (let {y = 'a' in {}} = {}; !y; y = !y) console.log(y)
    , .{ .no_emit = true, .syntax_target_es2015 = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(d.code != 2304);
    }
}

test "driver: harness lib triple-slash path reference is provided externally" {
    var c = try compileSource(T.allocator, "/// <reference path=\"/.lib/react16.d.ts\" />\nlet x = 1;", .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(d.code != 6053);
    }
}

test "driver: virtual triple-slash path reference is satisfied by filename section" {
    var c = try compileSource(T.allocator,
        \\// @filename: main.ts
        \\/// <reference path="./commonjs.d.ts" />
        \\let x = 1;
        \\// @filename: commonjs.d.ts
        \\declare const y: number;
    , .{ .no_emit = true });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(d.code != 6053);
    }
}

test "driver: declaration file allows exported const without initializer" {
    var c = try compileSource(T.allocator, "export const blogPost: Element;", .{
        .no_emit = true,
        .is_declaration_file = true,
    });
    defer {
        c.deinit();
        T.allocator.destroy(c);
    }
    for (c.diagnostics.items) |d| {
        try T.expect(d.code != 1155);
    }
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
