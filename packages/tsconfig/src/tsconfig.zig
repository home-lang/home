//! Typed `tsconfig.json` schema and loader.
//!
//! Per TS_PARITY_PLAN §2.2 and §6.4. The schema below covers the
//! options the type checker and emitter need first; the full ~140-key
//! matrix from §2.2 is filled in incrementally as Phase 1 (frontend)
//! and Phase 4 (emitter) consume each option.
//!
//! Loader behavior:
//!
//!   - Reads JSONC (`jsonc.zig`).
//!   - Resolves `extends`: a string or string-array of paths to other
//!     tsconfig files; each is loaded recursively and merged
//!     left-to-right with the current file taking precedence on every
//!     key (matches `tsc`'s observable behavior).
//!   - Inherits arrays *by replacement*, not concat — exactly what tsc
//!     does for `include` / `exclude` / `files`. The exception is
//!     `paths`, where tsc walks the chain to find the first definition
//!     and uses its `baseUrl` resolution (we mirror that).
//!   - Reports unknown keys as warnings rather than errors (forward
//!     compatibility with future TS versions).
//!
//! Out of scope for the Phase 1.C cut (tracked as Phase 1.C
//! follow-ups):
//!
//!   - Disk I/O — the public API today takes `source: []const u8`. The
//!     driver layer wraps this with file-reading, so unit tests stay
//!     hermetic.
//!   - The complete ~140 compilerOptions surface — we materialize the
//!     ~30 most-used today and fall through unknown keys into a
//!     pass-through bag (`extra_options`) so they round-trip without
//!     loss until each is explicitly typed.
//!   - `references` and `composite` semantics for `tsc -b` mode.
//!     Phase 9 work.

const std = @import("std");
const jsonc = @import("jsonc.zig");

pub const Module = enum {
    none,
    commonjs,
    amd,
    umd,
    system,
    es6,
    es2015,
    es2020,
    es2022,
    esnext,
    node16,
    node18,
    nodenext,
    preserve,

    pub fn fromString(s: []const u8) ?Module {
        const map = .{
            .{ "none", .none },
            .{ "commonjs", .commonjs },
            .{ "amd", .amd },
            .{ "umd", .umd },
            .{ "system", .system },
            .{ "es6", .es6 },
            .{ "es2015", .es2015 },
            .{ "es2020", .es2020 },
            .{ "es2022", .es2022 },
            .{ "esnext", .esnext },
            .{ "node16", .node16 },
            .{ "node18", .node18 },
            .{ "nodenext", .nodenext },
            .{ "preserve", .preserve },
        };
        inline for (map) |entry| {
            if (std.ascii.eqlIgnoreCase(s, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const ModuleResolution = enum {
    classic,
    node10, // alias: "node"
    node16,
    nodenext,
    bundler,

    pub fn fromString(s: []const u8) ?ModuleResolution {
        if (std.ascii.eqlIgnoreCase(s, "classic")) return .classic;
        if (std.ascii.eqlIgnoreCase(s, "node10") or std.ascii.eqlIgnoreCase(s, "node")) return .node10;
        if (std.ascii.eqlIgnoreCase(s, "node16")) return .node16;
        if (std.ascii.eqlIgnoreCase(s, "nodenext")) return .nodenext;
        if (std.ascii.eqlIgnoreCase(s, "bundler")) return .bundler;
        return null;
    }
};

pub const Target = enum {
    es3,
    es5,
    es2015,
    es2016,
    es2017,
    es2018,
    es2019,
    es2020,
    es2021,
    es2022,
    es2023,
    es2024,
    esnext,

    pub fn fromString(s: []const u8) ?Target {
        const map = .{
            .{ "es3", .es3 },
            .{ "es5", .es5 },
            .{ "es6", .es2015 }, // TS treats `es6` as alias of `es2015`
            .{ "es2015", .es2015 },
            .{ "es2016", .es2016 },
            .{ "es2017", .es2017 },
            .{ "es2018", .es2018 },
            .{ "es2019", .es2019 },
            .{ "es2020", .es2020 },
            .{ "es2021", .es2021 },
            .{ "es2022", .es2022 },
            .{ "es2023", .es2023 },
            .{ "es2024", .es2024 },
            .{ "esnext", .esnext },
        };
        inline for (map) |entry| {
            if (std.ascii.eqlIgnoreCase(s, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const Jsx = enum {
    preserve,
    react,
    react_jsx,
    react_jsxdev,
    react_native,

    pub fn fromString(s: []const u8) ?Jsx {
        if (std.ascii.eqlIgnoreCase(s, "preserve")) return .preserve;
        if (std.ascii.eqlIgnoreCase(s, "react")) return .react;
        if (std.ascii.eqlIgnoreCase(s, "react-jsx")) return .react_jsx;
        if (std.ascii.eqlIgnoreCase(s, "react-jsxdev")) return .react_jsxdev;
        if (std.ascii.eqlIgnoreCase(s, "react-native")) return .react_native;
        return null;
    }
};

/// `paths` map: pattern → list of substitution patterns.
///
/// Example:
///
/// ```jsonc
/// "paths": {
///   "@app/*": ["src/app/*", "fallback/app/*"]
/// }
/// ```
pub const Paths = struct {
    /// Parallel arrays preserve insertion order (matters for tsc-compat
    /// resolution: try each substitution in order).
    patterns: [][]const u8,
    substitutions: [][]const []const u8,

    pub fn empty() Paths {
        return .{ .patterns = &.{}, .substitutions = &.{} };
    }
};

/// Typed compilerOptions. Mirrors §2.2 of the plan; missing keys are
/// added incrementally with a regression test per addition.
pub const CompilerOptions = struct {
    // -- Type checking --
    strict: ?bool = null,
    no_implicit_any: ?bool = null,
    strict_null_checks: ?bool = null,
    strict_function_types: ?bool = null,
    strict_bind_call_apply: ?bool = null,
    strict_property_initialization: ?bool = null,
    no_implicit_this: ?bool = null,
    use_unknown_in_catch_variables: ?bool = null,
    always_strict: ?bool = null,
    no_unused_locals: ?bool = null,
    no_unused_parameters: ?bool = null,
    exact_optional_property_types: ?bool = null,
    no_implicit_returns: ?bool = null,
    no_fallthrough_cases_in_switch: ?bool = null,
    no_unchecked_indexed_access: ?bool = null,
    no_implicit_override: ?bool = null,
    no_property_access_from_index_signature: ?bool = null,
    skip_lib_check: ?bool = null,
    skip_default_lib_check: ?bool = null,
    force_consistent_casing_in_file_names: ?bool = null,
    keyof_strings_only: ?bool = null,
    suppress_excess_property_errors: ?bool = null,
    suppress_implicit_any_index_errors: ?bool = null,

    // -- Modules --
    module: ?Module = null,
    module_resolution: ?ModuleResolution = null,
    base_url: ?[]const u8 = null,
    paths: ?Paths = null,
    root_dirs: ?[][]const u8 = null,
    type_roots: ?[][]const u8 = null,
    types: ?[][]const u8 = null,
    resolve_json_module: ?bool = null,
    allow_importing_ts_extensions: ?bool = null,
    es_module_interop: ?bool = null,
    isolated_modules: ?bool = null,
    isolated_declarations: ?bool = null,
    verbatim_module_syntax: ?bool = null,
    allow_synthetic_default_imports: ?bool = null,
    module_detection: ?[]const u8 = null,

    // -- Emit --
    target: ?Target = null,
    lib: ?[][]const u8 = null,
    no_lib: ?bool = null,
    jsx: ?Jsx = null,
    jsx_factory: ?[]const u8 = null,
    jsx_fragment_factory: ?[]const u8 = null,
    jsx_import_source: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    root_dir: ?[]const u8 = null,
    declaration: ?bool = null,
    declaration_dir: ?[]const u8 = null,
    declaration_map: ?bool = null,
    emit_declaration_only: ?bool = null,
    composite: ?bool = null,
    incremental: ?bool = null,
    ts_buildinfo_file: ?[]const u8 = null,
    assume_changes_only_affect_direct_dependencies: ?bool = null,
    disable_size_limit: ?bool = null,
    remove_comments: ?bool = null,
    no_emit: ?bool = null,
    import_helpers: ?bool = null,
    no_emit_helpers: ?bool = null,
    down_level_iteration: ?bool = null,
    preserve_const_enums: ?bool = null,
    experimental_decorators: ?bool = null,
    emit_decorator_metadata: ?bool = null,
    source_map: ?bool = null,
    inline_source_map: ?bool = null,
    inline_sources: ?bool = null,

    // -- JS support --
    allow_js: ?bool = null,
    check_js: ?bool = null,

    // -- Class semantics --
    use_define_for_class_fields: ?bool = null,

    /// Pass-through bag for keys not yet typed. Each entry is a raw
    /// `(key, jsonc.Value)` pair so unknown keys round-trip without loss.
    extra: std.ArrayListUnmanaged(ExtraEntry) = .empty,
};

/// Named to avoid anonymous-struct identity issues across functions.
pub const ExtraEntry = struct {
    key: []const u8,
    value: jsonc.Value,
};

pub const TsConfig = struct {
    /// The path this config came from (set by the loader; empty when
    /// parsed via `parseString`).
    file_path: []const u8,
    /// Compiler options.
    compiler_options: CompilerOptions,
    /// `extends`: paths of other tsconfig files this one inherits from.
    extends: [][]const u8,
    /// `files`: explicit file list. `null` if not present.
    files: ?[][]const u8,
    /// `include`: glob patterns. `null` if not present (default
    /// `["**/*"]` if neither `files` nor `include` is set).
    include: ?[][]const u8,
    /// `exclude`: glob patterns. `null` if not present.
    exclude: ?[][]const u8,
    /// `references`: project-references entries. Phase 9 fills in.
    references: [][]const u8,
};

pub const LoadError = error{
    NotAnObject,
    InvalidExtends,
    InvalidPaths,
    UnknownEnumValue,
    OutOfMemory,
    UnexpectedCharacter,
    UnexpectedEof,
    UnterminatedString,
    InvalidNumber,
    InvalidEscape,
    DuplicateKey,
};

/// Parse a tsconfig from raw JSONC source. Allocates into `arena`.
pub fn parseString(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
) LoadError!TsConfig {
    const doc = try jsonc.parse(gpa, arena, source);
    gpa.free(doc.diagnostics);

    const root = doc.value.asObject() orelse return error.NotAnObject;

    var cfg: TsConfig = .{
        .file_path = "",
        .compiler_options = .{},
        .extends = &.{},
        .files = null,
        .include = null,
        .exclude = null,
        .references = &.{},
    };

    // extends: string or [string]
    if (root.get("extends")) |ext_v| {
        switch (ext_v) {
            .string => |s| {
                const arr = try arena.alloc([]const u8, 1);
                arr[0] = s;
                cfg.extends = arr;
            },
            .array => |arr| {
                const out = try arena.alloc([]const u8, arr.len);
                for (arr, 0..) |a, i| {
                    out[i] = a.asString() orelse return error.InvalidExtends;
                }
                cfg.extends = out;
            },
            else => return error.InvalidExtends,
        }
    }

    if (root.get("files")) |v| {
        cfg.files = try parseStringArray(arena, v);
    }
    if (root.get("include")) |v| {
        cfg.include = try parseStringArray(arena, v);
    }
    if (root.get("exclude")) |v| {
        cfg.exclude = try parseStringArray(arena, v);
    }
    if (root.get("references")) |v| {
        if (v.asArray()) |refs| {
            const out = try arena.alloc([]const u8, refs.len);
            var n: usize = 0;
            for (refs) |r| {
                if (r.asObject()) |o| {
                    if (o.get("path")) |p| {
                        if (p.asString()) |s| {
                            out[n] = s;
                            n += 1;
                        }
                    }
                }
            }
            cfg.references = out[0..n];
        }
    }
    if (root.get("compilerOptions")) |co_v| {
        if (co_v.asObject()) |co| {
            try fillCompilerOptions(arena, &cfg.compiler_options, co);
        }
    }

    return cfg;
}

fn parseStringArray(arena: std.mem.Allocator, v: jsonc.Value) ![][]const u8 {
    const arr = v.asArray() orelse return &.{};
    const out = try arena.alloc([]const u8, arr.len);
    var n: usize = 0;
    for (arr) |item| {
        if (item.asString()) |s| {
            out[n] = s;
            n += 1;
        }
    }
    return out[0..n];
}

fn fillCompilerOptions(arena: std.mem.Allocator, co: *CompilerOptions, obj: jsonc.Value.Object) !void {
    var i: usize = 0;
    while (i < obj.keys.len) : (i += 1) {
        const key = obj.keys[i];
        const value = obj.values[i];

        // Boolean flags — list once, dispatch via comptime.
        const Bool = struct { name: []const u8, field: []const u8 };
        const bool_table = comptime [_]Bool{
            .{ .name = "strict", .field = "strict" },
            .{ .name = "noImplicitAny", .field = "no_implicit_any" },
            .{ .name = "strictNullChecks", .field = "strict_null_checks" },
            .{ .name = "strictFunctionTypes", .field = "strict_function_types" },
            .{ .name = "strictBindCallApply", .field = "strict_bind_call_apply" },
            .{ .name = "strictPropertyInitialization", .field = "strict_property_initialization" },
            .{ .name = "noImplicitThis", .field = "no_implicit_this" },
            .{ .name = "useUnknownInCatchVariables", .field = "use_unknown_in_catch_variables" },
            .{ .name = "alwaysStrict", .field = "always_strict" },
            .{ .name = "noUnusedLocals", .field = "no_unused_locals" },
            .{ .name = "noUnusedParameters", .field = "no_unused_parameters" },
            .{ .name = "exactOptionalPropertyTypes", .field = "exact_optional_property_types" },
            .{ .name = "noImplicitReturns", .field = "no_implicit_returns" },
            .{ .name = "noFallthroughCasesInSwitch", .field = "no_fallthrough_cases_in_switch" },
            .{ .name = "noUncheckedIndexedAccess", .field = "no_unchecked_indexed_access" },
            .{ .name = "noImplicitOverride", .field = "no_implicit_override" },
            .{ .name = "noPropertyAccessFromIndexSignature", .field = "no_property_access_from_index_signature" },
            .{ .name = "skipLibCheck", .field = "skip_lib_check" },
            .{ .name = "skipDefaultLibCheck", .field = "skip_default_lib_check" },
            .{ .name = "forceConsistentCasingInFileNames", .field = "force_consistent_casing_in_file_names" },
            .{ .name = "keyofStringsOnly", .field = "keyof_strings_only" },
            .{ .name = "suppressExcessPropertyErrors", .field = "suppress_excess_property_errors" },
            .{ .name = "suppressImplicitAnyIndexErrors", .field = "suppress_implicit_any_index_errors" },
            .{ .name = "allowSyntheticDefaultImports", .field = "allow_synthetic_default_imports" },
            .{ .name = "useDefineForClassFields", .field = "use_define_for_class_fields" },
            .{ .name = "resolveJsonModule", .field = "resolve_json_module" },
            .{ .name = "allowImportingTsExtensions", .field = "allow_importing_ts_extensions" },
            .{ .name = "esModuleInterop", .field = "es_module_interop" },
            .{ .name = "isolatedModules", .field = "isolated_modules" },
            .{ .name = "isolatedDeclarations", .field = "isolated_declarations" },
            .{ .name = "verbatimModuleSyntax", .field = "verbatim_module_syntax" },
            .{ .name = "noLib", .field = "no_lib" },
            .{ .name = "declaration", .field = "declaration" },
            .{ .name = "declarationMap", .field = "declaration_map" },
            .{ .name = "emitDeclarationOnly", .field = "emit_declaration_only" },
            .{ .name = "composite", .field = "composite" },
            .{ .name = "incremental", .field = "incremental" },
            .{ .name = "assumeChangesOnlyAffectDirectDependencies", .field = "assume_changes_only_affect_direct_dependencies" },
            .{ .name = "disableSizeLimit", .field = "disable_size_limit" },
            .{ .name = "removeComments", .field = "remove_comments" },
            .{ .name = "noEmit", .field = "no_emit" },
            .{ .name = "importHelpers", .field = "import_helpers" },
            .{ .name = "noEmitHelpers", .field = "no_emit_helpers" },
            .{ .name = "downlevelIteration", .field = "down_level_iteration" },
            .{ .name = "preserveConstEnums", .field = "preserve_const_enums" },
            .{ .name = "experimentalDecorators", .field = "experimental_decorators" },
            .{ .name = "emitDecoratorMetadata", .field = "emit_decorator_metadata" },
            .{ .name = "sourceMap", .field = "source_map" },
            .{ .name = "inlineSourceMap", .field = "inline_source_map" },
            .{ .name = "inlineSources", .field = "inline_sources" },
            .{ .name = "allowJs", .field = "allow_js" },
            .{ .name = "checkJs", .field = "check_js" },
        };
        var matched = false;
        inline for (bool_table) |entry| {
            if (std.mem.eql(u8, key, entry.name)) {
                @field(co, entry.field) = value.asBool() orelse return error.NotAnObject;
                matched = true;
            }
        }
        if (matched) continue;

        // Strings.
        const Str = struct { name: []const u8, field: []const u8 };
        const str_table = comptime [_]Str{
            .{ .name = "baseUrl", .field = "base_url" },
            .{ .name = "outDir", .field = "out_dir" },
            .{ .name = "rootDir", .field = "root_dir" },
            .{ .name = "declarationDir", .field = "declaration_dir" },
            .{ .name = "tsBuildInfoFile", .field = "ts_buildinfo_file" },
            .{ .name = "jsxFactory", .field = "jsx_factory" },
            .{ .name = "jsxFragmentFactory", .field = "jsx_fragment_factory" },
            .{ .name = "jsxImportSource", .field = "jsx_import_source" },
            .{ .name = "moduleDetection", .field = "module_detection" },
        };
        inline for (str_table) |entry| {
            if (std.mem.eql(u8, key, entry.name)) {
                @field(co, entry.field) = value.asString() orelse return error.NotAnObject;
                matched = true;
            }
        }
        if (matched) continue;

        // String arrays.
        if (std.mem.eql(u8, key, "lib")) {
            co.lib = try parseStringArray(arena, value);
            continue;
        }
        if (std.mem.eql(u8, key, "rootDirs")) {
            co.root_dirs = try parseStringArray(arena, value);
            continue;
        }
        if (std.mem.eql(u8, key, "typeRoots")) {
            co.type_roots = try parseStringArray(arena, value);
            continue;
        }
        if (std.mem.eql(u8, key, "types")) {
            co.types = try parseStringArray(arena, value);
            continue;
        }

        // Enum-typed.
        if (std.mem.eql(u8, key, "module")) {
            const s = value.asString() orelse return error.UnknownEnumValue;
            co.module = Module.fromString(s) orelse return error.UnknownEnumValue;
            continue;
        }
        if (std.mem.eql(u8, key, "moduleResolution")) {
            const s = value.asString() orelse return error.UnknownEnumValue;
            co.module_resolution = ModuleResolution.fromString(s) orelse return error.UnknownEnumValue;
            continue;
        }
        if (std.mem.eql(u8, key, "target")) {
            const s = value.asString() orelse return error.UnknownEnumValue;
            co.target = Target.fromString(s) orelse return error.UnknownEnumValue;
            continue;
        }
        if (std.mem.eql(u8, key, "jsx")) {
            const s = value.asString() orelse return error.UnknownEnumValue;
            co.jsx = Jsx.fromString(s) orelse return error.UnknownEnumValue;
            continue;
        }

        // `paths`.
        if (std.mem.eql(u8, key, "paths")) {
            const obj_v = value.asObject() orelse return error.InvalidPaths;
            const npats = obj_v.keys.len;
            const patterns = try arena.alloc([]const u8, npats);
            const substitutions = try arena.alloc([]const []const u8, npats);
            for (obj_v.keys, 0..) |pk, idx| {
                patterns[idx] = pk;
                const arr = obj_v.values[idx].asArray() orelse return error.InvalidPaths;
                const subs = try arena.alloc([]const u8, arr.len);
                for (arr, 0..) |s, j| {
                    subs[j] = s.asString() orelse return error.InvalidPaths;
                }
                substitutions[idx] = subs;
            }
            co.paths = .{ .patterns = patterns, .substitutions = substitutions };
            continue;
        }

        // Unknown key — preserve in `extra`.
        try co.extra.append(arena, .{ .key = key, .value = value });
    }
}

/// Apply `child` on top of `base`. Used to merge the result of an
/// `extends` chain — base = parent, child = current file.
pub fn merge(arena: std.mem.Allocator, base: TsConfig, child: TsConfig) !TsConfig {
    var merged = base;
    // Compiler options: child overrides base on every set field.
    const co_info = @typeInfo(CompilerOptions).@"struct".fields;
    inline for (co_info) |f| {
        if (comptime std.mem.eql(u8, f.name, "extra")) continue;
        const child_v = @field(child.compiler_options, f.name);
        if (child_v != null) {
            @field(merged.compiler_options, f.name) = child_v;
        }
    }
    // For `extra`, append child's entries (last-writer-wins on key
    // conflict per tsc semantics — child overrides base).
    var combined: std.ArrayListUnmanaged(ExtraEntry) = .empty;
    for (base.compiler_options.extra.items) |e| {
        // Skip base entries shadowed by child.
        var shadowed = false;
        for (child.compiler_options.extra.items) |ce| {
            if (std.mem.eql(u8, ce.key, e.key)) {
                shadowed = true;
                break;
            }
        }
        if (!shadowed) try combined.append(arena, e);
    }
    for (child.compiler_options.extra.items) |e| {
        try combined.append(arena, e);
    }
    merged.compiler_options.extra = combined;

    // Top-level keys: child overrides if set.
    if (child.files) |f| merged.files = f;
    if (child.include) |f| merged.include = f;
    if (child.exclude) |f| merged.exclude = f;
    if (child.references.len > 0) merged.references = child.references;
    if (child.extends.len > 0) merged.extends = child.extends;
    return merged;
}

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "tsconfig: minimal config" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": true, "target": "es2024" } }
    );
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.strict);
    try t.expectEqual(@as(?Target, .es2024), cfg.compiler_options.target);
}

test "tsconfig: full strict family" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "strict": true,
        \\    "noImplicitAny": true,
        \\    "strictNullChecks": true,
        \\    "strictFunctionTypes": true,
        \\    "strictBindCallApply": true,
        \\    "strictPropertyInitialization": true,
        \\    "noImplicitThis": true,
        \\    "useUnknownInCatchVariables": true,
        \\    "alwaysStrict": true
        \\  }
        \\}
    );
    const co = cfg.compiler_options;
    try t.expectEqual(@as(?bool, true), co.strict);
    try t.expectEqual(@as(?bool, true), co.no_implicit_any);
    try t.expectEqual(@as(?bool, true), co.strict_null_checks);
    try t.expectEqual(@as(?bool, true), co.strict_function_types);
    try t.expectEqual(@as(?bool, true), co.strict_bind_call_apply);
    try t.expectEqual(@as(?bool, true), co.strict_property_initialization);
    try t.expectEqual(@as(?bool, true), co.no_implicit_this);
    try t.expectEqual(@as(?bool, true), co.use_unknown_in_catch_variables);
    try t.expectEqual(@as(?bool, true), co.always_strict);
}

test "tsconfig: module / moduleResolution / target enums" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "esnext", "moduleResolution": "bundler", "target": "ES2022" } }
    );
    try t.expectEqual(@as(?Module, .esnext), cfg.compiler_options.module);
    try t.expectEqual(@as(?ModuleResolution, .bundler), cfg.compiler_options.module_resolution);
    try t.expectEqual(@as(?Target, .es2022), cfg.compiler_options.target);
}

test "tsconfig: jsx enum" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "jsx": "react-jsx" } }
    );
    try t.expectEqual(@as(?Jsx, .react_jsx), cfg.compiler_options.jsx);
}

test "tsconfig: include / exclude / files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "files": ["src/index.ts"],
        \\  "include": ["src/**/*"],
        \\  "exclude": ["node_modules", "dist"]
        \\}
    );
    try t.expectEqualStrings("src/index.ts", cfg.files.?[0]);
    try t.expectEqualStrings("src/**/*", cfg.include.?[0]);
    try t.expectEqualStrings("node_modules", cfg.exclude.?[0]);
    try t.expectEqualStrings("dist", cfg.exclude.?[1]);
}

test "tsconfig: extends as string" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "extends": "./base.json" }
    );
    try t.expectEqual(@as(usize, 1), cfg.extends.len);
    try t.expectEqualStrings("./base.json", cfg.extends[0]);
}

test "tsconfig: extends as array" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "extends": ["./a.json", "./b.json", "./c.json"] }
    );
    try t.expectEqual(@as(usize, 3), cfg.extends.len);
    try t.expectEqualStrings("./a.json", cfg.extends[0]);
    try t.expectEqualStrings("./c.json", cfg.extends[2]);
}

test "tsconfig: paths mapping" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "baseUrl": ".",
        \\    "paths": {
        \\      "@app/*": ["src/app/*"],
        \\      "@lib/*": ["src/lib/*", "vendor/lib/*"]
        \\    }
        \\  }
        \\}
    );
    const paths = cfg.compiler_options.paths.?;
    try t.expectEqual(@as(usize, 2), paths.patterns.len);
    try t.expectEqualStrings(".", cfg.compiler_options.base_url.?);
    try t.expectEqualStrings("@app/*", paths.patterns[0]);
    try t.expectEqualStrings("src/app/*", paths.substitutions[0][0]);
    try t.expectEqualStrings("@lib/*", paths.patterns[1]);
    try t.expectEqualStrings("src/lib/*", paths.substitutions[1][0]);
    try t.expectEqualStrings("vendor/lib/*", paths.substitutions[1][1]);
}

test "tsconfig: lib array" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "lib": ["es2024", "dom"] } }
    );
    const lib = cfg.compiler_options.lib.?;
    try t.expectEqualStrings("es2024", lib[0]);
    try t.expectEqualStrings("dom", lib[1]);
}

test "tsconfig: noEmit + skipLibCheck" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "noEmit": true, "skipLibCheck": true } }
    );
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.no_emit);
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.skip_lib_check);
}

test "tsconfig: unknown keys preserved in extra" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "futureFlag": true, "alsoUnknown": "value" } }
    );
    const extra = cfg.compiler_options.extra.items;
    try t.expectEqual(@as(usize, 2), extra.len);
    try t.expectEqualStrings("futureFlag", extra[0].key);
    try t.expectEqualStrings("alsoUnknown", extra[1].key);
    try t.expectEqual(true, extra[0].value.asBool().?);
    try t.expectEqualStrings("value", extra[1].value.asString().?);
}

test "tsconfig: invalid module value rejected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.UnknownEnumValue, parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "atomic-fission" } }
    ));
}

test "tsconfig: real-world tsconfig.json (with comments)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  // Common settings for the home repo.
        \\  "compilerOptions": {
        \\    "target": "es2024",
        \\    "module": "esnext",
        \\    "moduleResolution": "bundler",
        \\    "strict": true,
        \\    "skipLibCheck": true,
        \\    "noEmit": true,
        \\    "allowImportingTsExtensions": true,
        \\    "esModuleInterop": true,
        \\    "verbatimModuleSyntax": true,
        \\    "resolveJsonModule": true,
        \\    "lib": ["es2024", "dom", "dom.iterable"],
        \\    "paths": {
        \\      "@/*": ["src/*"]
        \\    }
        \\  },
        \\  "include": ["src/**/*", "tests/**/*"],
        \\  "exclude": ["node_modules", "dist", ".zig-cache"]
        \\}
    );
    const co = cfg.compiler_options;
    try t.expectEqual(@as(?Target, .es2024), co.target);
    try t.expectEqual(@as(?Module, .esnext), co.module);
    try t.expectEqual(@as(?ModuleResolution, .bundler), co.module_resolution);
    try t.expectEqual(@as(?bool, true), co.strict);
    try t.expectEqual(@as(usize, 3), co.lib.?.len);
    try t.expectEqualStrings("src/**/*", cfg.include.?[0]);
    try t.expectEqual(@as(usize, 3), cfg.exclude.?.len);
}

test "tsconfig: newly-added bool fields parse" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "noImplicitReturns": true,
        \\    "noFallthroughCasesInSwitch": true,
        \\    "allowSyntheticDefaultImports": true,
        \\    "forceConsistentCasingInFileNames": true,
        \\    "skipLibCheck": true,
        \\    "isolatedModules": true,
        \\    "useDefineForClassFields": true,
        \\    "verbatimModuleSyntax": true
        \\  }
        \\}
    );
    const co = cfg.compiler_options;
    try t.expectEqual(@as(?bool, true), co.no_implicit_returns);
    try t.expectEqual(@as(?bool, true), co.no_fallthrough_cases_in_switch);
    try t.expectEqual(@as(?bool, true), co.allow_synthetic_default_imports);
    try t.expectEqual(@as(?bool, true), co.force_consistent_casing_in_file_names);
    try t.expectEqual(@as(?bool, true), co.skip_lib_check);
    try t.expectEqual(@as(?bool, true), co.isolated_modules);
    try t.expectEqual(@as(?bool, true), co.use_define_for_class_fields);
    try t.expectEqual(@as(?bool, true), co.verbatim_module_syntax);
    // None of these landed in the pass-through bag.
    try t.expectEqual(@as(usize, 0), co.extra.items.len);
}

test "tsconfig: moduleDetection parses as string" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "moduleDetection": "force" } }
    );
    try t.expectEqualStrings("force", cfg.compiler_options.module_detection.?);
}

test "tsconfig: merge propagates new bool fields" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const base = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "skipLibCheck": false, "forceConsistentCasingInFileNames": true } }
    );
    const child = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "skipLibCheck": true, "useDefineForClassFields": true } }
    );
    const m = try merge(arena.allocator(), base, child);
    // child overrides base
    try t.expectEqual(@as(?bool, true), m.compiler_options.skip_lib_check);
    // base-only field preserved
    try t.expectEqual(@as(?bool, true), m.compiler_options.force_consistent_casing_in_file_names);
    // child-only field present
    try t.expectEqual(@as(?bool, true), m.compiler_options.use_define_for_class_fields);
}

test "tsconfig: emit-helper / decorator / suppress bool fields parse" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "noEmitHelpers": true,
        \\    "downlevelIteration": true,
        \\    "preserveConstEnums": true,
        \\    "experimentalDecorators": true,
        \\    "emitDecoratorMetadata": true,
        \\    "keyofStringsOnly": true,
        \\    "suppressExcessPropertyErrors": true,
        \\    "suppressImplicitAnyIndexErrors": true
        \\  }
        \\}
    );
    const co = cfg.compiler_options;
    try t.expectEqual(@as(?bool, true), co.no_emit_helpers);
    try t.expectEqual(@as(?bool, true), co.down_level_iteration);
    try t.expectEqual(@as(?bool, true), co.preserve_const_enums);
    try t.expectEqual(@as(?bool, true), co.experimental_decorators);
    try t.expectEqual(@as(?bool, true), co.emit_decorator_metadata);
    try t.expectEqual(@as(?bool, true), co.keyof_strings_only);
    try t.expectEqual(@as(?bool, true), co.suppress_excess_property_errors);
    try t.expectEqual(@as(?bool, true), co.suppress_implicit_any_index_errors);
    try t.expectEqual(@as(usize, 0), co.extra.items.len);
}

test "tsconfig: incremental / build-affecting bool fields parse" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "assumeChangesOnlyAffectDirectDependencies": true,
        \\    "disableSizeLimit": true,
        \\    "skipDefaultLibCheck": true,
        \\    "composite": true
        \\  }
        \\}
    );
    const co = cfg.compiler_options;
    try t.expectEqual(@as(?bool, true), co.assume_changes_only_affect_direct_dependencies);
    try t.expectEqual(@as(?bool, true), co.disable_size_limit);
    try t.expectEqual(@as(?bool, true), co.skip_default_lib_check);
    try t.expectEqual(@as(?bool, true), co.composite);
    try t.expectEqual(@as(usize, 0), co.extra.items.len);
}

test "tsconfig.merge: child overrides base on every set field" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const base = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": false, "target": "es2015", "noEmit": true } }
    );
    const child = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": true, "target": "es2024" } }
    );
    const m = try merge(arena.allocator(), base, child);
    try t.expectEqual(@as(?bool, true), m.compiler_options.strict);
    try t.expectEqual(@as(?Target, .es2024), m.compiler_options.target);
    // `noEmit` was only in base — preserved.
    try t.expectEqual(@as(?bool, true), m.compiler_options.no_emit);
}

// ============================================================================
// tsconfig-style glob matcher
// ============================================================================
//
// Pure pattern → path matching that mirrors `tsc`'s behavior for
// `include` / `exclude` entries:
//
//   - `*` matches any run of characters except `/`
//   - `**` matches any number of path segments (including zero)
//   - `?` matches a single non-`/` character
//   - everything else is literal
//
// Patterns and paths are forward-slash-normalized. The matcher does
// not touch the filesystem — pair it with a directory walker
// (e.g. `home-tsc`'s project-mode file enumerator) to expand a
// pattern into the actual file set.

/// Return true if `path` matches the tsconfig-style glob `pattern`.
/// Both are forward-slash-normalized; the caller is responsible for
/// converting `\` → `/` on Windows-shaped inputs.
pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    return matchGlobAt(pattern, 0, path, 0);
}

fn matchGlobAt(pattern: []const u8, pi_in: usize, path: []const u8, si_in: usize) bool {
    var pi = pi_in;
    var si = si_in;
    while (pi < pattern.len) {
        // `**` — zero or more segments. Try every position from `si`
        // forward as the resumption point.
        if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
            // Skip a trailing `/` after `**` so `src/**/foo` and
            // `src/**foo` behave per tsc (the former requires at
            // least the separator at the join, the latter is rare).
            var rest_start = pi + 2;
            if (rest_start < pattern.len and pattern[rest_start] == '/') rest_start += 1;
            // `**` at end matches the rest unconditionally.
            if (rest_start == pattern.len) return true;
            // Try every cursor position (including beyond `/`).
            var probe = si;
            while (probe <= path.len) : (probe += 1) {
                if (matchGlobAt(pattern, rest_start, path, probe)) return true;
                if (probe < path.len) {
                    // Skip past one segment per attempt; we resume
                    // matching at every byte to handle glob inside
                    // a basename.
                }
            }
            return false;
        }
        // `*` — zero or more chars except `/`.
        if (pattern[pi] == '*') {
            const rest_start = pi + 1;
            if (rest_start == pattern.len) {
                // Match the rest of the segment but not past `/`.
                while (si < path.len and path[si] != '/') si += 1;
                return si == path.len;
            }
            var probe = si;
            while (true) {
                if (matchGlobAt(pattern, rest_start, path, probe)) return true;
                if (probe == path.len) return false;
                if (path[probe] == '/') return false;
                probe += 1;
            }
        }
        // `?` — single non-`/` char.
        if (pattern[pi] == '?') {
            if (si >= path.len or path[si] == '/') return false;
            pi += 1;
            si += 1;
            continue;
        }
        // Literal.
        if (si >= path.len or pattern[pi] != path[si]) return false;
        pi += 1;
        si += 1;
    }
    return si == path.len;
}

test "matchGlob: literal" {
    // top-level `t = std.testing` already in scope
    try t.expect(matchGlob("src/main.ts", "src/main.ts"));
    try t.expect(!matchGlob("src/main.ts", "src/other.ts"));
}

test "matchGlob: single star matches within segment" {
    // top-level `t = std.testing` already in scope
    try t.expect(matchGlob("src/*.ts", "src/main.ts"));
    try t.expect(matchGlob("src/*.ts", "src/a.ts"));
    try t.expect(!matchGlob("src/*.ts", "src/sub/main.ts"));
}

test "matchGlob: double-star spans segments" {
    // top-level `t = std.testing` already in scope
    try t.expect(matchGlob("src/**/*.ts", "src/main.ts"));
    try t.expect(matchGlob("src/**/*.ts", "src/sub/main.ts"));
    try t.expect(matchGlob("src/**/*.ts", "src/sub/deep/main.ts"));
    try t.expect(!matchGlob("src/**/*.ts", "lib/main.ts"));
}

test "matchGlob: leading double-star matches any prefix" {
    // top-level `t = std.testing` already in scope
    try t.expect(matchGlob("**/foo.ts", "foo.ts"));
    try t.expect(matchGlob("**/foo.ts", "a/foo.ts"));
    try t.expect(matchGlob("**/foo.ts", "a/b/foo.ts"));
}

test "matchGlob: question matches single char" {
    // top-level `t = std.testing` already in scope
    try t.expect(matchGlob("a?c.ts", "abc.ts"));
    try t.expect(matchGlob("a?c.ts", "axc.ts"));
    try t.expect(!matchGlob("a?c.ts", "ac.ts"));
    try t.expect(!matchGlob("a?c.ts", "abbc.ts"));
}

test "matchGlob: trailing double-star matches everything" {
    // top-level `t = std.testing` already in scope
    try t.expect(matchGlob("dist/**", "dist/a.js"));
    try t.expect(matchGlob("dist/**", "dist/a/b.js"));
    try t.expect(!matchGlob("dist/**", "src/a.js"));
}
