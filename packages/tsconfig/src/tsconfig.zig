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
    node20,
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
            .{ "node20", .node20 },
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
    es2025,
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
            .{ "es2025", .es2025 },
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

pub fn enumOptionValueIsValid(option: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, option, "module")) return Module.fromString(value) != null;
    if (std.mem.eql(u8, option, "moduleResolution")) return ModuleResolution.fromString(value) != null;
    if (std.mem.eql(u8, option, "target")) return Target.fromString(value) != null;
    if (std.mem.eql(u8, option, "jsx")) return Jsx.fromString(value) != null;
    return true;
}

pub fn enumOptionAllowedValues(option: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, option, "module")) return "'commonjs', 'es6', 'es2015', 'es2020', 'es2022', 'esnext', 'node16', 'node18', 'node20', 'nodenext', 'preserve'";
    if (std.mem.eql(u8, option, "moduleResolution")) return "'node16', 'nodenext', 'bundler'";
    if (std.mem.eql(u8, option, "target")) return "'es6', 'es2015', 'es2016', 'es2017', 'es2018', 'es2019', 'es2020', 'es2021', 'es2022', 'es2023', 'es2024', 'es2025', 'esnext'";
    if (std.mem.eql(u8, option, "jsx")) return "'preserve', 'react-native', 'react-jsx', 'react-jsxdev', 'react'";
    return null;
}

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
    erasable_syntax_only: ?bool = null,
    skip_lib_check: ?bool = null,
    skip_default_lib_check: ?bool = null,
    force_consistent_casing_in_file_names: ?bool = null,
    trace_resolution: ?bool = null,
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
    resolve_package_json_exports: ?bool = null,
    resolve_package_json_imports: ?bool = null,
    custom_conditions: ?[][]const u8 = null,
    allow_importing_ts_extensions: ?bool = null,
    rewrite_relative_import_extensions: ?bool = null,
    es_module_interop: ?bool = null,
    isolated_modules: ?bool = null,
    isolated_declarations: ?bool = null,
    verbatim_module_syntax: ?bool = null,
    allow_synthetic_default_imports: ?bool = null,
    module_detection: ?[]const u8 = null,
    ignore_deprecations: ?[]const u8 = null,

    // -- Emit --
    target: ?Target = null,
    lib: ?[][]const u8 = null,
    no_lib: ?bool = null,
    jsx: ?Jsx = null,
    jsx_factory: ?[]const u8 = null,
    jsx_fragment_factory: ?[]const u8 = null,
    jsx_import_source: ?[]const u8 = null,
    react_namespace: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    root_dir: ?[]const u8 = null,
    declaration: ?bool = null,
    declaration_dir: ?[]const u8 = null,
    declaration_map: ?bool = null,
    emit_declaration_only: ?bool = null,
    map_root: ?[]const u8 = null,
    source_root: ?[]const u8 = null,
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

pub const RootOptionDecl = struct {
    name: []const u8,
    kind: []const u8,
    /// TSxxxx code of the tsconfig root-option category header.
    category: u32 = 0,
};

/// Root-level tsconfig options that TypeScript declares outside
/// `compilerOptions`. The File Management category is used by editor
/// configuration/help surfaces and mirrors tsgo's tsconfig parser
/// declarations.
pub const root_option_decls = [_]RootOptionDecl{
    .{ .name = "extends", .kind = "listOrElement", .category = 6245 },
    .{ .name = "files", .kind = "list", .category = 6245 },
    .{ .name = "include", .kind = "list", .category = 6245 },
    .{ .name = "exclude", .kind = "list", .category = 6245 },
};

pub fn rootOptionCategoryCode(name: []const u8) ?u32 {
    for (root_option_decls) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return decl.category;
    }
    return null;
}

/// Diagnostic captured by the parser (`fillCompilerOptions`) for an
/// option whose value or placement is malformed. Stored on the parsed
/// `TsConfig` so `validate` can re-emit it with an owned message rather
/// than aborting the entire parse on the first bad value — which matches
/// `tsc`, which keeps parsing the rest of the config.
pub const OptionParseDiagnostic = struct {
    code: u32,
    /// Compiler option name (`{0}`), e.g. `"target"`.
    option: []const u8,
    /// Expected value type rendered into the message (`{1}` for
    /// TS5024). Empty for codes that don't use it.
    expected_type: []const u8 = "",
    /// For TS5064: the offending substitution string (`{0}`), the
    /// pattern it belongs to (`{1}`), and the JSON type we got (`{2}`).
    substitution: []const u8 = "",
    pattern: []const u8 = "",
    got_type: []const u8 = "",
};

/// Syntax diagnostics produced by the JSONC parser that TypeScript
/// reports while still recovering a usable config tree.
pub const JsonParseDiagnostic = struct {
    code: u32,
    pos: u32,
    line: u32,
    column: u32,
    message: []const u8,
};

pub const TsConfig = struct {
    /// The path this config came from (set by the loader; empty when
    /// parsed via `parseString`).
    file_path: []const u8,
    /// Compiler options.
    compiler_options: CompilerOptions,
    /// `extends`: paths of other tsconfig files this one inherits from.
    extends: [][]const u8,
    /// Whether the raw config contained an `extends` property. This is
    /// distinct from `extends.len`: `extends: []` still suppresses the
    /// empty-`files` diagnostic in tsc.
    has_extends: bool,
    /// `files`: explicit file list. `null` if not present.
    files: ?[][]const u8,
    /// `include`: glob patterns. `null` if not present (default
    /// `["**/*"]` if neither `files` nor `include` is set).
    include: ?[][]const u8,
    /// `exclude`: glob patterns. `null` if not present.
    exclude: ?[][]const u8,
    /// `references`: project-references entries. Phase 9 fills in.
    references: [][]const u8,
    /// Unknown keys seen inside top-level `typeAcquisition`. TypeScript
    /// validates that object with its own option table rather than
    /// treating these as generic unknown root keys.
    unknown_type_acquisition_options: [][]const u8,
    /// True when the root object carried an `excludes` key. tsc special-
    /// cases this exact misspelling at the config root with a dedicated
    /// "Did you mean 'exclude'?" diagnostic (TS6114) rather than the
    /// generic unknown-key handling.
    has_excludes_root_key: bool = false,
    /// Diagnostics recorded during `parseString` that are best surfaced
    /// alongside cross-field validation rather than aborting the parse.
    /// Holds value-type mismatches (TS5024) and `paths` substitution
    /// type errors (TS5064) so a single malformed option doesn't lose
    /// the rest of the config. Allocated in the parse arena; `validate`
    /// re-emits them (with arena-owned messages) so callers see them
    /// next to the TS50xx consistency diagnostics. Empty when the
    /// config parsed cleanly.
    option_parse_diagnostics: []OptionParseDiagnostic = &.{},
    /// JSON syntax diagnostics that did not prevent recovery. Today this
    /// covers TS1012 ("Unexpected token.") for extra top-level JSON
    /// expressions after the config object.
    json_parse_diagnostics: []JsonParseDiagnostic = &.{},
    /// True when the config file's JSON root was present but was not an
    /// object (e.g. a top-level array, string, number, boolean, or
    /// `null`). tsc's `convertConfigFileToObject` reports TS5092 and
    /// recovers with an empty config (or, for a top-level array, the
    /// first object element). `validate` re-emits the TS5092 here.
    root_not_object: bool = false,

    /// Walk the resolved config and report cross-field consistency
    /// issues that the parser accepts but `tsc` would reject during
    /// option resolution. Each individual field is already
    /// well-formed (enum-typed values were checked at parse time);
    /// this layer catches combinations like
    /// `composite: true` without `declaration: true` (TS6304) or
    /// `outDir == rootDir` (TS5009-style overlap).
    ///
    /// Returns an owned slice allocated with `gpa`. Caller frees with
    /// `freeValidationDiagnostics`. Empty slice when the config is
    /// consistent.
    ///
    /// v0 covers two cross-field checks; the rest of the matrix
    /// (noEmit + outFile contradiction, decorators mutual exclusion,
    /// experimentalDecorators stage-3 conflict, lib/target sanity,
    /// etc.) is tracked as follow-ups and will land alongside the
    /// option-resolution pass in the type checker.
    pub fn validate(self: TsConfig, gpa: std.mem.Allocator) ![]ValidationDiagnostic {
        var diags: std.ArrayListUnmanaged(ValidationDiagnostic) = .empty;
        errdefer diags.deinit(gpa);

        const co = self.compiler_options;

        // TS5092: a non-object JSON root. tsc reports this as the config
        // file's error and recovers with an empty config, so it reads
        // first, ahead of any option-level diagnostics.
        if (self.root_not_object) {
            const base = rootConfigBaseName(self.file_path);
            const msg = try std.fmt.allocPrint(gpa, "The root value of a '{s}' file must be an object.", .{base});
            try diags.append(gpa, .{
                .code = 5092,
                .message = msg,
                .owns_message = true,
                .field = "",
            });
        }

        // TS1012: JSON parser recovery for extra top-level expressions
        // after the config object. TypeScript keeps the first config
        // object and reports the unexpected token.
        for (self.json_parse_diagnostics) |parse_diag| {
            try diags.append(gpa, .{
                .code = parse_diag.code,
                .message = parse_diag.message,
                .field = "",
            });
        }

        // Surface value-type diagnostics the parser captured rather than
        // aborting on (TS5024 value-type mismatch, TS5064 paths
        // substitution type). Done first so they read in source order
        // ahead of the cross-field consistency checks below.
        for (self.option_parse_diagnostics) |opt_diag| {
            switch (opt_diag.code) {
                1328 => {
                    try appendInvalidJsonPropertyValueDiagnostic(gpa, &diags, opt_diag.option);
                },
                5024 => {
                    const msg = try std.fmt.allocPrint(gpa, "Compiler option '{s}' requires a value of type {s}.", .{ opt_diag.option, opt_diag.expected_type });
                    try diags.append(gpa, .{
                        .code = 5024,
                        .message = msg,
                        .owns_message = true,
                        .field = opt_diag.option,
                    });
                },
                5064 => {
                    const msg = try std.fmt.allocPrint(gpa, "Substitution '{s}' for pattern '{s}' has incorrect type, expected 'string', got '{s}'.", .{ opt_diag.substitution, opt_diag.pattern, opt_diag.got_type });
                    try diags.append(gpa, .{
                        .code = 5064,
                        .message = msg,
                        .owns_message = true,
                        .field = "paths",
                    });
                },
                5063 => {
                    const msg = try std.fmt.allocPrint(gpa, "Substitutions for pattern '{s}' should be an array.", .{opt_diag.pattern});
                    try diags.append(gpa, .{
                        .code = 5063,
                        .message = msg,
                        .owns_message = true,
                        .field = "paths",
                    });
                },
                6046 => {
                    const msg = try std.fmt.allocPrint(gpa, "Argument for '--{s}' option must be: {s}.", .{ opt_diag.option, opt_diag.expected_type });
                    try diags.append(gpa, .{
                        .code = 6046,
                        .message = msg,
                        .owns_message = true,
                        .field = opt_diag.option,
                    });
                },
                6266 => {
                    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' can only be specified on command line.", .{opt_diag.option});
                    try diags.append(gpa, .{
                        .code = 6266,
                        .message = msg,
                        .owns_message = true,
                        .field = opt_diag.option,
                    });
                },
                else => {},
            }
        }

        // TS5023 / TS5025: unknown compiler option (with a spelling
        // suggestion when one is close enough). Keys the parser couldn't
        // map to a known option land in `extra`; report each that isn't
        // a recognized TypeScript compiler option name.
        for (co.extra.items) |entry| {
            if (isKnownCompilerOptionName(entry.key)) continue;
            const suggestion = compilerOptionSuggestion(entry.key);
            const msg = if (suggestion) |suggested|
                try std.fmt.allocPrint(gpa, "Unknown compiler option '{s}'. Did you mean '{s}'?", .{ entry.key, suggested })
            else
                try std.fmt.allocPrint(gpa, "Unknown compiler option '{s}'.", .{entry.key});
            try diags.append(gpa, .{
                .code = if (suggestion != null) 5025 else 5023,
                .message = msg,
                .owns_message = true,
                .field = entry.key,
            });
            if (containsInvalidJsonValue(entry.value)) {
                try appendInvalidJsonPropertyValueDiagnostic(gpa, &diags, entry.key);
            }
        }

        // TS5108 / TS5106: options removed in TypeScript 7. tsc emits
        // these from the program/option-resolution pass; we mirror the
        // exact set and message (with the "Use {0} instead" chain where
        // applicable).
        try appendRemovedOptionDiagnostics(gpa, &diags, self);

        // TS5010 / TS5065: file-specification glob shapes that tsc
        // rejects. `include` disallows a trailing recursive wildcard;
        // `exclude` disallows a `..` segment after a `**` wildcard.
        try appendFileSpecDiagnostics(gpa, &diags, self);

        // TS18051: `extends` accepts a path or path array, but each
        // path must be non-empty. TypeScript reports one diagnostic per
        // empty string element.
        for (self.extends) |path| {
            if (path.len == 0) {
                try diags.append(gpa, .{
                    .code = 18051,
                    .message = "Compiler option 'extends' cannot be given an empty string.",
                    .field = "extends",
                });
            }
        }

        if (self.files) |files| {
            if (files.len == 0 and self.references.len == 0 and !self.has_extends) {
                const path = if (self.file_path.len > 0) self.file_path else "tsconfig.json";
                const msg = try std.fmt.allocPrint(gpa, "The 'files' list in config file '{s}' is empty.", .{path});
                try diags.append(gpa, .{
                    .code = 18002,
                    .message = msg,
                    .owns_message = true,
                    .field = "files",
                });
            }
        }

        // TS6114: tsc special-cases the `excludes` misspelling at the
        // config root with a fixed "Did you mean 'exclude'?" message
        // (the value shape is irrelevant — the key alone triggers it).
        if (self.has_excludes_root_key) {
            try diags.append(gpa, .{
                .code = 6114,
                .message = "Unknown option 'excludes'. Did you mean 'exclude'?",
                .field = "excludes",
            });
        }

        for (self.unknown_type_acquisition_options) |option| {
            const suggestion = typeAcquisitionOptionSuggestion(option);
            const msg = if (suggestion) |suggested|
                try std.fmt.allocPrint(gpa, "Unknown type acquisition option '{s}'. Did you mean '{s}'?", .{ option, suggested })
            else
                try std.fmt.allocPrint(gpa, "Unknown type acquisition option '{s}'.", .{option});
            try diags.append(gpa, .{
                .code = if (suggestion != null) 17018 else 17010,
                .message = msg,
                .owns_message = true,
                .field = "typeAcquisition",
            });
        }

        if (co.paths) |paths| {
            try validatePaths(gpa, &diags, paths, co.base_url != null);
        }

        if (co.ignore_deprecations) |ignore_deprecations| {
            if (!std.mem.eql(u8, ignore_deprecations, "5.0") and !std.mem.eql(u8, ignore_deprecations, "6.0")) {
                try diags.append(gpa, .{
                    .code = 5103,
                    .message = "Invalid value for '--ignoreDeprecations'.",
                    .field = "ignoreDeprecations",
                });
            }
        }

        if (co.isolated_modules == true and co.module == .none and !targetAtLeastES2015(co.target)) {
            try diags.append(gpa, .{
                .code = 5047,
                .message = "Option 'isolatedModules' can only be used when either option '--module' is provided or option 'target' is 'ES2015' or higher.",
                .field = "isolatedModules",
            });
        }

        const effective_module = effectiveModuleKind(co);
        const effective_module_resolution = effectiveModuleResolution(co, effective_module);
        if (co.allow_importing_ts_extensions == true and !(co.no_emit == true or co.emit_declaration_only == true or co.rewrite_relative_import_extensions == true)) {
            try diags.append(gpa, .{
                .code = 5096,
                .message = "Option 'allowImportingTsExtensions' can only be used when one of 'noEmit', 'emitDeclarationOnly', or 'rewriteRelativeImportExtensions' is set.",
                .field = "allowImportingTsExtensions",
            });
        }
        if (!moduleResolutionSupportsPackageJsonExportsAndImports(effective_module_resolution)) {
            if (co.resolve_package_json_exports == true) {
                try appendTs5098(gpa, &diags, "resolvePackageJsonExports");
            }
            if (co.resolve_package_json_imports == true) {
                try appendTs5098(gpa, &diags, "resolvePackageJsonImports");
            }
            if (co.custom_conditions != null) {
                try appendTs5098(gpa, &diags, "customConditions");
            }
        }
        if (effective_module_resolution == .bundler and !moduleKindIsNonNodeESM(effective_module) and effective_module != .preserve and effective_module != .commonjs) {
            try appendTs5095(gpa, &diags, "bundler");
        }
        if (moduleKindIsNode(effective_module) and !moduleResolutionIsNode(effective_module_resolution)) {
            try appendTs5109(gpa, &diags, moduleResolutionNameForModule(effective_module), moduleName(effective_module));
        } else if (moduleResolutionIsNode(effective_module_resolution) and !moduleKindIsNode(effective_module)) {
            try appendTs5110(gpa, &diags, moduleResolutionName(effective_module_resolution), moduleResolutionName(effective_module_resolution));
        }

        const strict_null_checks_enabled = co.strict_null_checks orelse (co.strict == true);
        if (co.strict_property_initialization == true and !strict_null_checks_enabled) {
            try appendTs5052(gpa, &diags, "strictPropertyInitialization", "strictPropertyInitialization", "strictNullChecks");
        }
        if (co.exact_optional_property_types == true and !strict_null_checks_enabled) {
            try appendTs5052(gpa, &diags, "exactOptionalPropertyTypes", "exactOptionalPropertyTypes", "strictNullChecks");
        }
        if (co.check_js == true and co.allow_js != true) {
            try appendTs5052(gpa, &diags, "checkJs", "checkJs", "allowJs");
        }
        if (co.emit_decorator_metadata == true and co.experimental_decorators != true) {
            try appendTs5052(gpa, &diags, "emitDecoratorMetadata", "emitDecoratorMetadata", "experimentalDecorators");
        }
        if (co.inline_source_map == true and co.source_map == true) {
            try appendTs5053(gpa, &diags, "sourceMap", "sourceMap", "inlineSourceMap");
        }
        if (co.source_map != true and co.inline_source_map != true) {
            if (co.inline_sources == true) {
                try appendTs5051(gpa, &diags, "inlineSources", "inlineSources");
            }
            if (co.source_root != null) {
                try appendTs5051(gpa, &diags, "sourceRoot", "sourceRoot");
            }
        }
        if (co.isolated_declarations == true and co.allow_js == true) {
            try appendTs5053(gpa, &diags, "allowJs", "allowJs", "isolatedDeclarations");
        }
        if (co.jsx_factory) |jsx_factory| {
            if (co.react_namespace != null) {
                try appendTs5053(gpa, &diags, "reactNamespace", "reactNamespace", "jsxFactory");
            }
            if (jsxDisallowsClassicFactory(co.jsx)) |jsx_value| {
                try appendTs5089(gpa, &diags, "jsxFactory", "jsxFactory", jsx_value);
            }
            if (!isEntityNameText(jsx_factory)) {
                try appendInvalidJsxFactory(gpa, &diags, "jsxFactory", jsx_factory);
            }
        } else if (co.react_namespace) |react_namespace| {
            if (!isIdentifierNameText(react_namespace)) {
                try appendInvalidReactNamespace(gpa, &diags, "reactNamespace", react_namespace);
            }
        }
        if (co.jsx_fragment_factory) |jsx_fragment_factory| {
            if (co.jsx_factory == null) {
                try appendTs5052(gpa, &diags, "jsxFragmentFactory", "jsxFragmentFactory", "jsxFactory");
            }
            if (jsxDisallowsClassicFactory(co.jsx)) |jsx_value| {
                try appendTs5089(gpa, &diags, "jsxFragmentFactory", "jsxFragmentFactory", jsx_value);
            }
            if (!isEntityNameText(jsx_fragment_factory)) {
                try appendInvalidJsxFragmentFactory(gpa, &diags, "jsxFragmentFactory", jsx_fragment_factory);
            }
        }
        if (co.react_namespace != null) {
            if (jsxDisallowsClassicFactory(co.jsx)) |jsx_value| {
                try appendTs5089(gpa, &diags, "reactNamespace", "reactNamespace", jsx_value);
            }
        }
        if (co.preserve_const_enums == false and (co.isolated_modules == true or co.verbatim_module_syntax == true)) {
            const enabled = if (co.verbatim_module_syntax == true) "verbatimModuleSyntax" else "isolatedModules";
            try appendTs5091(gpa, &diags, "preserveConstEnums", enabled);
        }

        const emit_declarations = co.declaration == true or co.composite == true;
        if (co.isolated_declarations == true and !emit_declarations) {
            try appendTs5069(gpa, &diags, "isolatedDeclarations", "isolatedDeclarations", "declaration", "composite");
        }
        if (co.map_root != null and !(co.source_map == true or co.declaration_map == true)) {
            try appendTs5069(gpa, &diags, "mapRoot", "mapRoot", "sourceMap", "declarationMap");
        }
        if (co.declaration_dir != null and !emit_declarations) {
            try appendTs5069(gpa, &diags, "declarationDir", "declarationDir", "declaration", "composite");
        }
        if (co.declaration_map == true and !emit_declarations) {
            try appendTs5069(gpa, &diags, "declarationMap", "declarationMap", "declaration", "composite");
        }
        if (co.emit_declaration_only == true and !emit_declarations) {
            try appendTs5069(gpa, &diags, "emitDeclarationOnly", "emitDeclarationOnly", "declaration", "composite");
        }

        // TS5009-shaped: `outDir` and `rootDir` must not be the same
        // path string. (Strict literal equality is a v0 approximation
        // — `tsc` resolves both to absolute paths first; we'll do
        // that once the path resolver lands.)
        if (co.out_dir) |o| {
            if (co.root_dir) |r| {
                if (std.mem.eql(u8, o, r)) {
                    try diags.append(gpa, .{
                        .code = 5009,
                        .message = "Option 'outDir' must be different from 'rootDir'.",
                        .field = "outDir",
                    });
                }
            }
        }

        // TS6304-shaped: `composite: true` requires `declaration: true`.
        // tsc auto-implies `declaration` when `composite` is set, but
        // emits a diagnostic when the user *explicitly* set
        // `declaration: false` alongside `composite: true`.
        if (co.composite == true) {
            if (co.declaration) |d| {
                if (!d) {
                    try diags.append(gpa, .{
                        .code = 6304,
                        .message = "Composite projects may not disable declaration emit.",
                        .field = "declaration",
                    });
                }
            }
            // TS6379-shaped: composite projects are always incremental;
            // explicitly setting `incremental: false` is rejected. tsc
            // emits this from the same option-resolution block as
            // TS6304 (program.go `if options.Composite.IsTrue()`),
            // pointing at the `declaration` option name.
            if (co.incremental) |inc| {
                if (!inc) {
                    try diags.append(gpa, .{
                        .code = 6379,
                        .message = "Composite projects may not disable incremental compilation.",
                        .field = "declaration",
                    });
                }
            }
        }

        return diags.toOwnedSlice(gpa);
    }
};

/// Diagnostic emitted by `TsConfig.validate` for cross-field issues
/// that the parser accepts (each field is individually well-formed)
/// but `tsc` would reject during option-resolution.
pub const ValidationDiagnostic = struct {
    code: u32,
    message: []const u8,
    owns_message: bool = false,
    /// Which option triggered the diagnostic. Empty when the issue
    /// spans multiple fields equally.
    field: []const u8 = "",
};

pub fn freeValidationDiagnostics(gpa: std.mem.Allocator, diags: []ValidationDiagnostic) void {
    for (diags) |d| {
        if (d.owns_message) gpa.free(d.message);
    }
    gpa.free(diags);
}

/// The `{0}` argument for TS5092 — the config file's base name. tsc uses
/// `"jsconfig.json"` when the file is a jsconfig and `"tsconfig.json"`
/// otherwise (the default when the path is unknown).
fn rootConfigBaseName(file_path: []const u8) []const u8 {
    const base = std.fs.path.basename(file_path);
    if (std.mem.eql(u8, base, "jsconfig.json")) return "jsconfig.json";
    return "tsconfig.json";
}

fn appendInvalidJsonPropertyValueDiagnostic(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
) !void {
    try diags.append(gpa, .{
        .code = 1328,
        .message = "Property value can only be string literal, numeric literal, 'true', 'false', 'null', object literal or array literal.",
        .field = field,
    });
}

/// All valid `compilerOptions` keys recognized by `tsc` (the
/// `OptionsDeclarations` set: `commonOptionsWithBuild` + the
/// compiler-specific options). Used to decide whether a key that fell
/// through into `extra` is genuinely unknown (TS5023/TS5025) versus a
/// real option Home simply hasn't materialized into a typed field yet.
/// Kept in sync with upstream `internal/tsoptions/declscompiler.go`.
const known_compiler_option_names = [_][]const u8{
    // commonOptionsWithBuild
    "help",
    "watch",
    "preserveWatchOutput",
    "listFiles",
    "explainFiles",
    "listEmittedFiles",
    "pretty",
    "traceResolution",
    "diagnostics",
    "extendedDiagnostics",
    "generateCpuProfile",
    "generateTrace",
    "incremental",
    "declaration",
    "declarationMap",
    "emitDeclarationOnly",
    "assumeChangesOnlyAffectDirectDependencies",
    "locale",
    // optionsForCompiler
    "all",
    "version",
    "init",
    "project",
    "showConfig",
    "listFilesOnly",
    "target",
    "module",
    "lib",
    "allowJs",
    "checkJs",
    "jsx",
    "outFile",
    "outDir",
    "rootDir",
    "composite",
    "tsBuildInfoFile",
    "removeComments",
    "types",
    "noEmit",
    "importHelpers",
    "downlevelIteration",
    "isolatedModules",
    "verbatimModuleSyntax",
    "stableTypeOrdering",
    "strict",
    "noImplicitAny",
    "strictNullChecks",
    "strictFunctionTypes",
    "strictBindCallApply",
    "strictBuiltinIteratorReturn",
    "strictPropertyInitialization",
    "noImplicitThis",
    "useUnknownInCatchVariables",
    "alwaysStrict",
    "noUnusedLocals",
    "noUnusedParameters",
    "exactOptionalPropertyTypes",
    "noImplicitReturns",
    "noFallthroughCasesInSwitch",
    "noUncheckedIndexedAccess",
    "noImplicitOverride",
    "noPropertyAccessFromIndexSignature",
    "moduleResolution",
    "baseUrl",
    "paths",
    "rootDirs",
    "typeRoots",
    "allowImportingTsExtensions",
    "resolvePackageJsonExports",
    "resolvePackageJsonImports",
    "customConditions",
    "noUncheckedSideEffectImports",
    "esModuleInterop",
    "preserveSymlinks",
    "allowUmdGlobalAccess",
    "moduleSuffixes",
    "allowArbitraryExtensions",
    "sourceMap",
    "inlineSourceMap",
    "inlineSources",
    "sourceRoot",
    "mapRoot",
    "declarationDir",
    "noEmitHelpers",
    "noEmitOnError",
    "emitBOM",
    "newLine",
    "stripInternal",
    "noResolve",
    "disableSizeLimit",
    "noLib",
    "jsxFactory",
    "jsxFragmentFactory",
    "jsxImportSource",
    "reactNamespace",
    "skipDefaultLibCheck",
    "emitDecoratorMetadata",
    "experimentalDecorators",
    "deduplicatePackages",
    "noErrorTruncation",
    "preserveConstEnums",
    "moduleDetection",
    "skipLibCheck",
    "checkers",
    "disableSourceOfProjectReferenceRedirect",
    "disableSolutionSearching",
    "disableReferencedProjectLoad",
    "libReplacement",
    "rewriteRelativeImportExtensions",
    "resolveJsonModule",
    "allowSyntheticDefaultImports",
    "noCheck",
    "erasableSyntaxOnly",
    "isolatedDeclarations",
    "ignoreDeprecations",
    "useDefineForClassFields",
    "keyofStringsOnly",
    "maxNodeModuleJsDepth",
    "plugins",
    "suppressExcessPropertyErrors",
    "suppressImplicitAnyIndexErrors",
    "allowUnusedLabels",
    "allowUnreachableCode",
    "ignoreConfig",
    "singleThreaded",
    "quiet",
    "pprofDir",
};

pub fn isKnownCompilerOptionName(name: []const u8) bool {
    for (known_compiler_option_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isCommandLineOnlyCompilerOptionName(name: []const u8) bool {
    const command_line_only = [_][]const u8{
        "help",
        "watch",
        "locale",
        "showConfig",
        "listFilesOnly",
        "ignoreConfig",
    };
    for (command_line_only) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Closest known compiler-option name to `option`, or null if nothing
/// is within the edit-distance threshold. Mirrors the same
/// suggestion heuristic used for `typeAcquisition` (TS5025).
fn compilerOptionSuggestion(option: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (known_compiler_option_names) |candidate| {
        const distance = levenshteinIcase(option, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    const threshold = @max(@as(usize, 2), option.len / 4);
    return if (best != null and best_distance <= threshold) best else null;
}

/// TS5108 / TS5106: options removed in TypeScript 7. Faithful port of
/// `createRemovedOptionDiagnostic` calls in upstream
/// `internal/compiler/program.go`. When `value` is non-empty the
/// message is `Option '{0}={1}' has been removed...` (TS5108); when
/// empty it is `Option '{0}' has been removed...` (TS5102). The optional
/// `use_instead` adds a TS5106 "Use '{0}' instead." companion.
fn appendRemovedOptionDiagnostics(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    cfg: TsConfig,
) !void {
    const co = cfg.compiler_options;

    // baseUrl removed; upstream suggests an equivalent `paths` mapping
    // computed from the config file's relative location. We only attach
    // the "Use ... instead" chain when we have a config path (matching
    // upstream's `configFilePath() != ""` guard); otherwise we emit the
    // removal on its own.
    if (co.base_url != null) {
        const suggestion: []const u8 = if (cfg.file_path.len > 0) "\"paths\": {\"*\": [\"./*\"]}" else "";
        try appendRemovedOption(gpa, diags, "baseUrl", "", suggestion);
    }
    // outFile is not a typed field — it rides in `extra`.
    for (co.extra.items) |entry| {
        if (std.mem.eql(u8, entry.key, "outFile")) {
            try appendRemovedOption(gpa, diags, "outFile", "", "");
        }
    }
    if (co.target) |target_value| {
        if (target_value == .es5) try appendRemovedOption(gpa, diags, "target", "ES5", "");
    }
    if (co.module) |m| {
        switch (m) {
            .amd => try appendRemovedOption(gpa, diags, "module", "AMD", ""),
            .system => try appendRemovedOption(gpa, diags, "module", "System", ""),
            .umd => try appendRemovedOption(gpa, diags, "module", "UMD", ""),
            else => {},
        }
    }
    if (co.module_resolution) |mr| {
        switch (mr) {
            .classic => try appendRemovedOption(gpa, diags, "moduleResolution", "Classic", ""),
            .node10 => try appendRemovedOption(gpa, diags, "moduleResolution", "node10", ""),
            else => {},
        }
    }
    if (co.always_strict == false) {
        try appendRemovedOption(gpa, diags, "alwaysStrict", "false", "");
    }
    if (co.es_module_interop == false) {
        try appendRemovedOption(gpa, diags, "esModuleInterop", "false", "");
    }
    if (co.allow_synthetic_default_imports == false) {
        try appendRemovedOption(gpa, diags, "allowSyntheticDefaultImports", "false", "");
    }
    // downlevelIteration: removed whenever explicitly set (any value).
    if (co.down_level_iteration != null) {
        try appendRemovedOption(gpa, diags, "downlevelIteration", "", "");
    }
}

fn appendRemovedOption(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    name: []const u8,
    value: []const u8,
    use_instead: []const u8,
) !void {
    if (value.len == 0) {
        const msg = try std.fmt.allocPrint(gpa, "Option '{s}' has been removed. Please remove it from your configuration.", .{name});
        try diags.append(gpa, .{ .code = 5102, .message = msg, .owns_message = true, .field = name });
    } else {
        const msg = try std.fmt.allocPrint(gpa, "Option '{s}={s}' has been removed. Please remove it from your configuration.", .{ name, value });
        try diags.append(gpa, .{ .code = 5108, .message = msg, .owns_message = true, .field = name });
    }
    if (use_instead.len != 0) {
        const chain = try std.fmt.allocPrint(gpa, "Use '{s}' instead.", .{use_instead});
        try diags.append(gpa, .{ .code = 5106, .message = chain, .owns_message = true, .field = name });
    }
}

/// TS5010 / TS5065: file-specification glob validation. `include`
/// patterns may not end in a recursive directory wildcard (`**`);
/// `exclude`/`files`-side specs may not contain a `..` parent-directory
/// segment that appears after a `**` wildcard. Faithful port of
/// `validateSpecs`/`specToDiagnostic` in upstream tsconfig parsing.
fn appendFileSpecDiagnostics(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    cfg: TsConfig,
) !void {
    if (cfg.include) |include| {
        for (include) |spec| {
            if (invalidTrailingRecursion(spec)) {
                const msg = try std.fmt.allocPrint(gpa, "File specification cannot end in a recursive directory wildcard ('**'): '{s}'.", .{spec});
                try diags.append(gpa, .{ .code = 5010, .message = msg, .owns_message = true, .field = "include" });
            } else if (invalidDotDotAfterRecursiveWildcard(spec)) {
                const msg = try std.fmt.allocPrint(gpa, "File specification cannot contain a parent directory ('..') that appears after a recursive directory wildcard ('**'): '{s}'.", .{spec});
                try diags.append(gpa, .{ .code = 5065, .message = msg, .owns_message = true, .field = "include" });
            }
        }
    }
    if (cfg.exclude) |exclude| {
        for (exclude) |spec| {
            if (invalidDotDotAfterRecursiveWildcard(spec)) {
                const msg = try std.fmt.allocPrint(gpa, "File specification cannot contain a parent directory ('..') that appears after a recursive directory wildcard ('**'): '{s}'.", .{spec});
                try diags.append(gpa, .{ .code = 5065, .message = msg, .owns_message = true, .field = "exclude" });
            }
        }
    }
}

/// Matches `**`, `/**`, `**/`, and `/**/`, but not `a**b`. Mirrors
/// upstream `invalidTrailingRecursion`.
fn invalidTrailingRecursion(spec: []const u8) bool {
    const s = if (spec.len > 0 and spec[spec.len - 1] == '/') spec[0 .. spec.len - 1] else spec;
    if (std.mem.eql(u8, s, "**")) return true;
    return std.mem.endsWith(u8, s, "/**");
}

/// Mirrors upstream `invalidDotDotAfterRecursiveWildcard`: true when a
/// `/../` (or trailing `/..`) segment appears after a `**/` segment.
fn invalidDotDotAfterRecursiveWildcard(s: []const u8) bool {
    var wildcard_index: ?usize = null;
    if (std.mem.startsWith(u8, s, "**/")) {
        wildcard_index = 0;
    } else {
        wildcard_index = std.mem.indexOf(u8, s, "/**/");
    }
    const wi = wildcard_index orelse return false;
    var last_dot_index: ?usize = null;
    if (std.mem.endsWith(u8, s, "/..")) {
        last_dot_index = s.len;
    } else {
        last_dot_index = std.mem.lastIndexOf(u8, s, "/../");
    }
    const ldi = last_dot_index orelse return false;
    return ldi > wi;
}

fn jsxDisallowsClassicFactory(jsx: ?Jsx) ?[]const u8 {
    return switch (jsx orelse return null) {
        .react_jsx => "react-jsx",
        .react_jsxdev => "react-jsxdev",
        else => null,
    };
}

fn appendTs5052(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    option: []const u8,
    required: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' cannot be specified without specifying option '{s}'.", .{ option, required });
    try diags.append(gpa, .{
        .code = 5052,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn appendTs5053(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    option: []const u8,
    conflicting: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' cannot be specified with option '{s}'.", .{ option, conflicting });
    try diags.append(gpa, .{
        .code = 5053,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn appendTs5051(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    option: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s} can only be used when either option '--inlineSourceMap' or option '--sourceMap' is provided.", .{option});
    try diags.append(gpa, .{
        .code = 5051,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn validatePaths(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    paths: Paths,
    has_base_url: bool,
) !void {
    for (paths.patterns, 0..) |pattern, idx| {
        if (!hasZeroOrOneAsteriskCharacter(pattern)) {
            try appendTs5061(gpa, diags, pattern);
        }

        const substitutions = paths.substitutions[idx];
        if (substitutions.len == 0) {
            try appendTs5066(gpa, diags, pattern);
        }
        for (substitutions) |subst| {
            if (!hasZeroOrOneAsteriskCharacter(subst)) {
                try appendTs5062(gpa, diags, subst, pattern);
            }
            if (!has_base_url and !pathIsRelative(subst) and !pathIsAbsolute(subst)) {
                try appendTs5090(gpa, diags);
            }
        }
    }
}

fn hasZeroOrOneAsteriskCharacter(text: []const u8) bool {
    return std.mem.count(u8, text, "*") <= 1;
}

fn pathIsRelative(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "./") or
        std.mem.startsWith(u8, path, "../") or
        std.mem.eql(u8, path, ".") or
        std.mem.eql(u8, path, "..");
}

fn pathIsAbsolute(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "\\")) return true;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) return true;
    return false;
}

fn appendTs5061(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    pattern: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Pattern '{s}' can have at most one '*' character.", .{pattern});
    try diags.append(gpa, .{
        .code = 5061,
        .message = msg,
        .owns_message = true,
        .field = "paths",
    });
}

fn appendTs5062(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    substitution: []const u8,
    pattern: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Substitution '{s}' in pattern '{s}' can have at most one '*' character.", .{ substitution, pattern });
    try diags.append(gpa, .{
        .code = 5062,
        .message = msg,
        .owns_message = true,
        .field = "paths",
    });
}

fn appendTs5066(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    pattern: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Substitutions for pattern '{s}' shouldn't be an empty array.", .{pattern});
    try diags.append(gpa, .{
        .code = 5066,
        .message = msg,
        .owns_message = true,
        .field = "paths",
    });
}

fn appendTs5090(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
) !void {
    const msg = try gpa.dupe(u8, "Non-relative paths are not allowed when 'baseUrl' is not set. Did you forget a leading './'?");
    try diags.append(gpa, .{
        .code = 5090,
        .message = msg,
        .owns_message = true,
        .field = "paths",
    });
}

fn targetAtLeastES2015(target: ?Target) bool {
    return switch (target orelse .esnext) {
        .es3, .es5 => false,
        else => true,
    };
}

fn effectiveModuleKind(co: CompilerOptions) Module {
    if (co.module) |module| {
        return module;
    }

    return switch (co.target orelse .esnext) {
        .esnext => .esnext,
        .es2022, .es2023, .es2024, .es2025 => .es2022,
        .es2020, .es2021 => .es2020,
        .es2015, .es2016, .es2017, .es2018, .es2019 => .es2015,
        .es3, .es5 => .commonjs,
    };
}

fn effectiveModuleResolution(co: CompilerOptions, module: Module) ModuleResolution {
    if (co.module_resolution) |module_resolution| {
        return module_resolution;
    }
    return switch (module) {
        .none, .amd, .umd, .system => .classic,
        .node16, .node18, .node20 => .node16,
        .nodenext => .nodenext,
        else => .bundler,
    };
}

fn moduleKindIsNode(module: Module) bool {
    return switch (module) {
        .node16, .node18, .node20, .nodenext => true,
        else => false,
    };
}

fn moduleResolutionIsNode(module_resolution: ModuleResolution) bool {
    return switch (module_resolution) {
        .node16, .nodenext => true,
        else => false,
    };
}

fn moduleResolutionSupportsPackageJsonExportsAndImports(module_resolution: ModuleResolution) bool {
    return switch (module_resolution) {
        .node16, .nodenext, .bundler => true,
        else => false,
    };
}

fn moduleKindIsNonNodeESM(module: Module) bool {
    return switch (module) {
        .es6, .es2015, .es2020, .es2022, .esnext => true,
        else => false,
    };
}

fn moduleName(module: Module) []const u8 {
    return switch (module) {
        .none => "None",
        .commonjs => "CommonJS",
        .amd => "AMD",
        .umd => "UMD",
        .system => "System",
        .es6, .es2015 => "ES2015",
        .es2020 => "ES2020",
        .es2022 => "ES2022",
        .esnext => "ESNext",
        .node16 => "Node16",
        .node18 => "Node18",
        .node20 => "Node20",
        .nodenext => "NodeNext",
        .preserve => "Preserve",
    };
}

fn moduleResolutionName(module_resolution: ModuleResolution) []const u8 {
    return switch (module_resolution) {
        .classic => "Classic",
        .node10 => "Node10",
        .node16 => "Node16",
        .nodenext => "NodeNext",
        .bundler => "Bundler",
    };
}

fn moduleResolutionNameForModule(module: Module) []const u8 {
    return switch (module) {
        .nodenext => "NodeNext",
        else => "Node16",
    };
}

fn appendTs5109(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    required_module_resolution: []const u8,
    module: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option 'moduleResolution' must be set to '{s}' (or left unspecified) when option 'module' is set to '{s}'.", .{ required_module_resolution, module });
    try diags.append(gpa, .{
        .code = 5109,
        .message = msg,
        .owns_message = true,
        .field = "moduleResolution",
    });
}

fn appendTs5095(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    option: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' can only be used when 'module' is set to 'preserve', 'commonjs', or 'es2015' or later.", .{option});
    try diags.append(gpa, .{
        .code = 5095,
        .message = msg,
        .owns_message = true,
        .field = "moduleResolution",
    });
}

fn appendTs5098(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    option: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' can only be used when 'moduleResolution' is set to 'node16', 'nodenext', or 'bundler'.", .{option});
    try diags.append(gpa, .{
        .code = 5098,
        .message = msg,
        .owns_message = true,
        .field = option,
    });
}

fn appendTs5110(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    required_module: []const u8,
    module_resolution: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option 'module' must be set to '{s}' when option 'moduleResolution' is set to '{s}'.", .{ required_module, module_resolution });
    try diags.append(gpa, .{
        .code = 5110,
        .message = msg,
        .owns_message = true,
        .field = "module",
    });
}

fn appendTs5069(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    option: []const u8,
    first_required: []const u8,
    second_required: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' cannot be specified without specifying option '{s}' or option '{s}'.", .{ option, first_required, second_required });
    try diags.append(gpa, .{
        .code = 5069,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn appendTs5089(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    option: []const u8,
    jsx_value: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' cannot be specified when option 'jsx' is '{s}'.", .{ option, jsx_value });
    try diags.append(gpa, .{
        .code = 5089,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn appendTs5091(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    enabled_option: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option 'preserveConstEnums' cannot be disabled when '{s}' is enabled.", .{enabled_option});
    try diags.append(gpa, .{
        .code = 5091,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

/// Mirrors TypeScript's `parseIsolatedEntityName` validity check for
/// JSX factory options: IdentifierName (`.` IdentifierName)*, with
/// reserved words allowed. The ASCII path is exact for the common
/// compiler-option surface; non-ASCII bytes are accepted as identifier
/// characters so this validator avoids rejecting valid Unicode names
/// until the tsconfig package grows a full TS scanner dependency.
pub fn isValidIsolatedEntityName(text: []const u8) bool {
    if (text.len == 0) return false;

    var at_segment_start = true;
    var saw_segment_char = false;
    for (text) |c| {
        if (c == '.') {
            if (at_segment_start or !saw_segment_char) return false;
            at_segment_start = true;
            saw_segment_char = false;
            continue;
        }

        const ok = if (at_segment_start)
            isEntityNameStart(c)
        else
            isEntityNameContinue(c);
        if (!ok) return false;
        at_segment_start = false;
        saw_segment_char = true;
    }

    return !at_segment_start and saw_segment_char;
}

fn isEntityNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

fn isEntityNameContinue(c: u8) bool {
    return isEntityNameStart(c) or std.ascii.isDigit(c);
}

fn appendInvalidJsxFactory(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    value: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Invalid value for 'jsxFactory'. '{s}' is not a valid identifier or qualified-name.", .{value});
    try diags.append(gpa, .{
        .code = 5067,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn appendInvalidJsxFragmentFactory(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    value: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Invalid value for 'jsxFragmentFactory'. '{s}' is not a valid identifier or qualified-name.", .{value});
    try diags.append(gpa, .{
        .code = 18035,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn appendInvalidReactNamespace(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    field: []const u8,
    value: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Invalid value for '--reactNamespace'. '{s}' is not a valid identifier.", .{value});
    try diags.append(gpa, .{
        .code = 5059,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn isEntityNameText(text: []const u8) bool {
    if (text.len == 0) return false;

    var segment_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '.') {
            if (!isIdentifierNameText(text[segment_start..i])) return false;
            segment_start = i + 1;
        }
    }
    return true;
}

fn isIdentifierNameText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!isIdentifierStartByte(text[0])) return false;
    for (text[1..]) |ch| {
        if (!isIdentifierPartByte(ch)) return false;
    }
    return true;
}

fn isIdentifierStartByte(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        ch == '_' or
        ch == '$' or
        ch >= 0x80;
}

fn isIdentifierPartByte(ch: u8) bool {
    return isIdentifierStartByte(ch) or (ch >= '0' and ch <= '9');
}

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
    defer gpa.free(doc.diagnostics);
    const json_parse_diagnostics = try arena.alloc(JsonParseDiagnostic, doc.diagnostics.len);
    for (doc.diagnostics, 0..) |diag, i| {
        json_parse_diagnostics[i] = .{
            .code = 1012,
            .pos = diag.pos,
            .line = diag.line,
            .column = diag.column,
            .message = diag.message,
        };
    }

    // TS5092: the root value parsed but is not an object. Mirror tsc's
    // `convertConfigFileToObject` recovery — for a top-level array, adopt
    // the first object element; otherwise fall back to an empty config —
    // and flag the config so `validate` emits the diagnostic.
    var root_not_object = false;
    const root: jsonc.Value.Object = doc.value.asObject() orelse blk: {
        root_not_object = true;
        if (doc.value.asArray()) |elems| {
            for (elems) |el| {
                if (el.asObject()) |o| break :blk o;
            }
        }
        break :blk jsonc.Value.Object{ .keys = &.{}, .values = &.{} };
    };

    var cfg: TsConfig = .{
        .file_path = "",
        .compiler_options = .{},
        .extends = &.{},
        .has_extends = false,
        .files = null,
        .include = null,
        .exclude = null,
        .references = &.{},
        .unknown_type_acquisition_options = &.{},
        .json_parse_diagnostics = json_parse_diagnostics,
        .root_not_object = root_not_object,
    };

    var config_diags: std.ArrayListUnmanaged(OptionParseDiagnostic) = .empty;
    try collectRootInvalidJsonValueDiagnostics(arena, root, &config_diags);

    // extends: string or [string]
    if (root.get("extends")) |ext_v| {
        cfg.has_extends = true;
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
    if (root.get("typeAcquisition")) |ta_v| {
        if (ta_v.asObject()) |ta| {
            cfg.unknown_type_acquisition_options = try collectUnknownTypeAcquisitionOptions(arena, ta);
        }
    }
    // tsc emits TS6114 for the `excludes` misspelling at the config
    // root (it means `exclude`). `get` is sufficient — the value shape
    // is irrelevant; the key's mere presence triggers the diagnostic.
    if (root.get("excludes") != null) {
        cfg.has_excludes_root_key = true;
    }
    if (root.get("compilerOptions")) |co_v| {
        if (co_v.asObject()) |co| {
            var opt_diags: std.ArrayListUnmanaged(OptionParseDiagnostic) = .empty;
            try fillCompilerOptions(arena, &cfg.compiler_options, co, &opt_diags);
            try config_diags.appendSlice(arena, opt_diags.items);
        }
    }
    cfg.option_parse_diagnostics = try config_diags.toOwnedSlice(arena);

    return cfg;
}

fn collectRootInvalidJsonValueDiagnostics(
    arena: std.mem.Allocator,
    root: jsonc.Value.Object,
    diags: *std.ArrayListUnmanaged(OptionParseDiagnostic),
) !void {
    for (root.keys, 0..) |key, i| {
        const value = root.values[i];
        if (std.mem.eql(u8, key, "compilerOptions") or
            std.mem.eql(u8, key, "extends") or
            std.mem.eql(u8, key, "files") or
            std.mem.eql(u8, key, "include") or
            std.mem.eql(u8, key, "exclude") or
            std.mem.eql(u8, key, "references"))
        {
            continue;
        }
        if (std.mem.eql(u8, key, "typeAcquisition")) {
            if (value.asObject()) |obj| {
                for (obj.keys, 0..) |ta_key, ta_i| {
                    if (!isKnownTypeAcquisitionOptionName(ta_key) and containsInvalidJsonValue(obj.values[ta_i])) {
                        try recordInvalidJsonPropertyValue(arena, diags, ta_key);
                    }
                }
            }
            continue;
        }
        if (containsInvalidJsonValue(value)) {
            try recordInvalidJsonPropertyValue(arena, diags, key);
        }
    }
}

fn containsInvalidJsonValue(value: jsonc.Value) bool {
    return switch (value) {
        .invalid => true,
        .array => |items| blk: {
            for (items) |item| {
                if (containsInvalidJsonValue(item)) break :blk true;
            }
            break :blk false;
        },
        .object => |obj| blk: {
            for (obj.values) |item| {
                if (containsInvalidJsonValue(item)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn recordInvalidJsonPropertyValue(
    arena: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(OptionParseDiagnostic),
    field: []const u8,
) !void {
    try diags.append(arena, .{
        .code = 1328,
        .option = field,
    });
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

fn collectUnknownTypeAcquisitionOptions(arena: std.mem.Allocator, obj: jsonc.Value.Object) ![][]const u8 {
    const allowed = comptime [_][]const u8{
        "enable",
        "include",
        "exclude",
        "disableFilenameBasedTypeAcquisition",
    };
    const out = try arena.alloc([]const u8, obj.keys.len);
    var n: usize = 0;
    for (obj.keys) |key| {
        var known = false;
        inline for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) {
                known = true;
                break;
            }
        }
        if (!known) {
            out[n] = key;
            n += 1;
        }
    }
    return out[0..n];
}

fn typeAcquisitionOptionSuggestion(option: []const u8) ?[]const u8 {
    const allowed = comptime [_][]const u8{
        "enable",
        "include",
        "exclude",
        "disableFilenameBasedTypeAcquisition",
    };
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    inline for (allowed) |candidate| {
        const distance = levenshteinIcase(option, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    const threshold = @max(@as(usize, 2), option.len / 4);
    return if (best != null and best_distance <= threshold) best else null;
}

fn isKnownTypeAcquisitionOptionName(option: []const u8) bool {
    const allowed = comptime [_][]const u8{
        "enable",
        "include",
        "exclude",
        "disableFilenameBasedTypeAcquisition",
    };
    inline for (allowed) |candidate| {
        if (std.mem.eql(u8, option, candidate)) return true;
    }
    return false;
}

pub fn levenshteinIcase(a: []const u8, b: []const u8) usize {
    var previous_buf: [128]usize = undefined;
    var current_buf: [128]usize = undefined;
    if (b.len + 1 > previous_buf.len) return std.math.maxInt(usize);
    for (0..b.len + 1) |i| previous_buf[i] = i;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        current_buf[0] = i + 1;
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            const ca = std.ascii.toLower(a[i]);
            const cb = std.ascii.toLower(b[j]);
            const cost: usize = if (ca == cb) 0 else 1;
            const del = previous_buf[j + 1] + 1;
            const ins = current_buf[j] + 1;
            const sub = previous_buf[j] + cost;
            current_buf[j + 1] = @min(@min(del, ins), sub);
        }
        @memcpy(previous_buf[0 .. b.len + 1], current_buf[0 .. b.len + 1]);
    }
    return previous_buf[b.len];
}

fn recordOptionTypeMismatch(
    arena: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(OptionParseDiagnostic),
    option: []const u8,
    expected_type: []const u8,
) !void {
    try diags.append(arena, .{
        .code = 5024,
        .option = option,
        .expected_type = expected_type,
    });
}

fn recordCommandLineOnlyOption(
    arena: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(OptionParseDiagnostic),
    option: []const u8,
) !void {
    try diags.append(arena, .{
        .code = 6266,
        .option = option,
    });
}

fn recordInvalidEnumOption(
    arena: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(OptionParseDiagnostic),
    option: []const u8,
) !void {
    try diags.append(arena, .{
        .code = 6046,
        .option = option,
        .expected_type = enumOptionAllowedValues(option) orelse "",
    });
}

/// JS `typeof` of a JSON value, used for TS5064's `{2}` placeholder.
fn jsonValueTypeName(v: jsonc.Value) []const u8 {
    return switch (v) {
        .null_ => "object", // matches JS `typeof null === "object"`
        .bool_ => "boolean",
        .number => "number",
        .string => "string",
        .array => "object",
        .object => "object",
        .invalid => "undefined",
    };
}

/// Render a JSON value for TS5064's `{0}` placeholder. Mirrors how the
/// original TS compiler coerces the substitution value into the message
/// (it interpolates the raw JS value). The result is arena-owned.
fn jsonValueDisplay(arena: std.mem.Allocator, v: jsonc.Value) ![]const u8 {
    return switch (v) {
        .null_ => "null",
        .bool_ => |b| if (b) "true" else "false",
        .string => |s| s,
        .number => |n| blk: {
            // Render integers without a trailing `.0`, matching JS's
            // `String(n)` for whole numbers.
            if (n == @floor(n) and std.math.isFinite(n)) {
                break :blk try std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
            }
            break :blk try std.fmt.allocPrint(arena, "{d}", .{n});
        },
        .array => "[object Array]",
        .object => "[object Object]",
        .invalid => "undefined",
    };
}

fn fillCompilerOptions(
    arena: std.mem.Allocator,
    co: *CompilerOptions,
    obj: jsonc.Value.Object,
    diags: *std.ArrayListUnmanaged(OptionParseDiagnostic),
) !void {
    var i: usize = 0;
    while (i < obj.keys.len) : (i += 1) {
        const key = obj.keys[i];
        const value = obj.values[i];

        if (isCommandLineOnlyCompilerOptionName(key)) {
            try recordCommandLineOnlyOption(arena, diags, key);
            continue;
        }

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
            .{ .name = "erasableSyntaxOnly", .field = "erasable_syntax_only" },
            .{ .name = "skipLibCheck", .field = "skip_lib_check" },
            .{ .name = "skipDefaultLibCheck", .field = "skip_default_lib_check" },
            .{ .name = "forceConsistentCasingInFileNames", .field = "force_consistent_casing_in_file_names" },
            .{ .name = "traceResolution", .field = "trace_resolution" },
            .{ .name = "keyofStringsOnly", .field = "keyof_strings_only" },
            .{ .name = "suppressExcessPropertyErrors", .field = "suppress_excess_property_errors" },
            .{ .name = "suppressImplicitAnyIndexErrors", .field = "suppress_implicit_any_index_errors" },
            .{ .name = "allowSyntheticDefaultImports", .field = "allow_synthetic_default_imports" },
            .{ .name = "useDefineForClassFields", .field = "use_define_for_class_fields" },
            .{ .name = "resolveJsonModule", .field = "resolve_json_module" },
            .{ .name = "resolvePackageJsonExports", .field = "resolve_package_json_exports" },
            .{ .name = "resolvePackageJsonImports", .field = "resolve_package_json_imports" },
            .{ .name = "allowImportingTsExtensions", .field = "allow_importing_ts_extensions" },
            .{ .name = "rewriteRelativeImportExtensions", .field = "rewrite_relative_import_extensions" },
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
                if (value.asBool()) |b| {
                    @field(co, entry.field) = b;
                } else {
                    try recordOptionTypeMismatch(arena, diags, entry.name, "boolean");
                }
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
            .{ .name = "mapRoot", .field = "map_root" },
            .{ .name = "sourceRoot", .field = "source_root" },
            .{ .name = "jsxFactory", .field = "jsx_factory" },
            .{ .name = "jsxFragmentFactory", .field = "jsx_fragment_factory" },
            .{ .name = "jsxImportSource", .field = "jsx_import_source" },
            .{ .name = "reactNamespace", .field = "react_namespace" },
            .{ .name = "moduleDetection", .field = "module_detection" },
            .{ .name = "ignoreDeprecations", .field = "ignore_deprecations" },
        };
        inline for (str_table) |entry| {
            if (std.mem.eql(u8, key, entry.name)) {
                if (value.asString()) |s| {
                    @field(co, entry.field) = s;
                } else {
                    try recordOptionTypeMismatch(arena, diags, entry.name, "string");
                }
                matched = true;
            }
        }
        if (matched) continue;

        // String arrays. A non-array value is a value-type mismatch
        // (expected Array) per tsc's `list`/`listOrElement` handling.
        const ListField = struct { name: []const u8, field: []const u8 };
        const list_table = comptime [_]ListField{
            .{ .name = "lib", .field = "lib" },
            .{ .name = "rootDirs", .field = "root_dirs" },
            .{ .name = "typeRoots", .field = "type_roots" },
            .{ .name = "types", .field = "types" },
            .{ .name = "customConditions", .field = "custom_conditions" },
        };
        inline for (list_table) |entry| {
            if (std.mem.eql(u8, key, entry.name)) {
                if (value.asArray() != null) {
                    @field(co, entry.field) = try parseStringArray(arena, value);
                } else {
                    try recordOptionTypeMismatch(arena, diags, entry.name, "Array");
                }
                matched = true;
            }
        }
        if (matched) continue;

        // Enum-typed. A non-string value is a value-type mismatch
        // (TS5024); an unrecognized string value is an enum-argument
        // error (TS6046). In both cases keep parsing, mirroring tsc's
        // recovery.
        if (std.mem.eql(u8, key, "module")) {
            if (value.asString()) |s| {
                co.module = Module.fromString(s) orelse {
                    try recordInvalidEnumOption(arena, diags, "module");
                    continue;
                };
            } else {
                try recordOptionTypeMismatch(arena, diags, "module", "string");
            }
            continue;
        }
        if (std.mem.eql(u8, key, "moduleResolution")) {
            if (value.asString()) |s| {
                co.module_resolution = ModuleResolution.fromString(s) orelse {
                    try recordInvalidEnumOption(arena, diags, "moduleResolution");
                    continue;
                };
            } else {
                try recordOptionTypeMismatch(arena, diags, "moduleResolution", "string");
            }
            continue;
        }
        if (std.mem.eql(u8, key, "target")) {
            if (value.asString()) |s| {
                co.target = Target.fromString(s) orelse {
                    try recordInvalidEnumOption(arena, diags, "target");
                    continue;
                };
            } else {
                try recordOptionTypeMismatch(arena, diags, "target", "string");
            }
            continue;
        }
        if (std.mem.eql(u8, key, "jsx")) {
            if (value.asString()) |s| {
                co.jsx = Jsx.fromString(s) orelse {
                    try recordInvalidEnumOption(arena, diags, "jsx");
                    continue;
                };
            } else {
                try recordOptionTypeMismatch(arena, diags, "jsx", "string");
            }
            continue;
        }

        // `paths`.
        if (std.mem.eql(u8, key, "paths")) {
            const obj_v = value.asObject() orelse {
                // `paths` itself must be an object (`object` kind in tsc).
                try recordOptionTypeMismatch(arena, diags, "paths", "object");
                continue;
            };
            const npats = obj_v.keys.len;
            const patterns = try arena.alloc([]const u8, npats);
            const substitutions = try arena.alloc([]const []const u8, npats);
            for (obj_v.keys, 0..) |pk, idx| {
                patterns[idx] = pk;
                // Each pattern maps to a string array. A non-array value
                // is a value-type mismatch for that entry (Array); a
                // non-string element is TS5064.
                const arr = obj_v.values[idx].asArray() orelse {
                    patterns[idx] = pk;
                    substitutions[idx] = &.{};
                    // TS5063 — `Substitutions for pattern '{0}' should
                    // be an array.` Specific to `paths` per-pattern
                    // value validation; mirrors tsc's narrower error.
                    // The renderer at the validation pass converts the
                    // OptionParseDiagnostic to its final wording.
                    try diags.append(arena, .{
                        .code = 5063,
                        .option = "paths",
                        .pattern = pk,
                    });
                    continue;
                };
                const subs_buf = try arena.alloc([]const u8, arr.len);
                var n: usize = 0;
                for (arr) |s| {
                    if (s.asString()) |str| {
                        subs_buf[n] = str;
                        n += 1;
                    } else {
                        try diags.append(arena, .{
                            .code = 5064,
                            .option = "",
                            .substitution = try jsonValueDisplay(arena, s),
                            .pattern = pk,
                            .got_type = jsonValueTypeName(s),
                        });
                    }
                }
                substitutions[idx] = subs_buf[0..n];
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
    const co_info = @typeInfo(CompilerOptions).@"struct".field_names;
    inline for (co_info) |fname| {
        if (comptime std.mem.eql(u8, fname, "extra")) continue;
        const child_v = @field(child.compiler_options, fname);
        if (child_v != null) {
            @field(merged.compiler_options, fname) = child_v;
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
    if (child.unknown_type_acquisition_options.len > 0) {
        merged.unknown_type_acquisition_options = child.unknown_type_acquisition_options;
    }
    merged.has_extends = base.has_extends or child.has_extends;
    merged.has_excludes_root_key = base.has_excludes_root_key or child.has_excludes_root_key;
    return merged;
}

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

/// Count how many validation diagnostics carry `code`. Used by tests
/// whose fixtures unavoidably also trip a TS7 removed-option diagnostic
/// (e.g. `target: es5`, `moduleResolution: classic`) so the assertion
/// can stay focused on the code under test.
fn countCode(diags: []const ValidationDiagnostic, code: u32) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    return n;
}

/// First diagnostic carrying `code`, or null.
fn findCode(diags: []const ValidationDiagnostic, code: u32) ?ValidationDiagnostic {
    for (diags) |d| {
        if (d.code == code) return d;
    }
    return null;
}

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
        \\{ "compilerOptions": { "module": "node20", "moduleResolution": "bundler", "target": "ES2022" } }
    );
    try t.expectEqual(@as(?Module, .node20), cfg.compiler_options.module);
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

test "tsconfig: JSX factory entity-name validation" {
    try t.expect(isValidIsolatedEntityName("h"));
    try t.expect(isValidIsolatedEntityName("React.createElement"));
    try t.expect(isValidIsolatedEntityName("null"));

    try t.expect(!isValidIsolatedEntityName("234"));
    try t.expect(!isValidIsolatedEntityName("Element.createElement="));
    try t.expect(!isValidIsolatedEntityName("id1 id2"));
    try t.expect(!isValidIsolatedEntityName("React."));
    try t.expect(!isValidIsolatedEntityName(".Fragment"));
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

test "tsconfig: root file-management options carry TS6245 category" {
    try t.expectEqual(@as(?u32, 6245), rootOptionCategoryCode("extends"));
    try t.expectEqual(@as(?u32, 6245), rootOptionCategoryCode("files"));
    try t.expectEqual(@as(?u32, 6245), rootOptionCategoryCode("include"));
    try t.expectEqual(@as(?u32, 6245), rootOptionCategoryCode("exclude"));
    try t.expectEqual(@as(?u32, null), rootOptionCategoryCode("compilerOptions"));
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

test "tsconfig: traceResolution boolean" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "traceResolution": true } }
    );
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.trace_resolution);
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

test "tsconfig: invalid module enum value is dropped without aborting parse" {
    // An unrecognized enum *string* is TS6046. tsc reports it but keeps
    // parsing the rest of the config; the option is left unset. (A
    // non-string value, by contrast, is a TS5024 value-type mismatch.)
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "atomic-fission", "strict": true } }
    );
    try t.expectEqual(@as(?Module, null), cfg.compiler_options.module);
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.strict);
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 6046));
    const d = findCode(diags, 6046).?;
    try t.expectEqualStrings("Argument for '--module' option must be: 'commonjs', 'es6', 'es2015', 'es2020', 'es2022', 'esnext', 'node16', 'node18', 'node20', 'nodenext', 'preserve'.", d.message);
    try t.expectEqualStrings("module", d.field);
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
        \\{ "compilerOptions": { "moduleDetection": "force", "ignoreDeprecations": "5.0" } }
    );
    try t.expectEqualStrings("force", cfg.compiler_options.module_detection.?);
    try t.expectEqualStrings("5.0", cfg.compiler_options.ignore_deprecations.?);
}

test "tsconfig: JSX factory string fields parse" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "jsxFactory": "h",
        \\    "jsxFragmentFactory": "Fragment",
        \\    "jsxImportSource": "preact",
        \\    "reactNamespace": "Preact"
        \\  }
        \\}
    );
    const co = cfg.compiler_options;
    try t.expectEqualStrings("h", co.jsx_factory.?);
    try t.expectEqualStrings("Fragment", co.jsx_fragment_factory.?);
    try t.expectEqualStrings("preact", co.jsx_import_source.?);
    try t.expectEqualStrings("Preact", co.react_namespace.?);
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

test "tsconfig.validate: clean config produces no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": true, "outDir": "dist", "rootDir": "src" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: outDir == rootDir reports TS5009-shaped diagnostic" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "outDir": "build", "rootDir": "build" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5009), diags[0].code);
    try t.expectEqualStrings("outDir", diags[0].field);
}

test "tsconfig.validate: non-object root reports TS5092" {
    // tsc's convertConfigFileToObject: a JSON root that is present but not
    // an object literal → TS5092, recover with an empty config.
    const cases = [_][]const u8{
        \\[]
        ,
        \\"a string"
        ,
        \\42
        ,
        \\true
        ,
        \\null
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const cfg = try parseString(t.allocator, arena.allocator(), src);
        try t.expect(cfg.root_not_object);
        const diags = try cfg.validate(t.allocator);
        defer freeValidationDiagnostics(t.allocator, diags);
        try t.expectEqual(@as(usize, 1), diags.len);
        try t.expectEqual(@as(u32, 5092), diags[0].code);
        try t.expectEqualStrings(
            "The root value of a 'tsconfig.json' file must be an object.",
            diags[0].message,
        );
    }
}

test "tsconfig.validate: jsconfig.json non-object root names jsconfig in TS5092" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var cfg = try parseString(t.allocator, arena.allocator(),
        \\[]
    );
    cfg.file_path = "/proj/jsconfig.json";
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(u32, 5092), diags[0].code);
    try t.expectEqualStrings(
        "The root value of a 'jsconfig.json' file must be an object.",
        diags[0].message,
    );
}

test "tsconfig.validate: top-level array recovers first object element (still TS5092)" {
    // tsc recovers a config object from `[ {…} ]` (stray brackets) but
    // still reports TS5092.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\[ { "compilerOptions": { "strict": true } } ]
    );
    try t.expect(cfg.root_not_object);
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.strict);
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5092));
}

test "tsconfig.validate: object root does not report TS5092" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": true } }
    );
    try t.expect(!cfg.root_not_object);
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), countCode(diags, 5092));
}

test "tsconfig.validate: trailing top-level JSON reports TS1012 and recovers config" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": true } } {}
    );
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.strict);
    try t.expectEqual(@as(usize, 1), cfg.json_parse_diagnostics.len);
    try t.expectEqual(@as(u32, 1012), cfg.json_parse_diagnostics[0].code);
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    const d = findCode(diags, 1012) orelse return error.TestExpectedDiagnostic;
    try t.expectEqualStrings("Unexpected token.", d.message);
}

test "tsconfig.validate: composite without declaration reports TS6304-shaped diagnostic" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "composite": true, "declaration": false } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 6304), diags[0].code);
    try t.expectEqualStrings("declaration", diags[0].field);
}

test "tsconfig.validate: composite with incremental:false reports TS6379" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "composite": true, "incremental": false } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    const d = findCode(diags, 6379) orelse return error.TestExpectedDiagnostic;
    try t.expectEqualStrings("Composite projects may not disable incremental compilation.", d.message);
    try t.expectEqualStrings("declaration", d.field);
}

test "tsconfig.validate: composite with incremental:true does not report TS6379" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "composite": true, "incremental": true, "declaration": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), countCode(diags, 6379));
}

test "tsconfig.validate: composite without incremental does not report TS6379" {
    // composite implies incremental unless it is *explicitly* false.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "composite": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), countCode(diags, 6379));
}

test "tsconfig.validate: composite with both declaration:false and incremental:false reports TS6304 and TS6379" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "composite": true, "declaration": false, "incremental": false } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 6304));
    try t.expectEqual(@as(usize, 1), countCode(diags, 6379));
}

test "tsconfig.validate: root 'excludes' key reports TS6114" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "excludes": ["dist"] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    const d = findCode(diags, 6114) orelse return error.TestExpectedDiagnostic;
    try t.expectEqualStrings("Unknown option 'excludes'. Did you mean 'exclude'?", d.message);
    try t.expectEqualStrings("excludes", d.field);
}

test "tsconfig.validate: correct 'exclude' key does not report TS6114" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "exclude": ["dist"] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), countCode(diags, 6114));
}

test "tsconfig: merge propagates root 'excludes' key from child for TS6114" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const base = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": true } }
    );
    const child = try parseString(t.allocator, arena.allocator(),
        \\{ "excludes": ["dist"] }
    );
    const merged = try merge(arena.allocator(), base, child);
    const diags = try merged.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 6114));
}

test "tsconfig.validate: empty extends string reports TS18051" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "extends": "" }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 18051), diags[0].code);
    try t.expectEqualStrings("Compiler option 'extends' cannot be given an empty string.", diags[0].message);
    try t.expectEqualStrings("extends", diags[0].field);
}

test "tsconfig.validate: empty extends array elements each report TS18051" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "extends": ["./base.json", "", ""] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), diags.len);
    try t.expectEqual(@as(u32, 18051), diags[0].code);
    try t.expectEqual(@as(u32, 18051), diags[1].code);
}

test "tsconfig.validate: empty files list without references or extends reports TS18002" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "files": [] }
    );
    cfg.file_path = "/apath/tsconfig.json";
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 18002), diags[0].code);
    try t.expectEqualStrings("The 'files' list in config file '/apath/tsconfig.json' is empty.", diags[0].message);
    try t.expectEqualStrings("files", diags[0].field);
}

test "tsconfig.validate: empty files list is allowed with references or extends" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const with_references = try parseString(t.allocator, arena.allocator(),
        \\{ "files": [], "references": [{ "path": "/apath" }] }
    );
    const ref_diags = try with_references.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, ref_diags);
    try t.expectEqual(@as(usize, 0), ref_diags.len);

    const with_extends = try parseString(t.allocator, arena.allocator(),
        \\{ "extends": [], "files": [] }
    );
    const ext_diags = try with_extends.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, ext_diags);
    try t.expectEqual(@as(usize, 0), ext_diags.len);
}

test "tsconfig.validate: unknown typeAcquisition keys report TS17010" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "typeAcquisition": {
        \\    "enableAutoDiscovy": true,
        \\    "enable": true,
        \\    "include": ["jquery"],
        \\    "exclude": ["node"],
        \\    "disableFilenameBasedTypeAcquisition": false
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 17010), diags[0].code);
    try t.expectEqualStrings("Unknown type acquisition option 'enableAutoDiscovy'.", diags[0].message);
    try t.expectEqualStrings("typeAcquisition", diags[0].field);
}

test "tsconfig.validate: misspelled typeAcquisition keys report TS17018 suggestion" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "typeAcquisition": {
        \\    "includes": ["jquery"],
        \\    "disableFilenameBasedTypeAquisition": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), diags.len);
    try t.expectEqual(@as(u32, 17018), diags[0].code);
    try t.expectEqualStrings("Unknown type acquisition option 'includes'. Did you mean 'include'?", diags[0].message);
    try t.expectEqual(@as(u32, 17018), diags[1].code);
    try t.expectEqualStrings("Unknown type acquisition option 'disableFilenameBasedTypeAquisition'. Did you mean 'disableFilenameBasedTypeAcquisition'?", diags[1].message);
}

test "tsconfig.validate: known typeAcquisition keys are accepted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "typeAcquisition": {
        \\    "enable": false,
        \\    "include": ["lodash"],
        \\    "exclude": ["mocha"],
        \\    "disableFilenameBasedTypeAcquisition": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: dependent options report TS5052" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "checkJs": true,
        \\    "emitDecoratorMetadata": true,
        \\    "exactOptionalPropertyTypes": true,
        \\    "strictPropertyInitialization": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 4), diags.len);
    try t.expectEqual(@as(u32, 5052), diags[0].code);
    try t.expectEqualStrings("Option 'strictPropertyInitialization' cannot be specified without specifying option 'strictNullChecks'.", diags[0].message);
    try t.expectEqual(@as(u32, 5052), diags[1].code);
    try t.expectEqualStrings("Option 'exactOptionalPropertyTypes' cannot be specified without specifying option 'strictNullChecks'.", diags[1].message);
    try t.expectEqual(@as(u32, 5052), diags[2].code);
    try t.expectEqualStrings("Option 'checkJs' cannot be specified without specifying option 'allowJs'.", diags[2].message);
    try t.expectEqual(@as(u32, 5052), diags[3].code);
    try t.expectEqualStrings("Option 'emitDecoratorMetadata' cannot be specified without specifying option 'experimentalDecorators'.", diags[3].message);
}

test "tsconfig.validate: dependent options accept required pairs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "allowJs": true,
        \\    "checkJs": true,
        \\    "experimentalDecorators": true,
        \\    "emitDecoratorMetadata": true,
        \\    "strict": true,
        \\    "exactOptionalPropertyTypes": true,
        \\    "strictPropertyInitialization": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: mutually exclusive options report TS5053" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "sourceMap": true,
        \\    "inlineSourceMap": true,
        \\    "allowJs": true,
        \\    "isolatedDeclarations": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 5053), diags[0].code);
    try t.expectEqualStrings("Option 'sourceMap' cannot be specified with option 'inlineSourceMap'.", diags[0].message);
    try t.expectEqual(@as(u32, 5053), diags[1].code);
    try t.expectEqualStrings("Option 'allowJs' cannot be specified with option 'isolatedDeclarations'.", diags[1].message);
    try t.expectEqual(@as(u32, 5069), diags[2].code);
    try t.expectEqualStrings("Option 'isolatedDeclarations' cannot be specified without specifying option 'declaration' or option 'composite'.", diags[2].message);
}

test "tsconfig.validate: paths reports TS5061 TS5062 TS5066 and TS5090" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "paths": {
        \\      "bad**": [],
        \\      "ok/*": ["src/*", "./rel/*", "/abs/*", "bad/**/x"]
        \\    }
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 5), diags.len);
    try t.expectEqual(@as(u32, 5061), diags[0].code);
    try t.expectEqualStrings("Pattern 'bad**' can have at most one '*' character.", diags[0].message);
    try t.expectEqual(@as(u32, 5066), diags[1].code);
    try t.expectEqualStrings("Substitutions for pattern 'bad**' shouldn't be an empty array.", diags[1].message);
    try t.expectEqual(@as(u32, 5090), diags[2].code);
    try t.expectEqualStrings("Non-relative paths are not allowed when 'baseUrl' is not set. Did you forget a leading './'?", diags[2].message);
    try t.expectEqual(@as(u32, 5062), diags[3].code);
    try t.expectEqualStrings("Substitution 'bad/**/x' in pattern 'ok/*' can have at most one '*' character.", diags[3].message);
    try t.expectEqual(@as(u32, 5090), diags[4].code);
    try t.expectEqualStrings("paths", diags[4].field);
}

test "tsconfig.validate: paths accepts non-relative substitutions when baseUrl is set" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "baseUrl": ".",
        \\    "paths": {
        \\      "@/*": ["src/*", "vendor/*"]
        \\    }
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    // No paths-specific diagnostics should fire. (`baseUrl` itself is a
    // removed option in TS7 and now emits TS5102; that is unrelated to
    // the paths validation under test.)
    try t.expectEqual(@as(usize, 0), countCode(diags, 5061));
    try t.expectEqual(@as(usize, 0), countCode(diags, 5062));
    try t.expectEqual(@as(usize, 0), countCode(diags, 5064));
    try t.expectEqual(@as(usize, 0), countCode(diags, 5066));
    try t.expectEqual(@as(usize, 0), countCode(diags, 5090));
    try t.expectEqual(@as(usize, 1), countCode(diags, 5102));
}

test "tsconfig.validate: ignoreDeprecations reports TS5103 for unsupported values" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "ignoreDeprecations": "5.1" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5103), diags[0].code);
    try t.expectEqualStrings("ignoreDeprecations", diags[0].field);
    try t.expectEqualStrings("Invalid value for '--ignoreDeprecations'.", diags[0].message);
}

test "tsconfig.validate: ignoreDeprecations accepts supported values" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const current = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "ignoreDeprecations": "5.0" } }
    );
    const current_diags = try current.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, current_diags);
    try t.expectEqual(@as(usize, 0), current_diags.len);
    try t.expectEqualStrings("5.0", current.compiler_options.ignore_deprecations.?);

    const next = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "ignoreDeprecations": "6.0" } }
    );
    const next_diags = try next.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, next_diags);
    try t.expectEqual(@as(usize, 0), next_diags.len);
    try t.expectEqualStrings("6.0", next.compiler_options.ignore_deprecations.?);
}

test "tsconfig.validate: isolatedModules reports TS5047 for module none below ES2015" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // `target: es5` is the only sub-ES2015 target and is itself a
    // removed option in TS7, so the config now also emits TS5102; the
    // assertion focuses on the TS5047 diagnostic under test.
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "isolatedModules": true, "module": "none", "target": "es5" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5047));
    const d = findCode(diags, 5047).?;
    try t.expectEqualStrings("isolatedModules", d.field);
    try t.expectEqualStrings("Option 'isolatedModules' can only be used when either option '--module' is provided or option 'target' is 'ES2015' or higher.", d.message);
    // Confirms the removed-option diagnostic for `target: ES5` rides
    // along (TS5108 value form).
    try t.expectEqual(@as(usize, 1), countCode(diags, 5108));
}

test "tsconfig.validate: isolatedModules accepts module none at ES2015" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "isolatedModules": true, "module": "none", "target": "es2015" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: node module kinds report TS5109 for incompatible moduleResolution" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // `classic` is non-node (so TS5109 fires) but is a removed option in
    // TS7, so the config also emits TS5102; the assertion stays focused
    // on the TS5109 diagnostic under test.
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "node20", "moduleResolution": "classic" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5109));
    const d = findCode(diags, 5109).?;
    try t.expectEqualStrings("moduleResolution", d.field);
    try t.expectEqualStrings("Option 'moduleResolution' must be set to 'Node16' (or left unspecified) when option 'module' is set to 'Node20'.", d.message);
    // `moduleResolution: classic` is a removed option → TS5108 value form.
    try t.expectEqual(@as(usize, 1), countCode(diags, 5108));
}

test "tsconfig.validate: bundler moduleResolution reports TS5095 for incompatible module" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // `none` is incompatible with bundler resolution but, unlike
    // `system`/`amd`/`umd`, is not a removed option — so the assertion
    // stays focused on TS5095.
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "none", "moduleResolution": "bundler" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5095), diags[0].code);
    try t.expectEqualStrings("moduleResolution", diags[0].field);
    try t.expectEqualStrings("Option 'bundler' can only be used when 'module' is set to 'preserve', 'commonjs', or 'es2015' or later.", diags[0].message);
}

test "tsconfig.validate: package-json condition options report TS5098 outside modern resolution" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "moduleResolution": "classic",
        \\    "resolvePackageJsonExports": true,
        \\    "resolvePackageJsonImports": true,
        \\    "customConditions": ["home"]
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    // `moduleResolution: classic` is required to take this branch but is
    // itself a removed option in TS7, so the config also emits TS5108
    // (the `{0}={1}` value form).
    try t.expectEqual(@as(usize, 3), countCode(diags, 5098));
    try t.expectEqual(@as(usize, 1), countCode(diags, 5108));
    var saw_exports = false;
    var saw_imports = false;
    var saw_conditions = false;
    for (diags) |d| {
        if (d.code != 5098) continue;
        if (std.mem.indexOf(u8, d.message, "resolvePackageJsonExports") != null) saw_exports = true;
        if (std.mem.indexOf(u8, d.message, "resolvePackageJsonImports") != null) saw_imports = true;
        if (std.mem.indexOf(u8, d.message, "customConditions") != null) saw_conditions = true;
    }
    try t.expect(saw_exports and saw_imports and saw_conditions);
}

test "tsconfig.validate: allowImportingTsExtensions reports TS5096 without no-emit mode" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "allowImportingTsExtensions": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5096), diags[0].code);
    try t.expectEqualStrings("allowImportingTsExtensions", diags[0].field);
    try t.expectEqualStrings("Option 'allowImportingTsExtensions' can only be used when one of 'noEmit', 'emitDeclarationOnly', or 'rewriteRelativeImportExtensions' is set.", diags[0].message);
}

test "tsconfig.validate: package-json and TS extension options accept supported modes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "moduleResolution": "bundler",
        \\    "resolvePackageJsonExports": true,
        \\    "resolvePackageJsonImports": true,
        \\    "customConditions": ["home"],
        \\    "allowImportingTsExtensions": true,
        \\    "rewriteRelativeImportExtensions": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
    try t.expectEqualStrings("home", cfg.compiler_options.custom_conditions.?[0]);
}

test "tsconfig.validate: node moduleResolution reports TS5110 for incompatible module" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "esnext", "moduleResolution": "node16" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5110), diags[0].code);
    try t.expectEqualStrings("module", diags[0].field);
    try t.expectEqualStrings("Option 'module' must be set to 'Node16' when option 'moduleResolution' is set to 'Node16'.", diags[0].message);
}

test "tsconfig.validate: node module and moduleResolution compatible pairs pass" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const implicit_resolution = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "node16" } }
    );
    const implicit_diags = try implicit_resolution.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, implicit_diags);
    try t.expectEqual(@as(usize, 0), implicit_diags.len);

    const cross_node_pair = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "nodenext", "moduleResolution": "node16" } }
    );
    const cross_node_diags = try cross_node_pair.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, cross_node_diags);
    try t.expectEqual(@as(usize, 0), cross_node_diags.len);
}

test "tsconfig.validate: source map companion options report TS5051" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "inlineSources": true,
        \\    "sourceRoot": "local"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), diags.len);
    try t.expectEqual(@as(u32, 5051), diags[0].code);
    try t.expectEqualStrings("Option 'inlineSources can only be used when either option '--inlineSourceMap' or option '--sourceMap' is provided.", diags[0].message);
    try t.expectEqualStrings("inlineSources", diags[0].field);
    try t.expectEqual(@as(u32, 5051), diags[1].code);
    try t.expectEqualStrings("Option 'sourceRoot can only be used when either option '--inlineSourceMap' or option '--sourceMap' is provided.", diags[1].message);
    try t.expectEqualStrings("sourceRoot", diags[1].field);
}

test "tsconfig.validate: source map companion options accept sourceMap or inlineSourceMap" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const with_source_map = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "sourceMap": true,
        \\    "inlineSources": true,
        \\    "sourceRoot": "local"
        \\  }
        \\}
    );
    const source_map_diags = try with_source_map.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, source_map_diags);
    try t.expectEqual(@as(usize, 0), source_map_diags.len);

    const with_inline_source_map = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "inlineSourceMap": true,
        \\    "inlineSources": true,
        \\    "sourceRoot": "local"
        \\  }
        \\}
    );
    const inline_source_map_diags = try with_inline_source_map.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, inline_source_map_diags);
    try t.expectEqual(@as(usize, 0), inline_source_map_diags.len);
}

test "tsconfig.validate: preserveConstEnums reports TS5091 under isolated emit modes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "isolatedModules": true,
        \\    "verbatimModuleSyntax": true,
        \\    "preserveConstEnums": false
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5091), diags[0].code);
    try t.expectEqualStrings("preserveConstEnums", diags[0].field);
    try t.expectEqualStrings("Option 'preserveConstEnums' cannot be disabled when 'verbatimModuleSyntax' is enabled.", diags[0].message);
}

test "tsconfig.validate: preserveConstEnums false reports isolatedModules when verbatim is off" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "isolatedModules": true,
        \\    "preserveConstEnums": false
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5091), diags[0].code);
    try t.expectEqualStrings("Option 'preserveConstEnums' cannot be disabled when 'isolatedModules' is enabled.", diags[0].message);
}

test "tsconfig.validate: preserveConstEnums accepts isolated modes when true or unset" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const explicit_true = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "isolatedModules": true, "preserveConstEnums": true } }
    );
    const explicit_true_diags = try explicit_true.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, explicit_true_diags);
    try t.expectEqual(@as(usize, 0), explicit_true_diags.len);

    const unset = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "verbatimModuleSyntax": true } }
    );
    const unset_diags = try unset.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, unset_diags);
    try t.expectEqual(@as(usize, 0), unset_diags.len);
}

test "tsconfig.validate: declaration-dependent options report TS5069" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "declarationDir": "types",
        \\    "declarationMap": true,
        \\    "emitDeclarationOnly": true,
        \\    "isolatedDeclarations": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 4), diags.len);
    try t.expectEqual(@as(u32, 5069), diags[0].code);
    try t.expectEqualStrings("Option 'isolatedDeclarations' cannot be specified without specifying option 'declaration' or option 'composite'.", diags[0].message);
    try t.expectEqual(@as(u32, 5069), diags[1].code);
    try t.expectEqualStrings("Option 'declarationDir' cannot be specified without specifying option 'declaration' or option 'composite'.", diags[1].message);
    try t.expectEqual(@as(u32, 5069), diags[2].code);
    try t.expectEqualStrings("Option 'declarationMap' cannot be specified without specifying option 'declaration' or option 'composite'.", diags[2].message);
    try t.expectEqual(@as(u32, 5069), diags[3].code);
    try t.expectEqualStrings("Option 'emitDeclarationOnly' cannot be specified without specifying option 'declaration' or option 'composite'.", diags[3].message);
}

test "tsconfig.validate: mapRoot reports TS5069 without sourceMap or declarationMap" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "mapRoot": "maps" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5069), diags[0].code);
    try t.expectEqualStrings("Option 'mapRoot' cannot be specified without specifying option 'sourceMap' or option 'declarationMap'.", diags[0].message);
}

test "tsconfig.validate: declaration-dependent options accept declaration or composite" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const with_declaration = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "declaration": true,
        \\    "declarationDir": "types",
        \\    "declarationMap": true,
        \\    "emitDeclarationOnly": true,
        \\    "isolatedDeclarations": true,
        \\    "mapRoot": "maps"
        \\  }
        \\}
    );
    const declaration_diags = try with_declaration.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, declaration_diags);
    try t.expectEqual(@as(usize, 0), declaration_diags.len);

    const with_composite = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "composite": true,
        \\    "declarationDir": "types",
        \\    "declarationMap": true,
        \\    "emitDeclarationOnly": true,
        \\    "isolatedDeclarations": true,
        \\    "mapRoot": "maps",
        \\    "sourceMap": true
        \\  }
        \\}
    );
    const composite_diags = try with_composite.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, composite_diags);
    try t.expectEqual(@as(usize, 0), composite_diags.len);
}

test "tsconfig.validate: JSX factory cluster accepts classic React values" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "jsx": "react",
        \\    "jsxFactory": "h.create",
        \\    "jsxFragmentFactory": "null"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: jsxFragmentFactory without jsxFactory reports TS5052" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "jsxFragmentFactory": "Fragment" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5052), diags[0].code);
    try t.expectEqualStrings("Option 'jsxFragmentFactory' cannot be specified without specifying option 'jsxFactory'.", diags[0].message);
    try t.expectEqualStrings("jsxFragmentFactory", diags[0].field);
}

test "tsconfig.validate: automatic JSX runtime rejects classic factory options with TS5089" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "jsx": "react-jsx",
        \\    "jsxFactory": "h",
        \\    "jsxFragmentFactory": "Fragment",
        \\    "reactNamespace": "React"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 4), diags.len);
    try t.expectEqual(@as(u32, 5053), diags[0].code);
    try t.expectEqualStrings("Option 'reactNamespace' cannot be specified with option 'jsxFactory'.", diags[0].message);
    try t.expectEqual(@as(u32, 5089), diags[1].code);
    try t.expectEqualStrings("Option 'jsxFactory' cannot be specified when option 'jsx' is 'react-jsx'.", diags[1].message);
    try t.expectEqual(@as(u32, 5089), diags[2].code);
    try t.expectEqualStrings("Option 'jsxFragmentFactory' cannot be specified when option 'jsx' is 'react-jsx'.", diags[2].message);
    try t.expectEqual(@as(u32, 5089), diags[3].code);
    try t.expectEqualStrings("Option 'reactNamespace' cannot be specified when option 'jsx' is 'react-jsx'.", diags[3].message);
}

test "tsconfig.validate: invalid JSX factory option values report upstream codes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "jsx": "react",
        \\    "jsxFactory": "Element.createElement=",
        \\    "jsxFragmentFactory": "234"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), diags.len);
    try t.expectEqual(@as(u32, 5067), diags[0].code);
    try t.expectEqualStrings("Invalid value for 'jsxFactory'. 'Element.createElement=' is not a valid identifier or qualified-name.", diags[0].message);
    try t.expectEqual(@as(u32, 18035), diags[1].code);
    try t.expectEqualStrings("Invalid value for 'jsxFragmentFactory'. '234' is not a valid identifier or qualified-name.", diags[1].message);
}

test "tsconfig.validate: invalid reactNamespace reports TS5059" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "reactNamespace": "my-React-Lib" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5059), diags[0].code);
    try t.expectEqualStrings("Invalid value for '--reactNamespace'. 'my-React-Lib' is not a valid identifier.", diags[0].message);
    try t.expectEqualStrings("reactNamespace", diags[0].field);
}

test "tsconfig.validate: unknown compiler option reports TS5023" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "totallyMadeUpOption": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5023));
    const d = findCode(diags, 5023).?;
    try t.expectEqualStrings("Unknown compiler option 'totallyMadeUpOption'.", d.message);
    try t.expectEqualStrings("totallyMadeUpOption", d.field);
    try t.expectEqual(@as(usize, 0), countCode(diags, 5025));
}

test "tsconfig.validate: invalid unknown root value reports TS1328" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "foo": [undefined] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 1328));
    const d = findCode(diags, 1328).?;
    try t.expectEqualStrings("foo", d.field);
    try t.expectEqualStrings("Property value can only be string literal, numeric literal, 'true', 'false', 'null', object literal or array literal.", d.message);
}

test "tsconfig.validate: invalid unknown compiler option value reports TS1328 after TS5023" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "totallyMadeUpOption": undefined } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5023));
    try t.expectEqual(@as(usize, 1), countCode(diags, 1328));
    try t.expect(diags.len >= 2);
    try t.expectEqual(@as(u32, 5023), diags[0].code);
    try t.expectEqual(@as(u32, 1328), diags[1].code);
}

test "tsconfig.validate: invalid known compiler option value stays TS5024" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": undefined } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5024));
    try t.expectEqual(@as(usize, 0), countCode(diags, 1328));
}

test "tsconfig.validate: misspelled compiler option reports TS5025 with suggestion" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strickt": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5025));
    const d = findCode(diags, 5025).?;
    try t.expectEqualStrings("Unknown compiler option 'strickt'. Did you mean 'strict'?", d.message);
    try t.expectEqualStrings("strickt", d.field);
}

test "tsconfig.validate: known-but-unmodeled option is not flagged unknown" {
    // `outFile`, `noEmitOnError`, `pretty`, `listFiles` are real tsc
    // options Home does not yet materialize into typed fields. They land
    // in `extra` but must NOT produce TS5023. (`outFile` additionally
    // triggers the TS5102 removed-option diagnostic.)
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "noEmitOnError": true, "pretty": true, "listFiles": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), countCode(diags, 5023));
    try t.expectEqual(@as(usize, 0), countCode(diags, 5025));
}

test "tsconfig.validate: command-line-only compiler options report TS6266" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "watch": true, "showConfig": true, "locale": "en", "strict": true } }
    );
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.strict);
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), countCode(diags, 6266));

    const first = findCode(diags, 6266).?;
    try t.expectEqualStrings("Option 'watch' can only be specified on command line.", first.message);
    try t.expectEqualStrings("watch", first.field);

    var saw_show_config = false;
    var saw_locale = false;
    for (diags) |d| {
        if (d.code != 6266) continue;
        if (std.mem.eql(u8, d.field, "showConfig")) saw_show_config = true;
        if (std.mem.eql(u8, d.field, "locale")) saw_locale = true;
    }
    try t.expect(saw_show_config);
    try t.expect(saw_locale);
}

test "tsconfig.validate: invalid enum compiler options report TS6046" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "nope", "target": "wat", "jsx": "nah", "moduleResolution": "zz", "strict": true } }
    );
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.strict);
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 4), countCode(diags, 6046));

    var saw_module = false;
    var saw_target = false;
    var saw_jsx = false;
    var saw_module_resolution = false;
    for (diags) |d| {
        if (d.code != 6046) continue;
        if (std.mem.eql(u8, d.field, "module")) {
            saw_module = true;
            try t.expectEqualStrings("Argument for '--module' option must be: 'commonjs', 'es6', 'es2015', 'es2020', 'es2022', 'esnext', 'node16', 'node18', 'node20', 'nodenext', 'preserve'.", d.message);
        }
        if (std.mem.eql(u8, d.field, "target")) {
            saw_target = true;
            try t.expectEqualStrings("Argument for '--target' option must be: 'es6', 'es2015', 'es2016', 'es2017', 'es2018', 'es2019', 'es2020', 'es2021', 'es2022', 'es2023', 'es2024', 'es2025', 'esnext'.", d.message);
        }
        if (std.mem.eql(u8, d.field, "jsx")) {
            saw_jsx = true;
            try t.expectEqualStrings("Argument for '--jsx' option must be: 'preserve', 'react-native', 'react-jsx', 'react-jsxdev', 'react'.", d.message);
        }
        if (std.mem.eql(u8, d.field, "moduleResolution")) {
            saw_module_resolution = true;
            try t.expectEqualStrings("Argument for '--moduleResolution' option must be: 'node16', 'nodenext', 'bundler'.", d.message);
        }
    }
    try t.expect(saw_module);
    try t.expect(saw_target);
    try t.expect(saw_jsx);
    try t.expect(saw_module_resolution);
}

test "tsconfig.validate: value-type mismatch reports TS5024" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // `strict` expects a boolean; a string value is a value-type
    // mismatch. The parse must not abort — `target` after it still
    // parses cleanly.
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": "yes", "target": "es2022" } }
    );
    try t.expectEqual(@as(?Target, .es2022), cfg.compiler_options.target);
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5024));
    const d = findCode(diags, 5024).?;
    try t.expectEqualStrings("Compiler option 'strict' requires a value of type boolean.", d.message);
    try t.expectEqualStrings("strict", d.field);
}

test "tsconfig.validate: string option given non-string reports TS5024" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "outDir": 42 } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5024));
    const d = findCode(diags, 5024).?;
    try t.expectEqualStrings("Compiler option 'outDir' requires a value of type string.", d.message);
}

test "tsconfig.validate: enum option given non-string reports TS5024" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "target": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5024));
    const d = findCode(diags, 5024).?;
    try t.expectEqualStrings("Compiler option 'target' requires a value of type string.", d.message);
    // The bad value leaves `target` unset.
    try t.expectEqual(@as(?Target, null), cfg.compiler_options.target);
}

test "tsconfig.validate: list option given non-array reports TS5024" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "lib": "es2022" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5024));
    const d = findCode(diags, 5024).?;
    try t.expectEqualStrings("Compiler option 'lib' requires a value of type Array.", d.message);
}

test "tsconfig.validate: paths substitution wrong type reports TS5064" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "paths": { "@/*": ["src/*", 42, true] } } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), countCode(diags, 5064));
    var saw_number = false;
    var saw_boolean = false;
    for (diags) |d| {
        if (d.code != 5064) continue;
        try t.expectEqualStrings("paths", d.field);
        try t.expect(std.mem.indexOf(u8, d.message, "for pattern '@/*'") != null);
        if (std.mem.indexOf(u8, d.message, "got 'number'") != null) saw_number = true;
        if (std.mem.indexOf(u8, d.message, "got 'boolean'") != null) saw_boolean = true;
    }
    try t.expect(saw_number and saw_boolean);
    // The good substitution still parsed.
    try t.expectEqual(@as(usize, 1), cfg.compiler_options.paths.?.substitutions[0].len);
    try t.expectEqualStrings("src/*", cfg.compiler_options.paths.?.substitutions[0][0]);
}

test "tsconfig.validate: paths value non-array reports TS5063" {
    // Previously fell back to the generic TS5024 ("requires a value
    // of type Array") for this case, but upstream tsc emits the
    // narrower TS5063 for `paths` substitution-value mismatches.
    // Mirrors `commandLineParser` / `parseCustomTypeOption`.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "paths": { "@/*": "src/*" } } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5063));
    const d = findCode(diags, 5063).?;
    try t.expectEqualStrings("Substitutions for pattern '@/*' should be an array.", d.message);
}

test "tsconfig.validate: removed valueless option reports TS5102 with chain" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "baseUrl": "." } }
    );
    cfg.file_path = "/repo/tsconfig.json";
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5102));
    const d = findCode(diags, 5102).?;
    try t.expectEqualStrings("Option 'baseUrl' has been removed. Please remove it from your configuration.", d.message);
    try t.expectEqualStrings("baseUrl", d.field);
    // The "Use ... instead" companion chain (TS5106) is attached because
    // a config path is known.
    try t.expectEqual(@as(usize, 1), countCode(diags, 5106));
    const chain = findCode(diags, 5106).?;
    try t.expectEqualStrings("Use '\"paths\": {\"*\": [\"./*\"]}' instead.", chain.message);
}

test "tsconfig.validate: removed valueless option without config path omits chain" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "baseUrl": "." } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5102));
    try t.expectEqual(@as(usize, 0), countCode(diags, 5106));
}

test "tsconfig.validate: removed enum value reports TS5108" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "amd" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5108));
    const d = findCode(diags, 5108).?;
    try t.expectEqualStrings("Option 'module=AMD' has been removed. Please remove it from your configuration.", d.message);
    try t.expectEqualStrings("module", d.field);
}

test "tsconfig.validate: removed boolean=false options report TS5108" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "esModuleInterop": false, "allowSyntheticDefaultImports": false, "alwaysStrict": false } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), countCode(diags, 5108));
    var saw_interop = false;
    var saw_synth = false;
    var saw_strict = false;
    for (diags) |d| {
        if (d.code != 5108) continue;
        if (std.mem.eql(u8, d.message, "Option 'esModuleInterop=false' has been removed. Please remove it from your configuration.")) saw_interop = true;
        if (std.mem.eql(u8, d.message, "Option 'allowSyntheticDefaultImports=false' has been removed. Please remove it from your configuration.")) saw_synth = true;
        if (std.mem.eql(u8, d.message, "Option 'alwaysStrict=false' has been removed. Please remove it from your configuration.")) saw_strict = true;
    }
    try t.expect(saw_interop and saw_synth and saw_strict);
}

test "tsconfig.validate: downlevelIteration when set reports TS5102" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "downlevelIteration": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5102));
    const d = findCode(diags, 5102).?;
    try t.expectEqualStrings("Option 'downlevelIteration' has been removed. Please remove it from your configuration.", d.message);
}

test "tsconfig.validate: include ending in recursive wildcard reports TS5010" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "include": ["src/**", "ok/**/*"] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5010));
    const d = findCode(diags, 5010).?;
    try t.expectEqualStrings("File specification cannot end in a recursive directory wildcard ('**'): 'src/**'.", d.message);
    try t.expectEqualStrings("include", d.field);
}

test "tsconfig.validate: include trailing slash recursive wildcard reports TS5010" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "include": ["src/**/"] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5010));
}

test "tsconfig.validate: parent dir after recursive wildcard reports TS5065" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "exclude": ["**/../foo"] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5065));
    const d = findCode(diags, 5065).?;
    try t.expectEqualStrings("File specification cannot contain a parent directory ('..') that appears after a recursive directory wildcard ('**'): '**/../foo'.", d.message);
    try t.expectEqualStrings("exclude", d.field);
}

test "tsconfig.validate: include parent dir after wildcard reports TS5065" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "include": ["src/**/../sibling/*"] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), countCode(diags, 5065));
}

test "tsconfig.validate: well-formed globs produce no file-spec diagnostics" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "include": ["src/**/*.ts", "a**b/x"], "exclude": ["node_modules", "../outside/**/*"] }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), countCode(diags, 5010));
    try t.expectEqual(@as(usize, 0), countCode(diags, 5065));
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
