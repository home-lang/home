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
    /// Original array length for each pattern before invalid
    /// non-string entries are filtered from `substitutions`.
    raw_substitution_counts: []usize,

    pub fn empty() Paths {
        return .{ .patterns = &.{}, .substitutions = &.{}, .raw_substitution_counts = &.{} };
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
    no_implicit_use_strict: ?bool = null,
    no_strict_generic_checks: ?bool = null,

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
    imports_not_used_as_values: ?[]const u8 = null,
    preserve_value_imports: ?bool = null,
    module_detection: ?[]const u8 = null,
    ignore_deprecations: ?[]const u8 = null,
    preserve_symlinks: ?bool = null,
    allow_umd_global_access: ?bool = null,
    allow_arbitrary_extensions: ?bool = null,
    no_unchecked_side_effect_imports: ?bool = null,

    // -- Emit --
    target: ?Target = null,
    lib: ?[][]const u8 = null,
    no_lib: ?bool = null,
    jsx: ?Jsx = null,
    jsx_factory: ?[]const u8 = null,
    jsx_fragment_factory: ?[]const u8 = null,
    jsx_import_source: ?[]const u8 = null,
    react_namespace: ?[]const u8 = null,
    out_file: ?[]const u8 = null,
    out: ?[]const u8 = null,
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
    charset: ?[]const u8 = null,
    no_check: ?bool = null,
    erasable_syntax_only: ?bool = null,
    lib_replacement: ?bool = null,
    strict_builtin_iterator_return: ?bool = null,
    stable_type_ordering: ?bool = null,
    no_error_truncation: ?bool = null,
    no_resolve: ?bool = null,
    strip_internal: ?bool = null,
    emit_bom: ?bool = null,
    no_emit_on_error: ?bool = null,
    allow_unused_labels: ?bool = null,
    allow_unreachable_code: ?bool = null,

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

pub const OptionParseDiagnostic = struct {
    code: u32,
    option: []const u8,
    expected: []const u8 = "",
    suggestion: ?[]const u8 = null,
};

pub const ConfigParseDiagnostic = struct {
    code: u32,
    option: []const u8 = "",
    expected: []const u8 = "",
    pattern: []const u8 = "",
    actual: []const u8 = "",
    file_kind: []const u8 = "tsconfig.json",
};

pub const ModuleFormatDiagnostic = struct {
    code: u32,
    message: []const u8,
    owns_message: bool = false,
};

pub const ModuleFormatKind = enum {
    esm_package_json_type_module,
    commonjs_package_json_type_not_module,
    commonjs_package_json_missing_type,
    commonjs_package_json_not_found,
};

pub const ModuleFormatSuggestionKind = enum {
    change_extension_or_create_package_json,
    change_extension_or_add_type_module,
    add_type_module_to_package_json,
    create_package_json_type_module,
};

pub const PackageMapKind = enum {
    exports,
    imports,
};

pub const ProjectReference = struct {
    path: []const u8,
    prepend: bool = false,
    circular: bool = false,
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
    /// `references`: project-reference entries.
    references: []ProjectReference,
    /// Unknown keys seen inside top-level `typeAcquisition`. TypeScript
    /// validates that object with its own option table rather than
    /// treating these as generic unknown root keys.
    unknown_type_acquisition_options: [][]const u8,
    /// Option-table diagnostics collected while parsing compilerOptions.
    /// TypeScript's config parser keeps walking after these so users see
    /// all bad option keys/types at once; validation formats them.
    compiler_option_parse_diagnostics: []OptionParseDiagnostic,
    /// Option-table diagnostics collected while parsing top-level
    /// watchOptions.
    watch_option_parse_diagnostics: []OptionParseDiagnostic,
    /// Config-file shape diagnostics that TypeScript reports while
    /// converting `tsconfig.json`.
    config_parse_diagnostics: []ConfigParseDiagnostic,

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

        for (self.config_parse_diagnostics) |diag| {
            try appendConfigParseDiagnostic(gpa, &diags, diag);
        }

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

        for (self.compiler_option_parse_diagnostics) |diag| {
            try appendOptionParseDiagnostic(gpa, &diags, diag, .compiler);
        }
        for (self.watch_option_parse_diagnostics) |diag| {
            try appendOptionParseDiagnostic(gpa, &diags, diag, .watch);
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
        if (self.include) |include| {
            try validateFileSpecs(gpa, &diags, include, "include");
        }
        if (self.exclude) |exclude| {
            try validateFileSpecs(gpa, &diags, exclude, "exclude");
        }
        for (self.references) |ref| {
            if (ref.prepend) {
                try diags.append(gpa, .{
                    .code = 5102,
                    .message = try gpa.dupe(u8, "Option 'prepend' has been removed. Please remove it from your configuration."),
                    .owns_message = true,
                    .field = "references",
                });
            }
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
        if (co.module_detection) |module_detection| {
            if (!std.ascii.eqlIgnoreCase(module_detection, "auto") and
                !std.ascii.eqlIgnoreCase(module_detection, "legacy") and
                !std.ascii.eqlIgnoreCase(module_detection, "force"))
            {
                try appendTs6046(gpa, &diags, "moduleDetection", "'auto', 'legacy', 'force'");
            }
        }
        if (co.imports_not_used_as_values) |imports_not_used_as_values| {
            if (!std.ascii.eqlIgnoreCase(imports_not_used_as_values, "remove") and
                !std.ascii.eqlIgnoreCase(imports_not_used_as_values, "preserve") and
                !std.ascii.eqlIgnoreCase(imports_not_used_as_values, "error"))
            {
                try appendTs6046(gpa, &diags, "importsNotUsedAsValues", "'remove', 'preserve', 'error'");
            }
        }

        // TypeScript 6.0 has crossed the 5.5 removal line for this
        // legacy option family from `verifyDeprecatedCompilerOptions`.
        if (co.target == .es3) {
            try appendTs5108(gpa, &diags, "target", "ES3");
        }
        if (co.no_implicit_use_strict == true) {
            try appendTs5102(gpa, &diags, "noImplicitUseStrict");
        }
        if (co.keyof_strings_only == true) {
            try appendTs5102(gpa, &diags, "keyofStringsOnly");
        }
        if (co.suppress_excess_property_errors == true) {
            try appendTs5102(gpa, &diags, "suppressExcessPropertyErrors");
        }
        if (co.suppress_implicit_any_index_errors == true) {
            try appendTs5102(gpa, &diags, "suppressImplicitAnyIndexErrors");
        }
        if (co.no_strict_generic_checks == true) {
            try appendTs5102(gpa, &diags, "noStrictGenericChecks");
        }
        if (co.charset != null) {
            try appendTs5102(gpa, &diags, "charset");
        }
        if (co.out != null) {
            try appendTs5102(gpa, &diags, "out");
        }
        if (co.imports_not_used_as_values != null) {
            try appendTs5102(gpa, &diags, "importsNotUsedAsValues");
        }
        if (co.preserve_value_imports == true) {
            try appendTs5102(gpa, &diags, "preserveValueImports");
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
        if (co.out_file != null) {
            if (co.module) |explicit_module| {
                if (explicit_module != .amd and explicit_module != .system) {
                    try appendTs6082(gpa, &diags, "outFile");
                    try appendTs6082(gpa, &diags, "module");
                }
            }
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
        if (co.inline_source_map == true and co.map_root != null) {
            try appendTs5053(gpa, &diags, "mapRoot", "mapRoot", "inlineSourceMap");
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
        if (co.out_file != null and (co.isolated_modules == true or co.verbatim_module_syntax == true)) {
            const conflicting = if (co.verbatim_module_syntax == true) "verbatimModuleSyntax" else "isolatedModules";
            try appendTs5053(gpa, &diags, "outFile", "outFile", conflicting);
        }
        if (co.declaration_dir != null and co.out_file != null) {
            try appendTs5053(gpa, &diags, "declarationDir", "declarationDir", "outFile");
        }
        if (co.lib != null and co.no_lib == true) {
            try appendTs5053(gpa, &diags, "lib", "lib", "noLib");
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
        if (co.incremental == true and co.ts_buildinfo_file == null and co.out_file == null and self.file_path.len == 0) {
            try diags.append(gpa, .{
                .code = 5074,
                .message = "Option '--incremental' can only be specified using tsconfig, emitting to single file or when option '--tsBuildInfoFile' is specified.",
                .field = "incremental",
            });
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
            if (co.incremental == false) {
                try diags.append(gpa, .{
                    .code = 6379,
                    .message = "Composite projects may not disable incremental compilation.",
                    .field = "incremental",
                });
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

pub const OptionMessageDiagnostic = struct {
    option: []const u8,
    code: u32,
    message: []const u8,
};

pub const compiler_option_message_diagnostics = [_]OptionMessageDiagnostic{
    .{
        .option = "showConfig",
        .code = 1350,
        .message = "Print the final configuration instead of building.",
    },
    .{
        .option = "preserveValueImports",
        .code = 1449,
        .message = "Preserve unused imported values in the JavaScript output that would otherwise be removed.",
    },
    .{
        .option = "moduleDetection",
        .code = 1475,
        .message = "Control what method is used to detect module-format JS files.",
    },
    .{
        .option = "moduleDetection.default",
        .code = 1476,
        .message = "\"auto\": Treat files with imports, exports, import.meta, jsx (with jsx: react-jsx), or esm format (with module: node16+) as modules.",
    },
    .{
        .option = "jsxFragmentFactory",
        .code = 18034,
        .message = "Specify the JSX fragment factory function to use when targeting 'react' JSX emit with 'jsxFactory' compiler option is specified, e.g. 'Fragment'.",
    },
    .{
        .option = "newLine",
        .code = 6060,
        .message = "Specify the end of line sequence to be used when emitting files: 'CRLF' (dos) or 'LF' (unix).",
    },
    .{
        .option = "experimentalDecorators",
        .code = 6065,
        .message = "Enables experimental support for ES7 decorators.",
    },
    .{
        .option = "init",
        .code = 6070,
        .message = "Initializes a TypeScript project and creates a tsconfig.json file.",
    },
    .{
        .option = "suppressExcessPropertyErrors",
        .code = 6072,
        .message = "Suppress excess property checks for object literals.",
    },
    .{
        .option = "pretty.legacy",
        .code = 6073,
        .message = "Stylize errors and messages using color and context (experimental).",
    },
    .{
        .option = "baseUrl",
        .code = 6083,
        .message = "Base directory to resolve non-absolute module names.",
    },
    .{
        .option = "build",
        .code = 6302,
        .message = "Enable project compilation",
    },
    .{
        .option = "tsBuildInfoFile",
        .code = 6380,
        .message = "Specify file to store incremental compilation information",
    },
};

pub fn compilerOptionMessageDiagnostic(option: []const u8) ?OptionMessageDiagnostic {
    for (compiler_option_message_diagnostics) |diag| {
        if (std.mem.eql(u8, option, diag.option)) return diag;
    }
    return null;
}

pub const FileIncludeReasonKind = enum {
    root_file,
    source_from_project_reference,
    output_from_project_reference,
    import,
    reference_file,
    type_reference_directive,
    automatic_type_directive_file,
    lib_file,
    lib_reference_directive,
};

pub const SyntheticImportKind = enum {
    source_text,
    import_helpers,
    jsx_factory,
};

pub const ReferencedFileReason = struct {
    text: []const u8,
    from_file: []const u8,
    package_id: ?[]const u8 = null,
};

pub const ImportFileReason = struct {
    text: []const u8,
    from_file: []const u8,
    package_id: ?[]const u8 = null,
    synthetic_kind: SyntheticImportKind = .source_text,
};

pub const RootFileReason = union(enum) {
    specified_for_compilation,
    default_include_pattern,
    files_list,
    include_pattern: struct {
        pattern: []const u8,
        config_file: []const u8,
    },
};

pub const ProjectReferenceReason = struct {
    project: []const u8,
    option: []const u8 = "--out",
};

pub const AutomaticTypeDirectiveFileReason = struct {
    type_reference: []const u8,
    package_id: ?[]const u8 = null,
    implicit: bool = false,
};

pub const LibFileReason = union(enum) {
    specified: []const u8,
    default_library,
    default_library_for_target: []const u8,
};

pub const FileIncludeReason = union(FileIncludeReasonKind) {
    root_file: RootFileReason,
    source_from_project_reference: ProjectReferenceReason,
    output_from_project_reference: ProjectReferenceReason,
    import: ImportFileReason,
    reference_file: ReferencedFileReason,
    type_reference_directive: ReferencedFileReason,
    automatic_type_directive_file: AutomaticTypeDirectiveFileReason,
    lib_file: LibFileReason,
    lib_reference_directive: ReferencedFileReason,
};

pub const FileIncludeDiagnostic = struct {
    code: u32,
    message: []const u8,
    owns_message: bool = false,
    related_code: ?u32 = null,
    related_message: ?[]const u8 = null,
    owns_related_message: bool = false,
};

pub fn freeFileIncludeDiagnostic(gpa: std.mem.Allocator, diag: FileIncludeDiagnostic) void {
    if (diag.owns_message) gpa.free(diag.message);
    if (diag.owns_related_message) {
        if (diag.related_message) |message| gpa.free(message);
    }
}

pub fn fileIncludeReasonToDiagnostic(gpa: std.mem.Allocator, reason: FileIncludeReason) !FileIncludeDiagnostic {
    return switch (reason) {
        .import => |import_reason| importFileReasonToDiagnostic(gpa, import_reason),
        .reference_file => |ref| .{
            .code = 1400,
            .message = try std.fmt.allocPrint(gpa, "Referenced via '{s}' from file '{s}'", .{ ref.text, ref.from_file }),
            .owns_message = true,
            .related_code = 1401,
            .related_message = "File is included via reference here.",
        },
        .type_reference_directive => |ref| if (ref.package_id) |package_id| .{
            .code = 1403,
            .message = try std.fmt.allocPrint(gpa, "Type library referenced via '{s}' from file '{s}' with packageId '{s}'", .{ ref.text, ref.from_file, package_id }),
            .owns_message = true,
            .related_code = 1404,
            .related_message = "File is included via type library reference here.",
        } else .{
            .code = 1402,
            .message = try std.fmt.allocPrint(gpa, "Type library referenced via '{s}' from file '{s}'", .{ ref.text, ref.from_file }),
            .owns_message = true,
            .related_code = 1404,
            .related_message = "File is included via type library reference here.",
        },
        .lib_reference_directive => |ref| .{
            .code = 1405,
            .message = try std.fmt.allocPrint(gpa, "Library referenced via '{s}' from file '{s}'", .{ ref.text, ref.from_file }),
            .owns_message = true,
            .related_code = 1406,
            .related_message = "File is included via library reference here.",
        },
        .root_file => |root| switch (root) {
            .specified_for_compilation => .{
                .code = 1427,
                .message = "Root file specified for compilation",
            },
            .default_include_pattern => .{
                .code = 1457,
                .message = "Matched by default include pattern '**/*'",
            },
            .files_list => .{
                .code = 1409,
                .message = "Part of 'files' list in tsconfig.json",
                .related_code = 1410,
                .related_message = "File is matched by 'files' list specified here.",
            },
            .include_pattern => |include| .{
                .code = 1407,
                .message = try std.fmt.allocPrint(gpa, "Matched by include pattern '{s}' in '{s}'", .{ include.pattern, include.config_file }),
                .owns_message = true,
                .related_code = 1408,
                .related_message = "File is matched by include pattern specified here.",
            },
        },
        .automatic_type_directive_file => |type_directive| automaticTypeDirectiveFileReasonToDiagnostic(gpa, type_directive),
        .lib_file => |lib| switch (lib) {
            .specified => |name| .{
                .code = 1422,
                .message = try std.fmt.allocPrint(gpa, "Library '{s}' specified in compilerOptions", .{name}),
                .owns_message = true,
                .related_code = 1423,
                .related_message = "File is library specified here.",
            },
            .default_library => .{
                .code = 1424,
                .message = "Default library",
            },
            .default_library_for_target => |target| .{
                .code = 1425,
                .message = try std.fmt.allocPrint(gpa, "Default library for target '{s}'", .{target}),
                .owns_message = true,
                .related_code = 1426,
                .related_message = "File is default library for target specified here.",
            },
        },
        .output_from_project_reference => |project| if (std.mem.eql(u8, project.option, "--module=none")) .{
            .code = 1412,
            .message = try std.fmt.allocPrint(gpa, "Output from referenced project '{s}' included because '--module' is specified as 'none'", .{project.project}),
            .owns_message = true,
            .related_code = 1413,
            .related_message = "File is output from referenced project specified here.",
        } else .{
            .code = 1411,
            .message = try std.fmt.allocPrint(gpa, "Output from referenced project '{s}' included because '{s}' specified", .{ project.project, project.option }),
            .owns_message = true,
            .related_code = 1413,
            .related_message = "File is output from referenced project specified here.",
        },
        .source_from_project_reference => |project| if (std.mem.eql(u8, project.option, "--module=none")) .{
            .code = 1415,
            .message = try std.fmt.allocPrint(gpa, "Source from referenced project '{s}' included because '--module' is specified as 'none'", .{project.project}),
            .owns_message = true,
            .related_code = 1416,
            .related_message = "File is source from referenced project specified here.",
        } else .{
            .code = 1414,
            .message = try std.fmt.allocPrint(gpa, "Source from referenced project '{s}' included because '{s}' specified", .{ project.project, project.option }),
            .owns_message = true,
            .related_code = 1416,
            .related_message = "File is source from referenced project specified here.",
        },
    };
}

pub fn fileRedirectDiagnostic(gpa: std.mem.Allocator, target: []const u8) !FileIncludeDiagnostic {
    return .{
        .code = 1429,
        .message = try std.fmt.allocPrint(gpa, "File redirects to file '{s}'", .{target}),
        .owns_message = true,
    };
}

pub fn projectReferenceSourceOutputDiagnostic(gpa: std.mem.Allocator, source: []const u8) !FileIncludeDiagnostic {
    return .{
        .code = 1428,
        .message = try std.fmt.allocPrint(gpa, "File is output of project reference source '{s}'", .{source}),
        .owns_message = true,
    };
}

pub fn fileProgramReasonHeaderDiagnostic() FileIncludeDiagnostic {
    return .{
        .code = 1430,
        .message = "The file is in the program because:",
    };
}

pub fn fileNameCasingDiagnostic(
    gpa: std.mem.Allocator,
    file_name: []const u8,
    existing_file_name: []const u8,
    has_existing_reference_reason: bool,
) !ValidationDiagnostic {
    if (has_existing_reference_reason) {
        return .{
            .code = 1261,
            .message = try std.fmt.allocPrint(gpa, "Already included file name '{s}' differs from file name '{s}' only in casing.", .{ existing_file_name, file_name }),
            .owns_message = true,
            .field = "forceConsistentCasingInFileNames",
        };
    }
    return .{
        .code = 1149,
        .message = try std.fmt.allocPrint(gpa, "File name '{s}' differs from already included file name '{s}' only in casing.", .{ file_name, existing_file_name }),
        .owns_message = true,
        .field = "forceConsistentCasingInFileNames",
    };
}

fn automaticTypeDirectiveFileReasonToDiagnostic(gpa: std.mem.Allocator, ref: AutomaticTypeDirectiveFileReason) !FileIncludeDiagnostic {
    if (ref.implicit) {
        if (ref.package_id) |package_id| {
            return .{
                .code = 1421,
                .message = try std.fmt.allocPrint(gpa, "Entry point for implicit type library '{s}' with packageId '{s}'", .{ ref.type_reference, package_id }),
                .owns_message = true,
            };
        }
        return .{
            .code = 1420,
            .message = try std.fmt.allocPrint(gpa, "Entry point for implicit type library '{s}'", .{ref.type_reference}),
            .owns_message = true,
        };
    }

    if (ref.package_id) |package_id| {
        return .{
            .code = 1418,
            .message = try std.fmt.allocPrint(gpa, "Entry point of type library '{s}' specified in compilerOptions with packageId '{s}'", .{ ref.type_reference, package_id }),
            .owns_message = true,
            .related_code = 1419,
            .related_message = "File is entry point of type library specified here.",
        };
    }
    return .{
        .code = 1417,
        .message = try std.fmt.allocPrint(gpa, "Entry point of type library '{s}' specified in compilerOptions", .{ref.type_reference}),
        .owns_message = true,
        .related_code = 1419,
        .related_message = "File is entry point of type library specified here.",
    };
}

fn importFileReasonToDiagnostic(gpa: std.mem.Allocator, ref: ImportFileReason) !FileIncludeDiagnostic {
    const has_package_id = ref.package_id != null;
    const code: u32 = switch (ref.synthetic_kind) {
        .source_text => if (has_package_id) 1394 else 1393,
        .import_helpers => if (has_package_id) 1396 else 1395,
        .jsx_factory => if (has_package_id) 1398 else 1397,
    };
    const message = switch (ref.synthetic_kind) {
        .source_text => if (ref.package_id) |package_id|
            try std.fmt.allocPrint(gpa, "Imported via {s} from file '{s}' with packageId '{s}'", .{ ref.text, ref.from_file, package_id })
        else
            try std.fmt.allocPrint(gpa, "Imported via {s} from file '{s}'", .{ ref.text, ref.from_file }),
        .import_helpers => if (ref.package_id) |package_id|
            try std.fmt.allocPrint(gpa, "Imported via {s} from file '{s}' with packageId '{s}' to import 'importHelpers' as specified in compilerOptions", .{ ref.text, ref.from_file, package_id })
        else
            try std.fmt.allocPrint(gpa, "Imported via {s} from file '{s}' to import 'importHelpers' as specified in compilerOptions", .{ ref.text, ref.from_file }),
        .jsx_factory => if (ref.package_id) |package_id|
            try std.fmt.allocPrint(gpa, "Imported via {s} from file '{s}' with packageId '{s}' to import 'jsx' and 'jsxs' factory functions", .{ ref.text, ref.from_file, package_id })
        else
            try std.fmt.allocPrint(gpa, "Imported via {s} from file '{s}' to import 'jsx' and 'jsxs' factory functions", .{ ref.text, ref.from_file }),
    };
    return .{
        .code = code,
        .message = message,
        .owns_message = true,
        .related_code = 1399,
        .related_message = "File is included via import here.",
    };
}

fn appendConfigParseDiagnostic(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    diag: ConfigParseDiagnostic,
) !void {
    const msg = switch (diag.code) {
        5063 => try std.fmt.allocPrint(gpa, "Substitutions for pattern '{s}' should be an array.", .{diag.pattern}),
        5064 => try std.fmt.allocPrint(gpa, "Substitution '{s}' for pattern '{s}' has incorrect type, expected 'string', got '{s}'.", .{ diag.option, diag.pattern, diag.actual }),
        6114 => try gpa.dupe(u8, "Unknown option 'excludes'. Did you mean 'exclude'?"),
        6258 => try std.fmt.allocPrint(gpa, "'{s}' should be set inside the 'compilerOptions' object of the config json file", .{diag.option}),
        5092 => try std.fmt.allocPrint(gpa, "The root value of a '{s}' file must be an object.", .{diag.file_kind}),
        1327 => try gpa.dupe(u8, "String literal with double quotes expected."),
        1328 => try gpa.dupe(u8, "Property value can only be string literal, numeric literal, 'true', 'false', 'null', object literal or array literal."),
        6266 => try std.fmt.allocPrint(gpa, "Option '{s}' can only be specified on command line.", .{diag.option}),
        5024 => try std.fmt.allocPrint(gpa, "Compiler option '{s}' requires a value of type {s}.", .{ diag.option, diag.expected }),
        else => unreachable,
    };
    try diags.append(gpa, .{
        .code = diag.code,
        .message = msg,
        .owns_message = true,
        .field = switch (diag.code) {
            5063, 5064 => "paths",
            6114 => "excludes",
            6258 => diag.option,
            5092 => "",
            1327, 1328 => "",
            6266 => diag.option,
            5024 => diag.option,
            else => "",
        },
    });
}

const OptionDiagnosticKind = enum {
    compiler,
    watch,
};

fn appendOptionParseDiagnostic(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    diag: OptionParseDiagnostic,
    kind: OptionDiagnosticKind,
) !void {
    const ts5023: u32 = 5023;
    const ts5024: u32 = 5024;
    const ts5025: u32 = 5025;
    const ts5078: u32 = 5078;
    const ts5079: u32 = 5079;
    const ts5080: u32 = 5080;
    const message = switch (kind) {
        .compiler => switch (diag.code) {
            ts5023 => try std.fmt.allocPrint(gpa, "Unknown compiler option '{s}'.", .{diag.option}),
            ts5024 => try std.fmt.allocPrint(gpa, "Compiler option '{s}' requires a value of type {s}.", .{ diag.option, diag.expected }),
            ts5025 => try std.fmt.allocPrint(gpa, "Unknown compiler option '{s}'. Did you mean '{s}'?", .{ diag.option, diag.suggestion.? }),
            else => unreachable,
        },
        .watch => switch (diag.code) {
            ts5078 => try std.fmt.allocPrint(gpa, "Unknown watch option '{s}'.", .{diag.option}),
            ts5079 => try std.fmt.allocPrint(gpa, "Unknown watch option '{s}'. Did you mean '{s}'?", .{ diag.option, diag.suggestion.? }),
            ts5080 => try std.fmt.allocPrint(gpa, "Watch option '{s}' requires a value of type {s}.", .{ diag.option, diag.expected }),
            else => unreachable,
        },
    };
    try diags.append(gpa, .{
        .code = diag.code,
        .message = message,
        .owns_message = true,
        .field = switch (kind) {
            .compiler => "compilerOptions",
            .watch => "watchOptions",
        },
    });
}

pub fn freeValidationDiagnostics(gpa: std.mem.Allocator, diags: []ValidationDiagnostic) void {
    for (diags) |d| {
        if (d.owns_message) gpa.free(d.message);
    }
    gpa.free(diags);
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
        const raw_count = if (idx < paths.raw_substitution_counts.len) paths.raw_substitution_counts[idx] else substitutions.len;
        if (raw_count == 0) {
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

fn validateFileSpecs(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    specs: []const []const u8,
    field: []const u8,
) !void {
    for (specs) |spec| {
        if (fileSpecEndsInRecursiveWildcard(spec)) {
            try appendTs5010(gpa, diags, spec, field);
        }
        if (fileSpecHasParentAfterRecursiveWildcard(spec)) {
            try appendTs5065(gpa, diags, spec, field);
        }
    }
}

fn fileSpecEndsInRecursiveWildcard(spec: []const u8) bool {
    const trimmed = std.mem.trim(u8, spec, "/\\");
    if (trimmed.len == 0) return false;
    const last_sep = std.mem.lastIndexOfAny(u8, trimmed, "/\\");
    const segment = if (last_sep) |idx| trimmed[idx + 1 ..] else trimmed;
    return std.mem.eql(u8, segment, "**");
}

fn fileSpecHasParentAfterRecursiveWildcard(spec: []const u8) bool {
    var saw_recursive = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= spec.len) : (i += 1) {
        if (i == spec.len or spec[i] == '/' or spec[i] == '\\') {
            const segment = spec[start..i];
            if (std.mem.eql(u8, segment, "**")) {
                saw_recursive = true;
            } else if (saw_recursive and std.mem.eql(u8, segment, "..")) {
                return true;
            }
            start = i + 1;
        }
    }
    return false;
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

fn appendTs5010(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    spec: []const u8,
    field: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "File specification cannot end in a recursive directory wildcard ('**'): '{s}'.", .{spec});
    try diags.append(gpa, .{
        .code = 5010,
        .message = msg,
        .owns_message = true,
        .field = field,
    });
}

fn appendTs5065(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    spec: []const u8,
    field: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "File specification cannot contain a parent directory ('..') that appears after a recursive directory wildcard ('**'): '{s}'.", .{spec});
    try diags.append(gpa, .{
        .code = 5065,
        .message = msg,
        .owns_message = true,
        .field = field,
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
        .es2022, .es2023, .es2024 => .es2022,
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

fn appendTs6082(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    option: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Only 'amd' and 'system' modules are supported alongside --{s}.", .{option});
    try diags.append(gpa, .{
        .code = 6082,
        .message = msg,
        .owns_message = true,
        .field = option,
    });
}

fn appendTs5102(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    option: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}' has been removed. Please remove it from your configuration.", .{option});
    try diags.append(gpa, .{
        .code = 5102,
        .message = msg,
        .owns_message = true,
        .field = option,
    });
}

fn appendTs5108(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    option: []const u8,
    value: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Option '{s}={s}' has been removed. Please remove it from your configuration.", .{ option, value });
    try diags.append(gpa, .{
        .code = 5108,
        .message = msg,
        .owns_message = true,
        .field = option,
    });
}

fn appendTs6046(
    gpa: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(ValidationDiagnostic),
    option: []const u8,
    values: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(gpa, "Argument for '--{s}' option must be: {s}.", .{ option, values });
    try diags.append(gpa, .{
        .code = 6046,
        .message = msg,
        .owns_message = true,
        .field = option,
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

const OptionValueKind = enum {
    boolean,
    string,
    number,
    array,
    object,
    string_or_array,

    fn typeString(self: OptionValueKind) []const u8 {
        return switch (self) {
            .boolean => "boolean",
            .string => "string",
            .number => "number",
            .array => "Array",
            .object => "object",
            .string_or_array => "string or Array",
        };
    }

    fn matches(self: OptionValueKind, value: jsonc.Value) bool {
        return switch (value) {
            .null_ => true,
            .bool_ => self == .boolean,
            .number => self == .number,
            .string => self == .string or self == .string_or_array,
            .array => self == .array or self == .string_or_array,
            .object => self == .object,
        };
    }
};

const OptionSpec = struct {
    name: []const u8,
    kind: OptionValueKind,
};

const compiler_option_specs = [_]OptionSpec{
    .{ .name = "help", .kind = .boolean },
    .{ .name = "watch", .kind = .boolean },
    .{ .name = "preserveWatchOutput", .kind = .boolean },
    .{ .name = "listFiles", .kind = .boolean },
    .{ .name = "explainFiles", .kind = .boolean },
    .{ .name = "listEmittedFiles", .kind = .boolean },
    .{ .name = "pretty", .kind = .boolean },
    .{ .name = "traceResolution", .kind = .boolean },
    .{ .name = "diagnostics", .kind = .boolean },
    .{ .name = "extendedDiagnostics", .kind = .boolean },
    .{ .name = "generateCpuProfile", .kind = .string },
    .{ .name = "generateTrace", .kind = .string },
    .{ .name = "incremental", .kind = .boolean },
    .{ .name = "declaration", .kind = .boolean },
    .{ .name = "declarationMap", .kind = .boolean },
    .{ .name = "emitDeclarationOnly", .kind = .boolean },
    .{ .name = "sourceMap", .kind = .boolean },
    .{ .name = "inlineSourceMap", .kind = .boolean },
    .{ .name = "noCheck", .kind = .boolean },
    .{ .name = "noEmit", .kind = .boolean },
    .{ .name = "assumeChangesOnlyAffectDirectDependencies", .kind = .boolean },
    .{ .name = "locale", .kind = .string },
    .{ .name = "target", .kind = .string },
    .{ .name = "module", .kind = .string },
    .{ .name = "all", .kind = .boolean },
    .{ .name = "version", .kind = .boolean },
    .{ .name = "init", .kind = .boolean },
    .{ .name = "project", .kind = .string },
    .{ .name = "showConfig", .kind = .boolean },
    .{ .name = "listFilesOnly", .kind = .boolean },
    .{ .name = "ignoreConfig", .kind = .boolean },
    .{ .name = "lib", .kind = .string_or_array },
    .{ .name = "allowJs", .kind = .boolean },
    .{ .name = "checkJs", .kind = .boolean },
    .{ .name = "jsx", .kind = .string },
    .{ .name = "outFile", .kind = .string },
    .{ .name = "outDir", .kind = .string },
    .{ .name = "rootDir", .kind = .string },
    .{ .name = "composite", .kind = .boolean },
    .{ .name = "tsBuildInfoFile", .kind = .string },
    .{ .name = "removeComments", .kind = .boolean },
    .{ .name = "importHelpers", .kind = .boolean },
    .{ .name = "importsNotUsedAsValues", .kind = .string },
    .{ .name = "downlevelIteration", .kind = .boolean },
    .{ .name = "isolatedModules", .kind = .boolean },
    .{ .name = "verbatimModuleSyntax", .kind = .boolean },
    .{ .name = "isolatedDeclarations", .kind = .boolean },
    .{ .name = "erasableSyntaxOnly", .kind = .boolean },
    .{ .name = "libReplacement", .kind = .boolean },
    .{ .name = "strict", .kind = .boolean },
    .{ .name = "noImplicitAny", .kind = .boolean },
    .{ .name = "strictNullChecks", .kind = .boolean },
    .{ .name = "strictFunctionTypes", .kind = .boolean },
    .{ .name = "strictBindCallApply", .kind = .boolean },
    .{ .name = "strictPropertyInitialization", .kind = .boolean },
    .{ .name = "strictBuiltinIteratorReturn", .kind = .boolean },
    .{ .name = "stableTypeOrdering", .kind = .boolean },
    .{ .name = "noImplicitThis", .kind = .boolean },
    .{ .name = "useUnknownInCatchVariables", .kind = .boolean },
    .{ .name = "alwaysStrict", .kind = .boolean },
    .{ .name = "noUnusedLocals", .kind = .boolean },
    .{ .name = "noUnusedParameters", .kind = .boolean },
    .{ .name = "exactOptionalPropertyTypes", .kind = .boolean },
    .{ .name = "noImplicitReturns", .kind = .boolean },
    .{ .name = "noFallthroughCasesInSwitch", .kind = .boolean },
    .{ .name = "noUncheckedIndexedAccess", .kind = .boolean },
    .{ .name = "noImplicitOverride", .kind = .boolean },
    .{ .name = "noPropertyAccessFromIndexSignature", .kind = .boolean },
    .{ .name = "moduleResolution", .kind = .string },
    .{ .name = "baseUrl", .kind = .string },
    .{ .name = "paths", .kind = .object },
    .{ .name = "rootDirs", .kind = .string_or_array },
    .{ .name = "typeRoots", .kind = .string_or_array },
    .{ .name = "types", .kind = .string_or_array },
    .{ .name = "allowSyntheticDefaultImports", .kind = .boolean },
    .{ .name = "esModuleInterop", .kind = .boolean },
    .{ .name = "preserveSymlinks", .kind = .boolean },
    .{ .name = "allowUmdGlobalAccess", .kind = .boolean },
    .{ .name = "moduleSuffixes", .kind = .array },
    .{ .name = "allowImportingTsExtensions", .kind = .boolean },
    .{ .name = "rewriteRelativeImportExtensions", .kind = .boolean },
    .{ .name = "resolvePackageJsonExports", .kind = .boolean },
    .{ .name = "resolvePackageJsonImports", .kind = .boolean },
    .{ .name = "customConditions", .kind = .array },
    .{ .name = "noUncheckedSideEffectImports", .kind = .boolean },
    .{ .name = "sourceRoot", .kind = .string },
    .{ .name = "mapRoot", .kind = .string },
    .{ .name = "inlineSources", .kind = .boolean },
    .{ .name = "experimentalDecorators", .kind = .boolean },
    .{ .name = "emitDecoratorMetadata", .kind = .boolean },
    .{ .name = "jsxFactory", .kind = .string },
    .{ .name = "jsxFragmentFactory", .kind = .string },
    .{ .name = "jsxImportSource", .kind = .string },
    .{ .name = "resolveJsonModule", .kind = .boolean },
    .{ .name = "allowArbitraryExtensions", .kind = .boolean },
    .{ .name = "out", .kind = .string },
    .{ .name = "reactNamespace", .kind = .string },
    .{ .name = "skipDefaultLibCheck", .kind = .boolean },
    .{ .name = "charset", .kind = .string },
    .{ .name = "emitBOM", .kind = .boolean },
    .{ .name = "newLine", .kind = .string },
    .{ .name = "noErrorTruncation", .kind = .boolean },
    .{ .name = "noLib", .kind = .boolean },
    .{ .name = "noResolve", .kind = .boolean },
    .{ .name = "stripInternal", .kind = .boolean },
    .{ .name = "disableSizeLimit", .kind = .boolean },
    .{ .name = "disableSourceOfProjectReferenceRedirect", .kind = .boolean },
    .{ .name = "disableSolutionSearching", .kind = .boolean },
    .{ .name = "disableReferencedProjectLoad", .kind = .boolean },
    .{ .name = "noImplicitUseStrict", .kind = .boolean },
    .{ .name = "noEmitHelpers", .kind = .boolean },
    .{ .name = "noEmitOnError", .kind = .boolean },
    .{ .name = "preserveConstEnums", .kind = .boolean },
    .{ .name = "declarationDir", .kind = .string },
    .{ .name = "skipLibCheck", .kind = .boolean },
    .{ .name = "allowUnusedLabels", .kind = .boolean },
    .{ .name = "allowUnreachableCode", .kind = .boolean },
    .{ .name = "suppressExcessPropertyErrors", .kind = .boolean },
    .{ .name = "suppressImplicitAnyIndexErrors", .kind = .boolean },
    .{ .name = "forceConsistentCasingInFileNames", .kind = .boolean },
    .{ .name = "maxNodeModuleJsDepth", .kind = .number },
    .{ .name = "noStrictGenericChecks", .kind = .boolean },
    .{ .name = "useDefineForClassFields", .kind = .boolean },
    .{ .name = "preserveValueImports", .kind = .boolean },
    .{ .name = "keyofStringsOnly", .kind = .boolean },
    .{ .name = "plugins", .kind = .array },
    .{ .name = "moduleDetection", .kind = .string },
    .{ .name = "ignoreDeprecations", .kind = .string },
};

const watch_option_specs = [_]OptionSpec{
    .{ .name = "watchFile", .kind = .string },
    .{ .name = "watchDirectory", .kind = .string },
    .{ .name = "fallbackPolling", .kind = .string },
    .{ .name = "synchronousWatchDirectory", .kind = .boolean },
    .{ .name = "excludeDirectories", .kind = .array },
    .{ .name = "excludeFiles", .kind = .array },
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

fn findOptionSpec(specs: []const OptionSpec, name: []const u8) ?OptionSpec {
    for (specs) |spec| {
        if (std.ascii.eqlIgnoreCase(name, spec.name)) return spec;
    }
    return null;
}

fn collectOptionParseDiagnostics(
    arena: std.mem.Allocator,
    obj: jsonc.Value.Object,
    specs: []const OptionSpec,
    unknown_code: u32,
    unknown_suggestion_code: u32,
    type_mismatch_code: u32,
) ![]OptionParseDiagnostic {
    var out: std.ArrayListUnmanaged(OptionParseDiagnostic) = .empty;
    for (obj.keys, 0..) |key, i| {
        if (findOptionSpec(specs, key)) |spec| {
            if (!spec.kind.matches(obj.values[i])) {
                try out.append(arena, .{
                    .code = type_mismatch_code,
                    .option = key,
                    .expected = spec.kind.typeString(),
                });
            }
        } else {
            if (optionSuggestion(key, specs)) |suggestion| {
                try out.append(arena, .{
                    .code = unknown_suggestion_code,
                    .option = key,
                    .suggestion = suggestion,
                });
            } else {
                try out.append(arena, .{
                    .code = unknown_code,
                    .option = key,
                });
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn collectConfigParseDiagnostics(arena: std.mem.Allocator, root: jsonc.Value.Object) ![]ConfigParseDiagnostic {
    var out: std.ArrayListUnmanaged(ConfigParseDiagnostic) = .empty;

    const has_compiler_options = root.contains("compilerOptions");
    for (root.keys) |key| {
        if (std.mem.eql(u8, key, "excludes")) {
            try out.append(arena, .{ .code = 6114 });
        } else if (!has_compiler_options and findOptionSpec(&compiler_option_specs, key) != null) {
            try out.append(arena, .{ .code = 6258, .option = key });
        }
    }

    if (root.get("compilerOptions")) |co_v| {
        if (co_v.asObject()) |co| {
            for (co.keys) |key| {
                if (compilerOptionIsCommandLineOnly(key)) {
                    try out.append(arena, .{ .code = 6266, .option = key });
                }
            }
            if (co.get("paths")) |paths_v| {
                if (paths_v.asObject()) |paths| {
                    try collectPathParseDiagnostics(arena, &out, paths);
                }
            }
        }
    }
    if (root.get("references")) |references_v| {
        if (references_v.asArray()) |references| {
            for (references) |ref_v| {
                const ref = ref_v.asObject() orelse continue;
                if (ref.get("path")) |path_v| {
                    if (path_v.asString() == null) {
                        try out.append(arena, .{
                            .code = 5024,
                            .option = "reference.path",
                            .expected = "string",
                        });
                    }
                } else {
                    try out.append(arena, .{
                        .code = 5024,
                        .option = "reference.path",
                        .expected = "string",
                    });
                }
            }
        }
    }

    return out.toOwnedSlice(arena);
}

fn compilerOptionIsCommandLineOnly(key: []const u8) bool {
    const command_line_only = comptime [_][]const u8{
        "help",
        "watch",
        "locale",
        "showConfig",
        "listFilesOnly",
        "ignoreConfig",
    };
    inline for (command_line_only) |name| {
        if (std.ascii.eqlIgnoreCase(key, name)) return true;
    }
    return false;
}

fn collectPathParseDiagnostics(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ConfigParseDiagnostic),
    paths: jsonc.Value.Object,
) !void {
    for (paths.keys, 0..) |pattern, idx| {
        const value = paths.values[idx];
        const substitutions = value.asArray() orelse {
            try out.append(arena, .{ .code = 5063, .pattern = pattern });
            continue;
        };

        for (substitutions) |subst| {
            if (subst.asString() == null) {
                try out.append(arena, .{
                    .code = 5064,
                    .option = try jsonValueDiagnosticText(arena, subst),
                    .pattern = pattern,
                    .actual = jsonTypeofName(subst),
                });
            }
        }
    }
}

fn jsonTypeofName(value: jsonc.Value) []const u8 {
    return switch (value) {
        .bool_ => "boolean",
        .number => "number",
        .string => "string",
        .null_, .array, .object => "object",
    };
}

fn jsonValueDiagnosticText(arena: std.mem.Allocator, value: jsonc.Value) ![]const u8 {
    return switch (value) {
        .null_ => "null",
        .bool_ => |b| if (b) "true" else "false",
        .number => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .string => |s| s,
        .array => "<array>",
        .object => "<object>",
    };
}

fn optionSuggestion(option: []const u8, specs: []const OptionSpec) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (specs) |spec| {
        const max_len_diff = @max(@as(usize, 2), option.len * 34 / 100);
        const len_diff = if (option.len > spec.name.len) option.len - spec.name.len else spec.name.len - option.len;
        if (len_diff > max_len_diff) continue;
        const distance = levenshteinIcase(option, spec.name);
        if (distance < best_distance) {
            best = spec.name;
            best_distance = distance;
        }
    }
    const threshold = option.len * 4 / 10 + 1;
    return if (best != null and best_distance < threshold) best else null;
}

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
        .has_extends = false,
        .files = null,
        .include = null,
        .exclude = null,
        .references = &.{},
        .unknown_type_acquisition_options = &.{},
        .compiler_option_parse_diagnostics = &.{},
        .watch_option_parse_diagnostics = &.{},
        .config_parse_diagnostics = &.{},
    };

    cfg.config_parse_diagnostics = try collectConfigParseDiagnostics(arena, root);

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
            const out = try arena.alloc(ProjectReference, refs.len);
            var n: usize = 0;
            for (refs) |r| {
                if (r.asObject()) |o| {
                    if (o.get("path")) |p| {
                        if (p.asString()) |s| {
                            out[n] = .{
                                .path = s,
                                .prepend = if (o.get("prepend")) |prepend| prepend.asBool() orelse false else false,
                                .circular = if (o.get("circular")) |circular| circular.asBool() orelse false else false,
                            };
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
    if (root.get("watchOptions")) |wo_v| {
        if (wo_v.asObject()) |wo| {
            cfg.watch_option_parse_diagnostics = try collectOptionParseDiagnostics(
                arena,
                wo,
                &watch_option_specs,
                5078,
                5079,
                5080,
            );
        }
    }
    if (root.get("compilerOptions")) |co_v| {
        if (co_v.asObject()) |co| {
            cfg.compiler_option_parse_diagnostics = try collectOptionParseDiagnostics(
                arena,
                co,
                &compiler_option_specs,
                5023,
                5025,
                5024,
            );
            try fillCompilerOptions(arena, &cfg.compiler_options, co);
        }
    }

    return cfg;
}

/// Parse enough of a config-like JSONC file to report TypeScript's
/// conversion diagnostic when the top-level value is not an object.
/// `parseString` still returns `error.NotAnObject` for callers that
/// need a typed config; this helper gives CLI/harness layers the
/// upstream TS5092 diagnostic shape before they bail out.
pub fn parseRootValueDiagnostics(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    file_kind: []const u8,
) LoadError![]ValidationDiagnostic {
    const doc = try jsonc.parse(gpa, arena, source);
    gpa.free(doc.diagnostics);
    if (doc.value.asObject() != null) {
        return try gpa.alloc(ValidationDiagnostic, 0);
    }

    var diags: std.ArrayListUnmanaged(ValidationDiagnostic) = .empty;
    errdefer diags.deinit(gpa);
    try appendConfigParseDiagnostic(gpa, &diags, .{
        .code = 5092,
        .file_kind = file_kind,
    });
    return diags.toOwnedSlice(gpa);
}

/// Scan the JSON source conversion surface that TypeScript reports
/// before typed tsconfig option validation: config/property strings
/// must be double quoted (TS1327), and untyped property values must be
/// JSON literals/objects/arrays (TS1328). This intentionally stays
/// small and syntax-shape oriented; the full value tree still comes
/// from `jsonc.parse`.
pub fn parseJsonConversionDiagnostics(
    gpa: std.mem.Allocator,
    source: []const u8,
) ![]ValidationDiagnostic {
    var scanner = JsonConversionScanner{ .source = source };
    var diags: std.ArrayListUnmanaged(ValidationDiagnostic) = .empty;
    errdefer diags.deinit(gpa);

    while (scanner.nextSignificant()) |tok| {
        switch (tok.kind) {
            .single_string => try appendConfigParseDiagnostic(gpa, &diags, .{ .code = 1327 }),
            .colon => {
                const value = scanner.nextSignificant() orelse break;
                switch (value.kind) {
                    .double_string, .single_string, .open_object, .open_array, .number, .keyword_true, .keyword_false, .keyword_null => {},
                    else => try appendConfigParseDiagnostic(gpa, &diags, .{ .code = 1328 }),
                }
                if (value.kind == .single_string) {
                    try appendConfigParseDiagnostic(gpa, &diags, .{ .code = 1327 });
                }
            },
            else => {},
        }
    }
    return diags.toOwnedSlice(gpa);
}

const JsonTokenKind = enum {
    double_string,
    single_string,
    colon,
    open_object,
    open_array,
    number,
    keyword_true,
    keyword_false,
    keyword_null,
    other,
};

const JsonToken = struct {
    kind: JsonTokenKind,
};

const JsonConversionScanner = struct {
    source: []const u8,
    pos: usize = 0,

    fn nextSignificant(self: *JsonConversionScanner) ?JsonToken {
        self.skipTrivia();
        if (self.pos >= self.source.len) return null;

        const c = self.source[self.pos];
        switch (c) {
            '"' => {
                self.skipQuoted('"');
                return .{ .kind = .double_string };
            },
            '\'' => {
                self.skipQuoted('\'');
                return .{ .kind = .single_string };
            },
            ':' => {
                self.pos += 1;
                return .{ .kind = .colon };
            },
            '{' => {
                self.pos += 1;
                return .{ .kind = .open_object };
            },
            '[' => {
                self.pos += 1;
                return .{ .kind = .open_array };
            },
            '-', '0'...'9' => {
                self.skipNumber();
                return .{ .kind = .number };
            },
            't' => if (self.consumeKeyword("true")) return .{ .kind = .keyword_true },
            'f' => if (self.consumeKeyword("false")) return .{ .kind = .keyword_false },
            'n' => if (self.consumeKeyword("null")) return .{ .kind = .keyword_null },
            else => {},
        }
        self.pos += 1;
        return .{ .kind = .other };
    }

    fn skipTrivia(self: *JsonConversionScanner) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                '/' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                        self.pos += 2;
                        while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                    } else if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                        self.pos += 2;
                        while (self.pos + 1 < self.source.len) {
                            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                                self.pos += 2;
                                break;
                            }
                            self.pos += 1;
                        }
                    } else return;
                },
                else => return,
            }
        }
    }

    fn skipQuoted(self: *JsonConversionScanner, quote: u8) void {
        self.pos += 1;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            self.pos += 1;
            if (c == '\\' and self.pos < self.source.len) {
                self.pos += 1;
            } else if (c == quote) {
                break;
            }
        }
    }

    fn skipNumber(self: *JsonConversionScanner) void {
        if (self.pos < self.source.len and self.source[self.pos] == '-') self.pos += 1;
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
        }
    }

    fn consumeKeyword(self: *JsonConversionScanner, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) return false;
        self.pos += keyword.len;
        return true;
    }
};

pub fn ambiguousProjectRootDiagnostic(
    gpa: std.mem.Allocator,
    kind: PackageMapKind,
    entry: []const u8,
    file: []const u8,
) !ValidationDiagnostic {
    const code: u32 = switch (kind) {
        .exports => 2209,
        .imports => 2210,
    };
    const label = switch (kind) {
        .exports => "export",
        .imports => "import",
    };
    return .{
        .code = code,
        .message = try std.fmt.allocPrint(gpa, "The project root is ambiguous, but is required to resolve {s} map entry '{s}' in file '{s}'. Supply the `rootDir` compiler option to disambiguate.", .{ label, entry, file }),
        .owns_message = true,
        .field = "rootDir",
    };
}

pub fn moduleFormatExplanationDiagnostic(
    gpa: std.mem.Allocator,
    kind: ModuleFormatKind,
    package_json_path: []const u8,
) !ModuleFormatDiagnostic {
    return switch (kind) {
        .esm_package_json_type_module => .{
            .code = 1458,
            .message = try std.fmt.allocPrint(gpa, "File is ECMAScript module because '{s}' has field \"type\" with value \"module\"", .{package_json_path}),
            .owns_message = true,
        },
        .commonjs_package_json_type_not_module => .{
            .code = 1459,
            .message = try std.fmt.allocPrint(gpa, "File is CommonJS module because '{s}' has field \"type\" whose value is not \"module\"", .{package_json_path}),
            .owns_message = true,
        },
        .commonjs_package_json_missing_type => .{
            .code = 1460,
            .message = try std.fmt.allocPrint(gpa, "File is CommonJS module because '{s}' does not have field \"type\"", .{package_json_path}),
            .owns_message = true,
        },
        .commonjs_package_json_not_found => .{
            .code = 1461,
            .message = "File is CommonJS module because 'package.json' was not found",
        },
    };
}

pub fn moduleFormatSuggestionDiagnostic(
    gpa: std.mem.Allocator,
    kind: ModuleFormatSuggestionKind,
    extension: []const u8,
    package_json_path: []const u8,
) !ModuleFormatDiagnostic {
    return switch (kind) {
        .change_extension_or_create_package_json => .{
            .code = 1480,
            .message = try std.fmt.allocPrint(gpa, "To convert this file to an ECMAScript module, change its file extension to '{s}' or create a local package.json file.", .{extension}),
            .owns_message = true,
        },
        .change_extension_or_add_type_module => .{
            .code = 1481,
            .message = try std.fmt.allocPrint(gpa, "To convert this file to an ECMAScript module, change its file extension to '{s}' or add the field `\"type\": \"module\"` to '{s}'.", .{ extension, package_json_path }),
            .owns_message = true,
        },
        .add_type_module_to_package_json => .{
            .code = 1482,
            .message = try std.fmt.allocPrint(gpa, "To convert this file to an ECMAScript module, add the field `\"type\": \"module\"` to '{s}'.", .{package_json_path}),
            .owns_message = true,
        },
        .create_package_json_type_module => .{
            .code = 1483,
            .message = "To convert this file to an ECMAScript module, create a local package.json file with `\"type\": \"module\"`.",
        },
    };
}

pub fn freeModuleFormatDiagnostic(gpa: std.mem.Allocator, diag: ModuleFormatDiagnostic) void {
    if (diag.owns_message) gpa.free(diag.message);
}

pub fn noInputsDiagnostic(
    gpa: std.mem.Allocator,
    config_file: []const u8,
    include_paths: []const u8,
    exclude_paths: []const u8,
) !ValidationDiagnostic {
    return .{
        .code = 18003,
        .message = try std.fmt.allocPrint(gpa, "No inputs were found in config file '{s}'. Specified 'include' paths were '{s}' and 'exclude' paths were '{s}'.", .{ config_file, include_paths, exclude_paths }),
        .owns_message = true,
        .field = "files",
    };
}

pub fn projectReferenceCompositeDiagnostic(gpa: std.mem.Allocator, project: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6306,
        .message = try std.fmt.allocPrint(gpa, "Referenced project '{s}' must have setting \"composite\": true.", .{project}),
        .owns_message = true,
        .field = "references",
    };
}

pub fn projectReferenceNoEmitDiagnostic(gpa: std.mem.Allocator, project: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6310,
        .message = try std.fmt.allocPrint(gpa, "Referenced project '{s}' may not disable emit.", .{project}),
        .owns_message = true,
        .field = "references",
    };
}

pub fn outputWouldOverwriteInputDiagnostic(gpa: std.mem.Allocator, output_file: []const u8) !ValidationDiagnostic {
    return .{
        .code = 5055,
        .message = try std.fmt.allocPrint(gpa, "Cannot write file '{s}' because it would overwrite input file.", .{output_file}),
        .owns_message = true,
        .field = "emit",
    };
}

pub fn outputWouldBeOverwrittenByMultipleInputsDiagnostic(gpa: std.mem.Allocator, output_file: []const u8) !ValidationDiagnostic {
    return .{
        .code = 5056,
        .message = try std.fmt.allocPrint(gpa, "Cannot write file '{s}' because it would be overwritten by multiple input files.", .{output_file}),
        .owns_message = true,
        .field = "emit",
    };
}

pub fn rootDirContainsSourceFileDiagnostic(gpa: std.mem.Allocator, file: []const u8, root_dir: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6059,
        .message = try std.fmt.allocPrint(gpa, "File '{s}' is not under 'rootDir' '{s}'. 'rootDir' is expected to contain all source files.", .{ file, root_dir }),
        .owns_message = true,
        .field = "rootDir",
    };
}

pub fn projectReferenceOutputNotBuiltDiagnostic(gpa: std.mem.Allocator, output_file: []const u8, source_file: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6305,
        .message = try std.fmt.allocPrint(gpa, "Output file '{s}' has not been built from source file '{s}'.", .{ output_file, source_file }),
        .owns_message = true,
        .field = "references",
    };
}

pub fn projectFileListDiagnostic(gpa: std.mem.Allocator, file: []const u8, project: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6307,
        .message = try std.fmt.allocPrint(gpa, "File '{s}' is not listed within the file list of project '{s}'. Projects must list all files or use an 'include' pattern.", .{ file, project }),
        .owns_message = true,
        .field = "files",
    };
}

pub fn referencedBuildInfoOverwriteDiagnostic(gpa: std.mem.Allocator, build_info_file: []const u8, referenced_project: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6377,
        .message = try std.fmt.allocPrint(gpa, "Cannot write file '{s}' because it will overwrite '.tsbuildinfo' file generated by referenced project '{s}'", .{ build_info_file, referenced_project }),
        .owns_message = true,
        .field = "tsBuildInfoFile",
    };
}

pub fn arbitraryExtensionImportDiagnostic(gpa: std.mem.Allocator, module_name: []const u8, resolved_file: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6263,
        .message = try std.fmt.allocPrint(gpa, "Module '{s}' was resolved to '{s}', but '--allowArbitraryExtensions' is not set.", .{ module_name, resolved_file }),
        .owns_message = true,
        .field = "allowArbitraryExtensions",
    };
}

pub fn jsxModuleResolutionDiagnostic(gpa: std.mem.Allocator, module_name: []const u8, resolved_file: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6142,
        .message = try std.fmt.allocPrint(gpa, "Module '{s}' was resolved to '{s}', but '--jsx' is not set.", .{ module_name, resolved_file }),
        .owns_message = true,
        .field = "jsx",
    };
}

pub fn unresolvedPathWithExtensionsDiagnostic(gpa: std.mem.Allocator, path: []const u8, extensions: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6231,
        .message = try std.fmt.allocPrint(gpa, "Could not resolve the path '{s}' with the extensions: {s}.", .{ path, extensions }),
        .owns_message = true,
        .field = "files",
    };
}

pub fn jsFileRequiresAllowJsDiagnostic(gpa: std.mem.Allocator, file: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6504,
        .message = try std.fmt.allocPrint(gpa, "File '{s}' is a JavaScript file. Did you mean to enable the 'allowJs' option?", .{file}),
        .owns_message = true,
        .field = "allowJs",
    };
}

pub fn moduleResolutionStartDiagnostic(gpa: std.mem.Allocator, module_name: []const u8, from_file: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6086,
        .message = try std.fmt.allocPrint(gpa, "======== Resolving module '{s}' from '{s}'. ========", .{ module_name, from_file }),
        .owns_message = true,
        .field = "traceResolution",
    };
}

pub fn projectReferenceCycleDiagnostic(gpa: std.mem.Allocator, cycle: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6202,
        .message = try std.fmt.allocPrint(gpa, "Project references may not form a circular graph. Cycle detected: {s}", .{cycle}),
        .owns_message = true,
        .field = "references",
    };
}

pub fn projectReferenceRedirectDiagnostic(gpa: std.mem.Allocator, project: []const u8) !ValidationDiagnostic {
    return .{
        .code = 6215,
        .message = try std.fmt.allocPrint(gpa, "Using compiler options of project reference redirect '{s}'.", .{project}),
        .owns_message = true,
        .field = "references",
    };
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

fn levenshteinIcase(a: []const u8, b: []const u8) usize {
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

fn fillCompilerOptions(arena: std.mem.Allocator, co: *CompilerOptions, obj: jsonc.Value.Object) !void {
    var i: usize = 0;
    while (i < obj.keys.len) : (i += 1) {
        const key = obj.keys[i];
        const value = obj.values[i];
        if (findOptionSpec(&compiler_option_specs, key)) |spec| {
            if (!spec.kind.matches(value)) continue;
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
            .{ .name = "skipLibCheck", .field = "skip_lib_check" },
            .{ .name = "skipDefaultLibCheck", .field = "skip_default_lib_check" },
            .{ .name = "forceConsistentCasingInFileNames", .field = "force_consistent_casing_in_file_names" },
            .{ .name = "keyofStringsOnly", .field = "keyof_strings_only" },
            .{ .name = "suppressExcessPropertyErrors", .field = "suppress_excess_property_errors" },
            .{ .name = "suppressImplicitAnyIndexErrors", .field = "suppress_implicit_any_index_errors" },
            .{ .name = "noImplicitUseStrict", .field = "no_implicit_use_strict" },
            .{ .name = "noStrictGenericChecks", .field = "no_strict_generic_checks" },
            .{ .name = "allowSyntheticDefaultImports", .field = "allow_synthetic_default_imports" },
            .{ .name = "preserveValueImports", .field = "preserve_value_imports" },
            .{ .name = "preserveSymlinks", .field = "preserve_symlinks" },
            .{ .name = "allowUmdGlobalAccess", .field = "allow_umd_global_access" },
            .{ .name = "allowArbitraryExtensions", .field = "allow_arbitrary_extensions" },
            .{ .name = "noUncheckedSideEffectImports", .field = "no_unchecked_side_effect_imports" },
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
            .{ .name = "noCheck", .field = "no_check" },
            .{ .name = "erasableSyntaxOnly", .field = "erasable_syntax_only" },
            .{ .name = "libReplacement", .field = "lib_replacement" },
            .{ .name = "strictBuiltinIteratorReturn", .field = "strict_builtin_iterator_return" },
            .{ .name = "stableTypeOrdering", .field = "stable_type_ordering" },
            .{ .name = "noErrorTruncation", .field = "no_error_truncation" },
            .{ .name = "noResolve", .field = "no_resolve" },
            .{ .name = "stripInternal", .field = "strip_internal" },
            .{ .name = "emitBOM", .field = "emit_bom" },
            .{ .name = "noEmitOnError", .field = "no_emit_on_error" },
            .{ .name = "allowUnusedLabels", .field = "allow_unused_labels" },
            .{ .name = "allowUnreachableCode", .field = "allow_unreachable_code" },
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
            .{ .name = "outFile", .field = "out_file" },
            .{ .name = "out", .field = "out" },
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
            .{ .name = "importsNotUsedAsValues", .field = "imports_not_used_as_values" },
            .{ .name = "moduleDetection", .field = "module_detection" },
            .{ .name = "ignoreDeprecations", .field = "ignore_deprecations" },
            .{ .name = "charset", .field = "charset" },
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
        if (std.mem.eql(u8, key, "customConditions")) {
            co.custom_conditions = try parseStringArray(arena, value);
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
            const raw_substitution_counts = try arena.alloc(usize, npats);
            for (obj_v.keys, 0..) |pk, idx| {
                patterns[idx] = pk;
                const arr = obj_v.values[idx].asArray() orelse {
                    substitutions[idx] = &.{};
                    raw_substitution_counts[idx] = 1;
                    continue;
                };
                raw_substitution_counts[idx] = arr.len;
                const subs = try arena.alloc([]const u8, arr.len);
                var n: usize = 0;
                for (arr) |s| {
                    if (s.asString()) |subst| {
                        subs[n] = subst;
                        n += 1;
                    }
                }
                substitutions[idx] = subs[0..n];
            }
            co.paths = .{ .patterns = patterns, .substitutions = substitutions, .raw_substitution_counts = raw_substitution_counts };
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
    if (child.unknown_type_acquisition_options.len > 0) {
        merged.unknown_type_acquisition_options = child.unknown_type_acquisition_options;
    }
    if (child.compiler_option_parse_diagnostics.len > 0) {
        merged.compiler_option_parse_diagnostics = child.compiler_option_parse_diagnostics;
    }
    if (child.watch_option_parse_diagnostics.len > 0) {
        merged.watch_option_parse_diagnostics = child.watch_option_parse_diagnostics;
    }
    if (child.config_parse_diagnostics.len > 0) {
        merged.config_parse_diagnostics = child.config_parse_diagnostics;
    }
    merged.has_extends = base.has_extends or child.has_extends;
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

test "tsconfig: noEmit + skipLibCheck + outFile" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "noEmit": true, "skipLibCheck": true, "outFile": "bundle.js" } }
    );
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.no_emit);
    try t.expectEqual(@as(?bool, true), cfg.compiler_options.skip_lib_check);
    try t.expectEqualStrings("bundle.js", cfg.compiler_options.out_file.?);
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

test "tsconfig.validate: compiler option table reports TS5023 TS5024 and TS5025" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "noEmt": true,
        \\    "futureFlag": true,
        \\    "strict": "yes"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 5025), diags[0].code);
    try t.expectEqualStrings("Unknown compiler option 'noEmt'. Did you mean 'noEmit'?", diags[0].message);
    try t.expectEqual(@as(u32, 5023), diags[1].code);
    try t.expectEqualStrings("Unknown compiler option 'futureFlag'.", diags[1].message);
    try t.expectEqual(@as(u32, 5024), diags[2].code);
    try t.expectEqualStrings("Compiler option 'strict' requires a value of type boolean.", diags[2].message);
}

test "tsconfig.validate: command-line-only compiler options report TS6266" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "showConfig": true,
        \\    "listFilesOnly": true,
        \\    "ignoreConfig": true,
        \\    "watch": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 4), diags.len);
    try t.expectEqual(@as(u32, 6266), diags[0].code);
    try t.expectEqualStrings("Option 'showConfig' can only be specified on command line.", diags[0].message);
    try t.expectEqualStrings("showConfig", diags[0].field);
    try t.expectEqual(@as(u32, 6266), diags[1].code);
    try t.expectEqualStrings("listFilesOnly", diags[1].field);
    try t.expectEqual(@as(u32, 6266), diags[2].code);
    try t.expectEqualStrings("ignoreConfig", diags[2].field);
    try t.expectEqual(@as(u32, 6266), diags[3].code);
    try t.expectEqualStrings("watch", diags[3].field);
}

test "tsconfig.validate: watchOptions reports TS5078 TS5079 and TS5080" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "watchOptions": {
        \\    "watchFyle": "usefsevents",
        \\    "watchMagic": true,
        \\    "excludeFiles": "dist/**/*.ts"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 5079), diags[0].code);
    try t.expectEqualStrings("Unknown watch option 'watchFyle'. Did you mean 'watchFile'?", diags[0].message);
    try t.expectEqual(@as(u32, 5078), diags[1].code);
    try t.expectEqualStrings("Unknown watch option 'watchMagic'.", diags[1].message);
    try t.expectEqual(@as(u32, 5080), diags[2].code);
    try t.expectEqualStrings("Watch option 'excludeFiles' requires a value of type Array.", diags[2].message);
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
        \\    "verbatimModuleSyntax": true,
        \\    "allowArbitraryExtensions": true,
        \\    "noUncheckedSideEffectImports": true,
        \\    "preserveSymlinks": true,
        \\    "allowUmdGlobalAccess": true,
        \\    "noCheck": true,
        \\    "erasableSyntaxOnly": true,
        \\    "libReplacement": true,
        \\    "strictBuiltinIteratorReturn": true,
        \\    "stableTypeOrdering": true,
        \\    "noErrorTruncation": true,
        \\    "noResolve": true,
        \\    "stripInternal": true,
        \\    "emitBOM": true,
        \\    "noEmitOnError": true,
        \\    "allowUnusedLabels": true,
        \\    "allowUnreachableCode": true
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
    try t.expectEqual(@as(?bool, true), co.allow_arbitrary_extensions);
    try t.expectEqual(@as(?bool, true), co.no_unchecked_side_effect_imports);
    try t.expectEqual(@as(?bool, true), co.preserve_symlinks);
    try t.expectEqual(@as(?bool, true), co.allow_umd_global_access);
    try t.expectEqual(@as(?bool, true), co.no_check);
    try t.expectEqual(@as(?bool, true), co.erasable_syntax_only);
    try t.expectEqual(@as(?bool, true), co.lib_replacement);
    try t.expectEqual(@as(?bool, true), co.strict_builtin_iterator_return);
    try t.expectEqual(@as(?bool, true), co.stable_type_ordering);
    try t.expectEqual(@as(?bool, true), co.no_error_truncation);
    try t.expectEqual(@as(?bool, true), co.no_resolve);
    try t.expectEqual(@as(?bool, true), co.strip_internal);
    try t.expectEqual(@as(?bool, true), co.emit_bom);
    try t.expectEqual(@as(?bool, true), co.no_emit_on_error);
    try t.expectEqual(@as(?bool, true), co.allow_unused_labels);
    try t.expectEqual(@as(?bool, true), co.allow_unreachable_code);
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

test "tsconfig: compiler option message diagnostics mirror upstream help text codes" {
    const show_config = compilerOptionMessageDiagnostic("showConfig").?;
    try t.expectEqual(@as(u32, 1350), show_config.code);
    try t.expectEqualStrings("Print the final configuration instead of building.", show_config.message);

    const preserve_value_imports = compilerOptionMessageDiagnostic("preserveValueImports").?;
    try t.expectEqual(@as(u32, 1449), preserve_value_imports.code);
    try t.expectEqualStrings("Preserve unused imported values in the JavaScript output that would otherwise be removed.", preserve_value_imports.message);

    const module_detection = compilerOptionMessageDiagnostic("moduleDetection").?;
    try t.expectEqual(@as(u32, 1475), module_detection.code);
    const module_detection_default = compilerOptionMessageDiagnostic("moduleDetection.default").?;
    try t.expectEqual(@as(u32, 1476), module_detection_default.code);

    const jsx_fragment_factory = compilerOptionMessageDiagnostic("jsxFragmentFactory").?;
    try t.expectEqual(@as(u32, 18034), jsx_fragment_factory.code);
    try t.expect(compilerOptionMessageDiagnostic("unknownOption") == null);
}

test "tsconfig: file include diagnostics cover import and reference reasons" {
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .import = .{
                .text = "\"./dep\"",
                .from_file = "/repo/src/main.ts",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1393), diag.code);
        try t.expectEqualStrings("Imported via \"./dep\" from file '/repo/src/main.ts'", diag.message);
        try t.expectEqual(@as(?u32, 1399), diag.related_code);
        try t.expectEqualStrings("File is included via import here.", diag.related_message.?);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .import = .{
                .text = "\"tslib\"",
                .from_file = "/repo/src/main.ts",
                .package_id = "tslib/index.d.ts@2.6.2",
                .synthetic_kind = .import_helpers,
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1396), diag.code);
        try t.expectEqualStrings("Imported via \"tslib\" from file '/repo/src/main.ts' with packageId 'tslib/index.d.ts@2.6.2' to import 'importHelpers' as specified in compilerOptions", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .import = .{
                .text = "\"react/jsx-runtime\"",
                .from_file = "/repo/src/view.tsx",
                .synthetic_kind = .jsx_factory,
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1397), diag.code);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .reference_file = .{
                .text = "./types.d.ts",
                .from_file = "/repo/src/main.ts",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1400), diag.code);
        try t.expectEqual(@as(?u32, 1401), diag.related_code);
        try t.expectEqualStrings("Referenced via './types.d.ts' from file '/repo/src/main.ts'", diag.message);
    }
}

test "tsconfig: file include diagnostics cover type, lib, root, and project reasons" {
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .type_reference_directive = .{
                .text = "node",
                .from_file = "/repo/src/main.ts",
                .package_id = "@types/node/index.d.ts@20.0.0",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1403), diag.code);
        try t.expectEqual(@as(?u32, 1404), diag.related_code);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .lib_reference_directive = .{
                .text = "dom",
                .from_file = "/repo/src/main.ts",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1405), diag.code);
        try t.expectEqual(@as(?u32, 1406), diag.related_code);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .root_file = .{ .include_pattern = .{
                .pattern = "src/**/*",
                .config_file = "/repo/tsconfig.json",
            } },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1407), diag.code);
        try t.expectEqual(@as(?u32, 1408), diag.related_code);
        try t.expectEqualStrings("Matched by include pattern 'src/**/*' in '/repo/tsconfig.json'", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{ .root_file = .files_list });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1409), diag.code);
        try t.expectEqual(@as(?u32, 1410), diag.related_code);
        try t.expectEqualStrings("Part of 'files' list in tsconfig.json", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .output_from_project_reference = .{
                .project = "../lib/tsconfig.json",
                .option = "--outFile",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1411), diag.code);
        try t.expectEqual(@as(?u32, 1413), diag.related_code);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .source_from_project_reference = .{
                .project = "../lib/tsconfig.json",
                .option = "--module=none",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1415), diag.code);
        try t.expectEqual(@as(?u32, 1416), diag.related_code);
    }
}

test "tsconfig: file include diagnostics cover type-library and library entry points" {
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .automatic_type_directive_file = .{
                .type_reference = "node",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1417), diag.code);
        try t.expectEqualStrings("Entry point of type library 'node' specified in compilerOptions", diag.message);
        try t.expectEqual(@as(?u32, 1419), diag.related_code);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .automatic_type_directive_file = .{
                .type_reference = "node",
                .package_id = "@types/node/index.d.ts@20.0.0",
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1418), diag.code);
        try t.expectEqualStrings("Entry point of type library 'node' specified in compilerOptions with packageId '@types/node/index.d.ts@20.0.0'", diag.message);
        try t.expectEqual(@as(?u32, 1419), diag.related_code);
        try t.expectEqualStrings("File is entry point of type library specified here.", diag.related_message.?);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .automatic_type_directive_file = .{
                .type_reference = "jest",
                .implicit = true,
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1420), diag.code);
        try t.expectEqualStrings("Entry point for implicit type library 'jest'", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .automatic_type_directive_file = .{
                .type_reference = "react",
                .package_id = "@types/react/index.d.ts@18.2.0",
                .implicit = true,
            },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1421), diag.code);
        try t.expectEqualStrings("Entry point for implicit type library 'react' with packageId '@types/react/index.d.ts@18.2.0'", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .lib_file = .{ .specified = "dom" },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1422), diag.code);
        try t.expectEqualStrings("Library 'dom' specified in compilerOptions", diag.message);
        try t.expectEqual(@as(?u32, 1423), diag.related_code);
    }
}

test "tsconfig: module-resolution helper diagnostics cover TS2209 and TS2210" {
    {
        const diag = try ambiguousProjectRootDiagnostic(t.allocator, .exports, ".", "package.json");
        defer if (diag.owns_message) t.allocator.free(diag.message);
        try t.expectEqual(@as(u32, 2209), diag.code);
        try t.expectEqualStrings("The project root is ambiguous, but is required to resolve export map entry '.' in file 'package.json'. Supply the `rootDir` compiler option to disambiguate.", diag.message);
        try t.expectEqualStrings("rootDir", diag.field);
    }
    {
        const diag = try ambiguousProjectRootDiagnostic(t.allocator, .imports, "#dep", "package.json");
        defer if (diag.owns_message) t.allocator.free(diag.message);
        try t.expectEqual(@as(u32, 2210), diag.code);
        try t.expectEqualStrings("The project root is ambiguous, but is required to resolve import map entry '#dep' in file 'package.json'. Supply the `rootDir` compiler option to disambiguate.", diag.message);
    }
}

test "tsconfig: module-format explanation and suggestion diagnostics mirror upstream codes" {
    {
        const diag = try moduleFormatExplanationDiagnostic(t.allocator, .esm_package_json_type_module, "/repo/package.json");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1458), diag.code);
        try t.expectEqualStrings("File is ECMAScript module because '/repo/package.json' has field \"type\" with value \"module\"", diag.message);
    }
    {
        const diag = try moduleFormatExplanationDiagnostic(t.allocator, .commonjs_package_json_type_not_module, "/repo/package.json");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1459), diag.code);
    }
    {
        const diag = try moduleFormatExplanationDiagnostic(t.allocator, .commonjs_package_json_missing_type, "/repo/package.json");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1460), diag.code);
    }
    {
        const diag = try moduleFormatExplanationDiagnostic(t.allocator, .commonjs_package_json_not_found, "");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1461), diag.code);
        try t.expectEqualStrings("File is CommonJS module because 'package.json' was not found", diag.message);
    }
    {
        const diag = try moduleFormatSuggestionDiagnostic(t.allocator, .change_extension_or_create_package_json, ".mts", "");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1480), diag.code);
    }
    {
        const diag = try moduleFormatSuggestionDiagnostic(t.allocator, .change_extension_or_add_type_module, ".mts", "/repo/package.json");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1481), diag.code);
    }
    {
        const diag = try moduleFormatSuggestionDiagnostic(t.allocator, .add_type_module_to_package_json, "", "/repo/package.json");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1482), diag.code);
    }
    {
        const diag = try moduleFormatSuggestionDiagnostic(t.allocator, .create_package_json_type_module, "", "");
        defer freeModuleFormatDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1483), diag.code);
    }
}

test "tsconfig: file include diagnostics cover default roots, redirects, and casing" {
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .root_file = .specified_for_compilation,
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1427), diag.code);
        try t.expectEqualStrings("Root file specified for compilation", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .root_file = .default_include_pattern,
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1457), diag.code);
        try t.expectEqualStrings("Matched by default include pattern '**/*'", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .lib_file = .default_library,
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1424), diag.code);
        try t.expectEqualStrings("Default library", diag.message);
    }
    {
        const diag = try fileIncludeReasonToDiagnostic(t.allocator, .{
            .lib_file = .{ .default_library_for_target = "es2024" },
        });
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1425), diag.code);
        try t.expectEqualStrings("Default library for target 'es2024'", diag.message);
        try t.expectEqual(@as(?u32, 1426), diag.related_code);
    }
    {
        const diag = try projectReferenceSourceOutputDiagnostic(t.allocator, "/repo/src/main.ts");
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1428), diag.code);
        try t.expectEqualStrings("File is output of project reference source '/repo/src/main.ts'", diag.message);
    }
    {
        const diag = try fileRedirectDiagnostic(t.allocator, "/repo/dist/main.d.ts");
        defer freeFileIncludeDiagnostic(t.allocator, diag);
        try t.expectEqual(@as(u32, 1429), diag.code);
        try t.expectEqualStrings("File redirects to file '/repo/dist/main.d.ts'", diag.message);
    }
    {
        const diag = fileProgramReasonHeaderDiagnostic();
        try t.expectEqual(@as(u32, 1430), diag.code);
        try t.expectEqualStrings("The file is in the program because:", diag.message);
    }
    {
        const diag = try fileNameCasingDiagnostic(t.allocator, "/repo/src/foo.ts", "/repo/src/Foo.ts", false);
        defer if (diag.owns_message) t.allocator.free(diag.message);
        try t.expectEqual(@as(u32, 1149), diag.code);
        try t.expectEqualStrings("File name '/repo/src/foo.ts' differs from already included file name '/repo/src/Foo.ts' only in casing.", diag.message);
    }
    {
        const diag = try fileNameCasingDiagnostic(t.allocator, "/repo/src/foo.ts", "/repo/src/Foo.ts", true);
        defer if (diag.owns_message) t.allocator.free(diag.message);
        try t.expectEqual(@as(u32, 1261), diag.code);
        try t.expectEqualStrings("Already included file name '/repo/src/Foo.ts' differs from file name '/repo/src/foo.ts' only in casing.", diag.message);
    }
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
        \\    "suppressImplicitAnyIndexErrors": true,
        \\    "noImplicitUseStrict": true,
        \\    "noStrictGenericChecks": true,
        \\    "preserveValueImports": true,
        \\    "importsNotUsedAsValues": "preserve",
        \\    "charset": "utf8",
        \\    "out": "legacy.js"
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
    try t.expectEqual(@as(?bool, true), co.no_implicit_use_strict);
    try t.expectEqual(@as(?bool, true), co.no_strict_generic_checks);
    try t.expectEqual(@as(?bool, true), co.preserve_value_imports);
    try t.expectEqualStrings("preserve", co.imports_not_used_as_values.?);
    try t.expectEqualStrings("utf8", co.charset.?);
    try t.expectEqualStrings("legacy.js", co.out.?);
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

test "tsconfig.validate: incremental outside config reports TS5074 unless build info or outFile is present" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    {
        const cfg = try parseString(t.allocator, arena.allocator(),
            \\{ "compilerOptions": { "incremental": true } }
        );
        const diags = try cfg.validate(t.allocator);
        defer freeValidationDiagnostics(t.allocator, diags);
        try t.expectEqual(@as(usize, 1), diags.len);
        try t.expectEqual(@as(u32, 5074), diags[0].code);
        try t.expectEqualStrings("incremental", diags[0].field);
    }
    {
        var cfg = try parseString(t.allocator, arena.allocator(),
            \\{ "compilerOptions": { "incremental": true } }
        );
        cfg.file_path = "/repo/tsconfig.json";
        const diags = try cfg.validate(t.allocator);
        defer freeValidationDiagnostics(t.allocator, diags);
        try t.expectEqual(@as(usize, 0), diags.len);
    }
    {
        const cfg = try parseString(t.allocator, arena.allocator(),
            \\{ "compilerOptions": { "incremental": true, "tsBuildInfoFile": ".cache/build.tsbuildinfo" } }
        );
        const diags = try cfg.validate(t.allocator);
        defer freeValidationDiagnostics(t.allocator, diags);
        try t.expectEqual(@as(usize, 0), diags.len);
    }
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

test "tsconfig: project references keep typed metadata and validate reference.path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "references": [
        \\    { "path": "./pkg-a", "prepend": true, "circular": true },
        \\    { "path": 123 },
        \\    { "prepend": true }
        \\  ]
        \\}
    );
    try t.expectEqual(@as(usize, 1), cfg.references.len);
    try t.expectEqualStrings("./pkg-a", cfg.references[0].path);
    try t.expect(cfg.references[0].prepend);
    try t.expect(cfg.references[0].circular);

    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 5024), diags[0].code);
    try t.expectEqualStrings("Compiler option 'reference.path' requires a value of type string.", diags[0].message);
    try t.expectEqual(@as(u32, 5024), diags[1].code);
    try t.expectEqual(@as(u32, 5102), diags[2].code);
    try t.expectEqualStrings("Option 'prepend' has been removed. Please remove it from your configuration.", diags[2].message);
    try t.expectEqualStrings("references", diags[2].field);
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

test "tsconfig.validate: paths reports TS5063 and TS5064 for malformed substitutions" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "paths": {
        \\      "not-array": "src/*",
        \\      "bad-types/*": [false, 1, null, "ok/*"]
        \\    }
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 5), diags.len);
    try t.expectEqual(@as(u32, 5063), diags[0].code);
    try t.expectEqualStrings("Substitutions for pattern 'not-array' should be an array.", diags[0].message);
    try t.expectEqual(@as(u32, 5064), diags[1].code);
    try t.expectEqualStrings("Substitution 'false' for pattern 'bad-types/*' has incorrect type, expected 'string', got 'boolean'.", diags[1].message);
    try t.expectEqual(@as(u32, 5064), diags[2].code);
    try t.expectEqualStrings("Substitution '1' for pattern 'bad-types/*' has incorrect type, expected 'string', got 'number'.", diags[2].message);
    try t.expectEqual(@as(u32, 5064), diags[3].code);
    try t.expectEqualStrings("Substitution 'null' for pattern 'bad-types/*' has incorrect type, expected 'string', got 'object'.", diags[3].message);
    try t.expectEqual(@as(u32, 5090), diags[4].code);
}

test "tsconfig.validate: include and exclude file specs report TS5010 and TS5065" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "include": ["**", "src/**", "**/../*", "**/y/../*"],
        \\  "exclude": ["dist/**", "**/.."]
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 6), diags.len);
    try t.expectEqual(@as(u32, 5010), diags[0].code);
    try t.expectEqualStrings("File specification cannot end in a recursive directory wildcard ('**'): '**'.", diags[0].message);
    try t.expectEqualStrings("include", diags[0].field);
    try t.expectEqual(@as(u32, 5010), diags[1].code);
    try t.expectEqualStrings("File specification cannot end in a recursive directory wildcard ('**'): 'src/**'.", diags[1].message);
    try t.expectEqual(@as(u32, 5065), diags[2].code);
    try t.expectEqualStrings("File specification cannot contain a parent directory ('..') that appears after a recursive directory wildcard ('**'): '**/../*'.", diags[2].message);
    try t.expectEqual(@as(u32, 5065), diags[3].code);
    try t.expectEqualStrings("File specification cannot contain a parent directory ('..') that appears after a recursive directory wildcard ('**'): '**/y/../*'.", diags[3].message);
    try t.expectEqual(@as(u32, 5010), diags[4].code);
    try t.expectEqualStrings("exclude", diags[4].field);
    try t.expectEqual(@as(u32, 5065), diags[5].code);
    try t.expectEqualStrings("exclude", diags[5].field);
}

test "tsconfig.validate: clean include and exclude globs do not report recursive wildcard diagnostics" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "include": ["src/**/*", "types/**/index.d.ts"],
        \\  "exclude": ["dist", "../shared", "**/*.generated.ts"]
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: root value diagnostic reports TS5092" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const diags = try parseRootValueDiagnostics(t.allocator, arena.allocator(),
        \\["not", "an", "object"]
    , "tsconfig.json");
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5092), diags[0].code);
    try t.expectEqualStrings("The root value of a 'tsconfig.json' file must be an object.", diags[0].message);
}

test "tsconfig.validate: object root value has no TS5092 diagnostic" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const diags = try parseRootValueDiagnostics(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "strict": true } }
    , "tsconfig.json");
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: JSON conversion diagnostics report TS1327 and TS1328" {
    const diags = try parseJsonConversionDiagnostics(t.allocator,
        \\{
        \\  'compilerOptions': {
        \\    "target": 'es2024',
        \\    "strict": maybe,
        \\    "noEmit": true
        \\  }
        \\}
    );
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 1327), diags[0].code);
    try t.expectEqualStrings("String literal with double quotes expected.", diags[0].message);
    try t.expectEqual(@as(u32, 1327), diags[1].code);
    try t.expectEqual(@as(u32, 1328), diags[2].code);
    try t.expectEqualStrings("Property value can only be string literal, numeric literal, 'true', 'false', 'null', object literal or array literal.", diags[2].message);
}

test "tsconfig.validate: JSON conversion accepts valid JSON values" {
    const diags = try parseJsonConversionDiagnostics(t.allocator,
        \\{
        \\  "compilerOptions": {
        \\    "strict": true,
        \\    "target": "es2024",
        \\    "plugins": [{ "name": "typed" }],
        \\    "disableSizeLimit": false,
        \\    "maxNodeModuleJsDepth": 2,
        \\    "jsxImportSource": null
        \\  }
        \\}
    );
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: root excludes and misplaced compiler option report TS6114 and TS6258" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "excludes": ["dist"],
        \\  "strict": true
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), diags.len);
    try t.expectEqual(@as(u32, 6114), diags[0].code);
    try t.expectEqualStrings("Unknown option 'excludes'. Did you mean 'exclude'?", diags[0].message);
    try t.expectEqualStrings("excludes", diags[0].field);
    try t.expectEqual(@as(u32, 6258), diags[1].code);
    try t.expectEqualStrings("'strict' should be set inside the 'compilerOptions' object of the config json file", diags[1].message);
    try t.expectEqualStrings("strict", diags[1].field);
}

test "tsconfig.validate: root compiler option is tolerated when compilerOptions exists" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "strict": true,
        \\  "compilerOptions": {
        \\    "strict": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
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
    try t.expectEqual(@as(usize, 0), diags.len);
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

test "tsconfig.validate: TS6 removed compiler options report TS5102 and TS5108" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "target": "es3",
        \\    "noImplicitUseStrict": true,
        \\    "keyofStringsOnly": true,
        \\    "suppressExcessPropertyErrors": true,
        \\    "suppressImplicitAnyIndexErrors": true,
        \\    "noStrictGenericChecks": true,
        \\    "charset": "utf8",
        \\    "out": "legacy.js",
        \\    "importsNotUsedAsValues": "preserve",
        \\    "preserveValueImports": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 10), diags.len);
    try t.expectEqual(@as(u32, 5108), diags[0].code);
    try t.expectEqualStrings("target", diags[0].field);
    try t.expectEqualStrings("Option 'target=ES3' has been removed. Please remove it from your configuration.", diags[0].message);
    const expected_fields = [_][]const u8{
        "noImplicitUseStrict",
        "keyofStringsOnly",
        "suppressExcessPropertyErrors",
        "suppressImplicitAnyIndexErrors",
        "noStrictGenericChecks",
        "charset",
        "out",
        "importsNotUsedAsValues",
        "preserveValueImports",
    };
    for (expected_fields, 1..) |field, i| {
        try t.expectEqual(@as(u32, 5102), diags[i].code);
        try t.expectEqualStrings(field, diags[i].field);
    }
}

test "tsconfig.validate: custom string options report TS6046 for unsupported values" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "moduleDetection": "maybe",
        \\    "importsNotUsedAsValues": "panic"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 6046), diags[0].code);
    try t.expectEqualStrings("moduleDetection", diags[0].field);
    try t.expectEqualStrings("Argument for '--moduleDetection' option must be: 'auto', 'legacy', 'force'.", diags[0].message);
    try t.expectEqual(@as(u32, 6046), diags[1].code);
    try t.expectEqualStrings("importsNotUsedAsValues", diags[1].field);
    try t.expectEqualStrings("Argument for '--importsNotUsedAsValues' option must be: 'remove', 'preserve', 'error'.", diags[1].message);
    try t.expectEqual(@as(u32, 5102), diags[2].code);
    try t.expectEqualStrings("importsNotUsedAsValues", diags[2].field);
}

test "tsconfig.validate: isolatedModules reports TS5047 for module none below ES2015" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "isolatedModules": true, "module": "none", "target": "es5" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5047), diags[0].code);
    try t.expectEqualStrings("isolatedModules", diags[0].field);
    try t.expectEqualStrings("Option 'isolatedModules' can only be used when either option '--module' is provided or option 'target' is 'ES2015' or higher.", diags[0].message);
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
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "node20", "moduleResolution": "classic" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 5109), diags[0].code);
    try t.expectEqualStrings("moduleResolution", diags[0].field);
    try t.expectEqualStrings("Option 'moduleResolution' must be set to 'Node16' (or left unspecified) when option 'module' is set to 'Node20'.", diags[0].message);
}

test "tsconfig.validate: bundler moduleResolution reports TS5095 for incompatible module" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "module": "system", "moduleResolution": "bundler" } }
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
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 5098), diags[0].code);
    try t.expectEqualStrings("Option 'resolvePackageJsonExports' can only be used when 'moduleResolution' is set to 'node16', 'nodenext', or 'bundler'.", diags[0].message);
    try t.expectEqual(@as(u32, 5098), diags[1].code);
    try t.expectEqualStrings("Option 'resolvePackageJsonImports' can only be used when 'moduleResolution' is set to 'node16', 'nodenext', or 'bundler'.", diags[1].message);
    try t.expectEqual(@as(u32, 5098), diags[2].code);
    try t.expectEqualStrings("Option 'customConditions' can only be used when 'moduleResolution' is set to 'node16', 'nodenext', or 'bundler'.", diags[2].message);
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
        \\    "noEmit": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
    try t.expectEqualStrings("home", cfg.compiler_options.custom_conditions.?[0]);
}

test "tsconfig.validate: rewriteRelativeImportExtensions alone satisfies TS5096 gate" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "rewriteRelativeImportExtensions": true } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "tsconfig.validate: outFile reports TS6082 for non-bundling modules" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "outFile": "bundle.js", "module": "commonjs" } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), diags.len);
    try t.expectEqual(@as(u32, 6082), diags[0].code);
    try t.expectEqualStrings("outFile", diags[0].field);
    try t.expectEqualStrings("Only 'amd' and 'system' modules are supported alongside --outFile.", diags[0].message);
    try t.expectEqual(@as(u32, 6082), diags[1].code);
    try t.expectEqualStrings("module", diags[1].field);
    try t.expectEqualStrings("Only 'amd' and 'system' modules are supported alongside --module.", diags[1].message);
}

test "tsconfig.validate: outFile accepts amd system and implicit module" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const amd = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "outFile": "bundle.js", "module": "amd" } }
    );
    const amd_diags = try amd.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, amd_diags);
    try t.expectEqual(@as(usize, 0), amd_diags.len);

    const system = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "outFile": "bundle.js", "module": "system" } }
    );
    const system_diags = try system.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, system_diags);
    try t.expectEqual(@as(usize, 0), system_diags.len);

    const implicit = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "outFile": "bundle.js" } }
    );
    const implicit_diags = try implicit.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, implicit_diags);
    try t.expectEqual(@as(usize, 0), implicit_diags.len);
}

test "tsconfig.validate: outFile declarationDir and lib conflicts report TS5053" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "outFile": "bundle.js",
        \\    "isolatedModules": true,
        \\    "declaration": true,
        \\    "declarationDir": "types",
        \\    "lib": ["es2024"],
        \\    "noLib": true
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqual(@as(u32, 5053), diags[0].code);
    try t.expectEqualStrings("Option 'outFile' cannot be specified with option 'isolatedModules'.", diags[0].message);
    try t.expectEqual(@as(u32, 5053), diags[1].code);
    try t.expectEqualStrings("Option 'declarationDir' cannot be specified with option 'outFile'.", diags[1].message);
    try t.expectEqual(@as(u32, 5053), diags[2].code);
    try t.expectEqualStrings("Option 'lib' cannot be specified with option 'noLib'.", diags[2].message);
}

test "tsconfig.validate: inlineSourceMap companion conflicts report TS5053" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{
        \\  "compilerOptions": {
        \\    "inlineSourceMap": true,
        \\    "sourceMap": true,
        \\    "mapRoot": "maps"
        \\  }
        \\}
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 2), diags.len);
    try t.expectEqual(@as(u32, 5053), diags[0].code);
    try t.expectEqualStrings("Option 'sourceMap' cannot be specified with option 'inlineSourceMap'.", diags[0].message);
    try t.expectEqual(@as(u32, 5053), diags[1].code);
    try t.expectEqualStrings("Option 'mapRoot' cannot be specified with option 'inlineSourceMap'.", diags[1].message);
}

test "tsconfig.validate: composite with incremental false reports TS6379" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseString(t.allocator, arena.allocator(),
        \\{ "compilerOptions": { "composite": true, "incremental": false } }
    );
    const diags = try cfg.validate(t.allocator);
    defer freeValidationDiagnostics(t.allocator, diags);
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(u32, 6379), diags[0].code);
    try t.expectEqualStrings("incremental", diags[0].field);
    try t.expectEqualStrings("Composite projects may not disable incremental compilation.", diags[0].message);
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

test "tsconfig diagnostics: no-input and project-reference helpers mirror upstream messages" {
    const no_inputs = try noInputsDiagnostic(t.allocator, "/repo/tsconfig.json", "[\"src/**/*\"]", "[\"dist\"]");
    defer if (no_inputs.owns_message) t.allocator.free(no_inputs.message);
    try t.expectEqual(@as(u32, 18003), no_inputs.code);
    try t.expectEqualStrings("No inputs were found in config file '/repo/tsconfig.json'. Specified 'include' paths were '[\"src/**/*\"]' and 'exclude' paths were '[\"dist\"]'.", no_inputs.message);
    try t.expectEqualStrings("files", no_inputs.field);

    const composite = try projectReferenceCompositeDiagnostic(t.allocator, "/repo/pkg-a");
    defer if (composite.owns_message) t.allocator.free(composite.message);
    try t.expectEqual(@as(u32, 6306), composite.code);
    try t.expectEqualStrings("Referenced project '/repo/pkg-a' must have setting \"composite\": true.", composite.message);
    try t.expectEqualStrings("references", composite.field);

    const no_emit = try projectReferenceNoEmitDiagnostic(t.allocator, "/repo/pkg-b");
    defer if (no_emit.owns_message) t.allocator.free(no_emit.message);
    try t.expectEqual(@as(u32, 6310), no_emit.code);
    try t.expectEqualStrings("Referenced project '/repo/pkg-b' may not disable emit.", no_emit.message);
    try t.expectEqualStrings("references", no_emit.field);

    const arbitrary = try arbitraryExtensionImportDiagnostic(t.allocator, "./component.html", "component.d.html.ts");
    defer if (arbitrary.owns_message) t.allocator.free(arbitrary.message);
    try t.expectEqual(@as(u32, 6263), arbitrary.code);
    try t.expectEqualStrings("Module './component.html' was resolved to 'component.d.html.ts', but '--allowArbitraryExtensions' is not set.", arbitrary.message);
    try t.expectEqualStrings("allowArbitraryExtensions", arbitrary.field);

    const jsx_resolution = try jsxModuleResolutionDiagnostic(t.allocator, "./tsx", "/tsx.tsx");
    defer if (jsx_resolution.owns_message) t.allocator.free(jsx_resolution.message);
    try t.expectEqual(@as(u32, 6142), jsx_resolution.code);
    try t.expectEqualStrings("Module './tsx' was resolved to '/tsx.tsx', but '--jsx' is not set.", jsx_resolution.message);
    try t.expectEqualStrings("jsx", jsx_resolution.field);

    const unresolved_path = try unresolvedPathWithExtensionsDiagnostic(t.allocator, "a", "'.ts', '.tsx', '.d.ts', '.cts', '.d.cts', '.mts', '.d.mts'");
    defer if (unresolved_path.owns_message) t.allocator.free(unresolved_path.message);
    try t.expectEqual(@as(u32, 6231), unresolved_path.code);
    try t.expectEqualStrings("Could not resolve the path 'a' with the extensions: '.ts', '.tsx', '.d.ts', '.cts', '.d.cts', '.mts', '.d.mts'.", unresolved_path.message);
    try t.expectEqualStrings("files", unresolved_path.field);

    const js_without_allow_js = try jsFileRequiresAllowJsDiagnostic(t.allocator, "a.js");
    defer if (js_without_allow_js.owns_message) t.allocator.free(js_without_allow_js.message);
    try t.expectEqual(@as(u32, 6504), js_without_allow_js.code);
    try t.expectEqualStrings("File 'a.js' is a JavaScript file. Did you mean to enable the 'allowJs' option?", js_without_allow_js.message);
    try t.expectEqualStrings("allowJs", js_without_allow_js.field);

    const trace = try moduleResolutionStartDiagnostic(t.allocator, "react", "/repo/src/app.tsx");
    defer if (trace.owns_message) t.allocator.free(trace.message);
    try t.expectEqual(@as(u32, 6086), trace.code);
    try t.expectEqualStrings("======== Resolving module 'react' from '/repo/src/app.tsx'. ========", trace.message);
    try t.expectEqualStrings("traceResolution", trace.field);

    const cycle = try projectReferenceCycleDiagnostic(t.allocator, "/repo/a -> /repo/b -> /repo/a");
    defer if (cycle.owns_message) t.allocator.free(cycle.message);
    try t.expectEqual(@as(u32, 6202), cycle.code);
    try t.expectEqualStrings("Project references may not form a circular graph. Cycle detected: /repo/a -> /repo/b -> /repo/a", cycle.message);
    try t.expectEqualStrings("references", cycle.field);

    const redirect = try projectReferenceRedirectDiagnostic(t.allocator, "/repo/pkg-c");
    defer if (redirect.owns_message) t.allocator.free(redirect.message);
    try t.expectEqual(@as(u32, 6215), redirect.code);
    try t.expectEqualStrings("Using compiler options of project reference redirect '/repo/pkg-c'.", redirect.message);
    try t.expectEqualStrings("references", redirect.field);
}

test "tsconfig diagnostics: emit and project graph helpers mirror upstream messages" {
    const overwrite_input = try outputWouldOverwriteInputDiagnostic(t.allocator, "a.js");
    defer if (overwrite_input.owns_message) t.allocator.free(overwrite_input.message);
    try t.expectEqual(@as(u32, 5055), overwrite_input.code);
    try t.expectEqualStrings("Cannot write file 'a.js' because it would overwrite input file.", overwrite_input.message);
    try t.expectEqualStrings("emit", overwrite_input.field);

    const multiple_inputs = try outputWouldBeOverwrittenByMultipleInputsDiagnostic(t.allocator, "out/b.js");
    defer if (multiple_inputs.owns_message) t.allocator.free(multiple_inputs.message);
    try t.expectEqual(@as(u32, 5056), multiple_inputs.code);
    try t.expectEqualStrings("Cannot write file 'out/b.js' because it would be overwritten by multiple input files.", multiple_inputs.message);

    const root_dir = try rootDirContainsSourceFileDiagnostic(t.allocator, "FolderA/file.ts", "FolderA/src");
    defer if (root_dir.owns_message) t.allocator.free(root_dir.message);
    try t.expectEqual(@as(u32, 6059), root_dir.code);
    try t.expectEqualStrings("File 'FolderA/file.ts' is not under 'rootDir' 'FolderA/src'. 'rootDir' is expected to contain all source files.", root_dir.message);
    try t.expectEqualStrings("rootDir", root_dir.field);

    const not_built = try projectReferenceOutputNotBuiltDiagnostic(t.allocator, "lib/index.d.ts", "src/index.ts");
    defer if (not_built.owns_message) t.allocator.free(not_built.message);
    try t.expectEqual(@as(u32, 6305), not_built.code);
    try t.expectEqualStrings("Output file 'lib/index.d.ts' has not been built from source file 'src/index.ts'.", not_built.message);

    const not_listed = try projectFileListDiagnostic(t.allocator, "src/extra.ts", "/repo/tsconfig.json");
    defer if (not_listed.owns_message) t.allocator.free(not_listed.message);
    try t.expectEqual(@as(u32, 6307), not_listed.code);
    try t.expectEqualStrings("File 'src/extra.ts' is not listed within the file list of project '/repo/tsconfig.json'. Projects must list all files or use an 'include' pattern.", not_listed.message);

    const buildinfo = try referencedBuildInfoOverwriteDiagnostic(t.allocator, "pkg-a/tsconfig.tsbuildinfo", "../pkg-a");
    defer if (buildinfo.owns_message) t.allocator.free(buildinfo.message);
    try t.expectEqual(@as(u32, 6377), buildinfo.code);
    try t.expectEqualStrings("Cannot write file 'pkg-a/tsconfig.tsbuildinfo' because it will overwrite '.tsbuildinfo' file generated by referenced project '../pkg-a'", buildinfo.message);
    try t.expectEqualStrings("tsBuildInfoFile", buildinfo.field);
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
