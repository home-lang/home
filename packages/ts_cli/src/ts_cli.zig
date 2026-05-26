//! `home tsc` CLI entry point.
//!
//! Per TS_PARITY_PLAN section 2.1. Drop-in compatible with `tsc` /
//! `tsgo` flag surface. Phase 4.5 ships the most-used flags; the
//! complete ~140-key matrix from section 2.2 fills in incrementally
//! against the typed tsconfig schema.
//!
//! Usage:
//!
//!   home tsc [files…] [options]
//!   home tsc --noEmit            # type-check only
//!   home tsc --watch              # re-emit on file change
//!   home tsc --project=tsconfig.json   # explicit config path
//!
//! Exit codes match tsc: 0 success, 1 type errors, 2 CLI/config errors,
//! 3 internal errors.

const std = @import("std");
const ts_diagnostics = @import("ts_diagnostics");
const ts_driver = @import("ts_driver");
const ts_program = @import("ts_program");
const ts_resolver = @import("ts_resolver");
const tsconfig_mod = @import("tsconfig");

pub const ExitCode = enum(u8) {
    success = 0,
    type_errors = 1,
    config_error = 2,
    internal_error = 3,
};

pub const Options = struct {
    /// Files passed positionally on the CLI.
    files: []const []const u8 = &.{},
    /// `--project` / `-p` path to a tsconfig.json.
    project: ?[]const u8 = null,
    /// `--noEmit`.
    no_emit: bool = false,
    /// `--watch` / `-w`.
    watch: bool = false,
    /// `--pretty` / `--no-pretty`. `null` means "auto" (TTY detect).
    pretty: ?bool = null,
    /// `--listFiles`.
    list_files: bool = false,
    /// `--listFilesOnly`.
    list_files_only: bool = false,
    /// `--explainFiles`.
    explain_files: bool = false,
    list_emitted_files: bool = false,
    preserve_watch_output: bool = false,
    trace_resolution: bool = false,
    diagnostics: bool = false,
    extended_diagnostics: bool = false,
    /// `--showConfig`.
    show_config: bool = false,
    /// `--init`.
    init_config: bool = false,
    /// `--version` / `-v`.
    show_version: bool = false,
    /// `--help` / `-h` / `-?` / `--all`.
    show_help: bool = false,
    show_all_help: bool = false,
    /// `--strict` (and the strict-family individual toggles).
    strict: ?bool = null,
    /// `--target=esXXXX`.
    target: ?[]const u8 = null,
    module_resolution: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    generate_cpu_profile: ?[]const u8 = null,
    generate_trace: ?[]const u8 = null,
    /// `--outDir=PATH`.
    out_dir: ?[]const u8 = null,
    /// `--module=…`.
    module: ?[]const u8 = null,
    /// `--jsx=…`.
    jsx: ?[]const u8 = null,
    /// `--declaration` / `-d`. `null` means defer to tsconfig.
    declaration: ?bool = null,
    /// `--sourceMap`. `null` means defer to tsconfig.
    source_map: ?bool = null,
    /// `--declarationMap`. `null` means defer to tsconfig. When true,
    /// emit a `.d.ts.map` (or `.d.hm.map`) alongside each `.d.ts` /
    /// `.d.hm`. Implies `--declaration` at emit time.
    declaration_map: ?bool = null,
    emit_declaration_only: ?bool = null,
    inline_source_map: ?bool = null,
    no_check: ?bool = null,
    allow_arbitrary_extensions: ?bool = null,
    allow_importing_ts_extensions: ?bool = null,
    rewrite_relative_import_extensions: ?bool = null,
    assume_changes_only_affect_direct_dependencies: ?bool = null,
    incremental: ?bool = null,
    out_file: ?[]const u8 = null,
    ts_buildinfo_file: ?[]const u8 = null,
    /// `--build` / `-b`.
    build: bool = false,
    build_clean: bool = false,
    build_dry: bool = false,
    build_force: bool = false,
    build_verbose: bool = false,
    build_stop_on_errors: bool = false,
    parse_diagnostics: [16]CliDiagnostic = undefined,
    parse_diagnostic_count: u8 = 0,
};

pub const CliDiagnostic = struct {
    code: u32,
    option: []const u8,
    expected: []const u8 = "",
    suggestion: ?[]const u8 = null,
};

pub const ProjectDiagnosticKind = enum {
    host_unsupported_option,
    cannot_read_file_with_reason,
    cannot_read_file,
    could_not_write_file,
    config_already_defined,
    cannot_find_config_at_directory,
    specified_path_does_not_exist,
    add_tsconfig_json,
    cannot_find_config_at_current_directory,
    file_not_found,
    unsupported_extension,
};

pub const ProjectDiagnostic = struct {
    code: u32,
    path: []const u8 = "",
    detail: []const u8 = "",
    option: []const u8 = "",
};

pub const BuildStatusKind = enum {
    output_older_than_input,
    newest_input_older_than_output,
    output_missing,
    dependency_out_of_date,
    up_to_date_with_dts_from_dependencies,
    projects_in_build,
    dry_delete_files,
    dry_build_project,
    building_project,
    updating_output_timestamps,
    up_to_date,
    skipped_dependency_errors,
    dependency_errors,
    updating_unchanged_output_timestamps,
    dry_update_timestamps,
    version_mismatch,
    skipped_dependency_not_built,
    dependency_not_built,
    forcibly_rebuilt,
    buildinfo_pending_emit,
    buildinfo_read_error,
    buildinfo_options_changed,
    buildinfo_root_removed,
    buildinfo_report_errors,
    out_of_date_reason,
};

pub const BuildStatusDiagnostic = struct {
    kind: BuildStatusKind,
    project: []const u8 = "",
    output: []const u8 = "",
    input: []const u8 = "",
    dependency: []const u8 = "",
    files: []const u8 = "",
    version: []const u8 = "",
    current_version: []const u8 = "",
    buildinfo_file: []const u8 = "",
    reason: []const u8 = "",
};

const BuildStatusMessage = struct {
    kind: BuildStatusKind,
    code: u32,
};

pub const build_status_messages = [_]BuildStatusMessage{
    .{ .kind = .output_older_than_input, .code = 6350 },
    .{ .kind = .newest_input_older_than_output, .code = 6351 },
    .{ .kind = .output_missing, .code = 6352 },
    .{ .kind = .dependency_out_of_date, .code = 6353 },
    .{ .kind = .up_to_date_with_dts_from_dependencies, .code = 6354 },
    .{ .kind = .projects_in_build, .code = 6355 },
    .{ .kind = .dry_delete_files, .code = 6356 },
    .{ .kind = .dry_build_project, .code = 6357 },
    .{ .kind = .building_project, .code = 6358 },
    .{ .kind = .updating_output_timestamps, .code = 6359 },
    .{ .kind = .up_to_date, .code = 6361 },
    .{ .kind = .skipped_dependency_errors, .code = 6362 },
    .{ .kind = .dependency_errors, .code = 6363 },
    .{ .kind = .updating_unchanged_output_timestamps, .code = 6371 },
    .{ .kind = .dry_update_timestamps, .code = 6374 },
    .{ .kind = .version_mismatch, .code = 6381 },
    .{ .kind = .skipped_dependency_not_built, .code = 6382 },
    .{ .kind = .dependency_not_built, .code = 6383 },
    .{ .kind = .forcibly_rebuilt, .code = 6388 },
    .{ .kind = .buildinfo_pending_emit, .code = 6399 },
    .{ .kind = .buildinfo_read_error, .code = 6401 },
    .{ .kind = .buildinfo_options_changed, .code = 6406 },
    .{ .kind = .buildinfo_root_removed, .code = 6412 },
    .{ .kind = .buildinfo_report_errors, .code = 6419 },
    .{ .kind = .out_of_date_reason, .code = 6420 },
};

pub const ParseError = error{
    OutOfMemory,
    UnknownFlag,
    MissingValue,
};

/// Parse argv (excluding the program name) into a typed Options.
pub fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--noEmit")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "noEmit");
            } else {
                opts.no_emit = true;
            }
        } else if (std.mem.eql(u8, a, "--watch") or std.mem.eql(u8, a, "-w")) {
            if (opts.build) {
                const parsed = parseOptionalBoolValue(args, i);
                opts.watch = parsed.value orelse false;
                i = parsed.next_index;
            } else {
                opts.watch = true;
            }
        } else if (std.mem.eql(u8, a, "--pretty")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "pretty");
            } else {
                opts.pretty = true;
            }
        } else if (std.mem.eql(u8, a, "--no-pretty")) {
            opts.pretty = false;
        } else if (std.mem.eql(u8, a, "--listFiles")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "listFiles");
            } else {
                opts.list_files = true;
            }
        } else if (std.mem.eql(u8, a, "--listFilesOnly")) {
            if (opts.build) {
                appendCliDiagnostic(&opts, .{ .code = 5094, .option = "listFilesOnly" });
            } else {
                opts.list_files_only = true;
            }
        } else if (std.mem.eql(u8, a, "--explainFiles")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "explainFiles");
            } else {
                opts.explain_files = true;
            }
        } else if (std.mem.eql(u8, a, "--listEmittedFiles")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "listEmittedFiles");
            } else {
                opts.list_emitted_files = true;
            }
        } else if (std.mem.eql(u8, a, "--preserveWatchOutput")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "preserveWatchOutput");
            } else {
                opts.preserve_watch_output = true;
            }
        } else if (std.mem.eql(u8, a, "--traceResolution")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "traceResolution");
            } else {
                opts.trace_resolution = true;
            }
        } else if (std.mem.eql(u8, a, "--diagnostics")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "diagnostics");
            } else {
                opts.diagnostics = true;
            }
        } else if (std.mem.eql(u8, a, "--extendedDiagnostics")) {
            if (opts.build) {
                i = applyBuildBoolCompilerOption(args, i, &opts, "extendedDiagnostics");
            } else {
                opts.extended_diagnostics = true;
            }
        } else if (std.mem.eql(u8, a, "--showConfig")) {
            if (opts.build) {
                appendCliDiagnostic(&opts, .{ .code = 5094, .option = "showConfig" });
            } else {
                opts.show_config = true;
            }
        } else if (std.mem.eql(u8, a, "--init")) {
            if (opts.build) {
                appendCliDiagnostic(&opts, .{ .code = 5094, .option = "init" });
            } else {
                opts.init_config = true;
            }
        } else if (std.mem.eql(u8, a, "--version") or (std.mem.eql(u8, a, "-v") and !opts.build)) {
            if (opts.build and std.mem.eql(u8, a, "--version")) {
                appendCliDiagnostic(&opts, .{ .code = 5094, .option = "version" });
            } else {
                opts.show_version = true;
            }
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "-?")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            if (opts.build) {
                appendCliDiagnostic(&opts, .{ .code = 5094, .option = "all" });
            } else {
                opts.show_all_help = true;
            }
        } else if (std.mem.eql(u8, a, "--build") or std.mem.eql(u8, a, "-b")) {
            if (i == 0) {
                opts.build = true;
            } else {
                appendCliDiagnostic(&opts, .{ .code = 6369, .option = "build" });
            }
        } else if (buildOptionName(a)) |name| {
            if (opts.build) {
                applyBuildBoolOption(&opts, name);
            } else {
                appendCliDiagnostic(&opts, .{ .code = 5093, .option = name });
            }
        } else if (opts.build) {
            if (buildModeCompilerOnlyOption(a)) |name| {
                appendCliDiagnostic(&opts, .{ .code = 5094, .option = name });
            } else if (buildStringOptionName(a)) |name| {
                if (i + 1 >= args.len or (args[i + 1].len > 0 and args[i + 1][0] == '-')) {
                    appendCliDiagnostic(&opts, .{ .code = 5073, .option = name, .expected = "string" });
                } else {
                    i += 1;
                    if (std.mem.eql(u8, name, "generateCpuProfile")) opts.generate_cpu_profile = args[i];
                    if (std.mem.eql(u8, name, "generateTrace")) opts.generate_trace = args[i];
                }
            } else if (buildBoolCompilerOptionName(a)) |name| {
                i = applyBuildBoolCompilerOption(args, i, &opts, name);
            } else if (buildStringCompilerOptionName(a)) |name| {
                if (i + 1 < args.len and (args[i + 1].len == 0 or args[i + 1][0] != '-')) {
                    i += 1;
                    applyBuildStringCompilerOption(&opts, name, args[i]);
                } else {
                    appendCliDiagnostic(&opts, .{ .code = 5073, .option = name, .expected = "string" });
                }
            } else if (unknownDashedOptionName(a)) |name| {
                if (buildOptionSuggestion(name)) |suggestion| {
                    appendCliDiagnostic(&opts, .{ .code = 5077, .option = a, .suggestion = suggestion });
                } else {
                    appendCliDiagnostic(&opts, .{ .code = 5072, .option = a });
                }
            } else {
                try files.append(gpa, a);
            }
        } else if (std.mem.eql(u8, a, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "project" });
            } else {
                opts.project = args[i];
            }
        } else if (parseEqFlag(a, "--project=")) |v| {
            opts.project = v;
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "target" });
            } else {
                opts.target = args[i];
            }
        } else if (parseEqFlag(a, "--target=")) |v| {
            opts.target = v;
        } else if (std.mem.eql(u8, a, "--moduleResolution")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "moduleResolution" });
            } else {
                opts.module_resolution = args[i];
            }
        } else if (parseEqFlag(a, "--moduleResolution=")) |v| {
            opts.module_resolution = v;
        } else if (std.mem.eql(u8, a, "--baseUrl")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "baseUrl" });
            } else {
                opts.base_url = args[i];
            }
        } else if (parseEqFlag(a, "--baseUrl=")) |v| {
            opts.base_url = v;
        } else if (std.mem.eql(u8, a, "--locale")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "locale" });
            } else {
                opts.locale = args[i];
            }
        } else if (parseEqFlag(a, "--locale=")) |v| {
            opts.locale = v;
        } else if (std.mem.eql(u8, a, "--generateCpuProfile")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "generateCpuProfile" });
            } else {
                opts.generate_cpu_profile = args[i];
            }
        } else if (parseEqFlag(a, "--generateCpuProfile=")) |v| {
            opts.generate_cpu_profile = v;
        } else if (std.mem.eql(u8, a, "--generateTrace")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "generateTrace" });
            } else {
                opts.generate_trace = args[i];
            }
        } else if (parseEqFlag(a, "--generateTrace=")) |v| {
            opts.generate_trace = v;
        } else if (parseEqFlag(a, "--outDir=")) |v| {
            opts.out_dir = v;
        } else if (std.mem.eql(u8, a, "--outDir")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "outDir" });
            } else {
                opts.out_dir = args[i];
            }
        } else if (parseEqFlag(a, "--outFile=")) |v| {
            opts.out_file = v;
        } else if (std.mem.eql(u8, a, "--outFile")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "outFile" });
            } else {
                opts.out_file = args[i];
            }
        } else if (parseEqFlag(a, "--tsBuildInfoFile=")) |v| {
            opts.ts_buildinfo_file = v;
        } else if (std.mem.eql(u8, a, "--tsBuildInfoFile")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "tsBuildInfoFile" });
            } else {
                opts.ts_buildinfo_file = args[i];
            }
        } else if (parseEqFlag(a, "--module=")) |v| {
            opts.module = v;
        } else if (std.mem.eql(u8, a, "--module")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "module" });
            } else {
                opts.module = args[i];
            }
        } else if (parseEqFlag(a, "--jsx=")) |v| {
            opts.jsx = v;
        } else if (std.mem.eql(u8, a, "--jsx")) {
            i += 1;
            if (i >= args.len) {
                appendCliDiagnostic(&opts, .{ .code = 6044, .option = "jsx" });
            } else {
                opts.jsx = args[i];
            }
        } else if (std.mem.eql(u8, a, "--declaration") or std.mem.eql(u8, a, "-d")) {
            opts.declaration = true;
        } else if (std.mem.eql(u8, a, "--no-declaration")) {
            opts.declaration = false;
        } else if (std.mem.eql(u8, a, "--sourceMap")) {
            opts.source_map = true;
        } else if (std.mem.eql(u8, a, "--no-sourceMap")) {
            opts.source_map = false;
        } else if (std.mem.eql(u8, a, "--declarationMap")) {
            opts.declaration_map = true;
        } else if (std.mem.eql(u8, a, "--no-declarationMap")) {
            opts.declaration_map = false;
        } else if (std.mem.eql(u8, a, "--emitDeclarationOnly")) {
            opts.emit_declaration_only = true;
        } else if (std.mem.eql(u8, a, "--no-emitDeclarationOnly")) {
            opts.emit_declaration_only = false;
        } else if (std.mem.eql(u8, a, "--inlineSourceMap")) {
            opts.inline_source_map = true;
        } else if (std.mem.eql(u8, a, "--no-inlineSourceMap")) {
            opts.inline_source_map = false;
        } else if (std.mem.eql(u8, a, "--noCheck")) {
            opts.no_check = true;
        } else if (std.mem.eql(u8, a, "--no-noCheck")) {
            opts.no_check = false;
        } else if (std.mem.eql(u8, a, "--allowArbitraryExtensions")) {
            opts.allow_arbitrary_extensions = true;
        } else if (std.mem.eql(u8, a, "--no-allowArbitraryExtensions")) {
            opts.allow_arbitrary_extensions = false;
        } else if (std.mem.eql(u8, a, "--allowImportingTsExtensions")) {
            opts.allow_importing_ts_extensions = true;
        } else if (std.mem.eql(u8, a, "--no-allowImportingTsExtensions")) {
            opts.allow_importing_ts_extensions = false;
        } else if (std.mem.eql(u8, a, "--rewriteRelativeImportExtensions")) {
            opts.rewrite_relative_import_extensions = true;
        } else if (std.mem.eql(u8, a, "--no-rewriteRelativeImportExtensions")) {
            opts.rewrite_relative_import_extensions = false;
        } else if (std.mem.eql(u8, a, "--assumeChangesOnlyAffectDirectDependencies")) {
            opts.assume_changes_only_affect_direct_dependencies = true;
        } else if (std.mem.eql(u8, a, "--no-assumeChangesOnlyAffectDirectDependencies")) {
            opts.assume_changes_only_affect_direct_dependencies = false;
        } else if (std.mem.eql(u8, a, "--incremental")) {
            opts.incremental = true;
        } else if (std.mem.eql(u8, a, "--no-incremental")) {
            opts.incremental = false;
        } else if (tsConfigOnlyOptionName(a)) |config_only| {
            i = parseTsConfigOnlyOption(args, i, &opts, config_only);
        } else if (unknownDashedOptionName(a)) |name| {
            if (compilerOptionSuggestion(name)) |suggestion| {
                appendCliDiagnostic(&opts, .{ .code = 5025, .option = name, .suggestion = suggestion });
            } else {
                appendCliDiagnostic(&opts, .{ .code = 5023, .option = name });
            }
        } else {
            try files.append(gpa, a);
        }
    }
    appendBuildCombinationDiagnostics(&opts);
    if (opts.build and files.items.len == 0) {
        try files.append(gpa, ".");
    }
    opts.files = try files.toOwnedSlice(gpa);
    return opts;
}

fn parseEqFlag(a: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, a, prefix)) return a[prefix.len..];
    return null;
}

fn appendCliDiagnostic(opts: *Options, diag: CliDiagnostic) void {
    if (opts.parse_diagnostic_count >= opts.parse_diagnostics.len) return;
    opts.parse_diagnostics[opts.parse_diagnostic_count] = diag;
    opts.parse_diagnostic_count += 1;
}

fn buildOptionName(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "--clean")) return "clean";
    if (std.mem.eql(u8, arg, "--dry") or std.mem.eql(u8, arg, "-d")) return "dry";
    if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) return "force";
    if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) return "verbose";
    if (std.mem.eql(u8, arg, "--stopBuildOnErrors")) return "stopBuildOnErrors";
    return null;
}

fn applyBuildBoolOption(opts: *Options, name: []const u8) void {
    if (std.mem.eql(u8, name, "clean")) opts.build_clean = true;
    if (std.mem.eql(u8, name, "dry")) opts.build_dry = true;
    if (std.mem.eql(u8, name, "force")) opts.build_force = true;
    if (std.mem.eql(u8, name, "verbose")) opts.build_verbose = true;
    if (std.mem.eql(u8, name, "stopBuildOnErrors")) opts.build_stop_on_errors = true;
}

fn appendBuildCombinationDiagnostics(opts: *Options) void {
    if (!opts.build) return;
    if (opts.build_clean and opts.build_force) appendCliDiagnostic(opts, .{ .code = 6370, .option = "clean", .expected = "force" });
    if (opts.build_clean and opts.build_verbose) appendCliDiagnostic(opts, .{ .code = 6370, .option = "clean", .expected = "verbose" });
    if (opts.build_clean and opts.watch) appendCliDiagnostic(opts, .{ .code = 6370, .option = "clean", .expected = "watch" });
    if (opts.watch and opts.build_dry) appendCliDiagnostic(opts, .{ .code = 6370, .option = "watch", .expected = "dry" });
}

const TsConfigOnlyOption = struct {
    name: []const u8,
    boolean: bool,
    inline_value: ?[]const u8 = null,
};

fn tsConfigOnlyOptionName(arg: []const u8) ?TsConfigOnlyOption {
    const name = unknownDashedOptionName(arg) orelse return null;
    const config_only = comptime [_]TsConfigOnlyOption{
        .{ .name = "composite", .boolean = true },
        .{ .name = "disableSourceOfProjectReferenceRedirect", .boolean = true },
        .{ .name = "disableSolutionSearching", .boolean = true },
        .{ .name = "disableReferencedProjectLoad", .boolean = true },
        .{ .name = "paths", .boolean = false },
        .{ .name = "rootDirs", .boolean = false },
        .{ .name = "plugins", .boolean = false },
    };
    inline for (config_only) |candidate| {
        if (std.mem.eql(u8, name, candidate.name)) {
            var result = candidate;
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                result.inline_value = arg[eq + 1 ..];
            }
            return result;
        }
    }
    return null;
}

fn parseTsConfigOnlyOption(args: []const []const u8, i: usize, opts: *Options, config_only: TsConfigOnlyOption) usize {
    const value = config_only.inline_value orelse if (i + 1 < args.len and (args[i + 1].len == 0 or args[i + 1][0] != '-')) args[i + 1] else null;
    if (config_only.boolean) {
        if (value) |v| {
            if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "null")) return if (config_only.inline_value == null) i + 1 else i;
            if (std.mem.eql(u8, v, "true") and config_only.inline_value == null) {
                appendCliDiagnostic(opts, .{ .code = 6230, .option = config_only.name });
                return i + 1;
            }
        }
        appendCliDiagnostic(opts, .{ .code = 6230, .option = config_only.name });
        return i;
    }

    if (value) |v| {
        if (std.mem.eql(u8, v, "null")) return if (config_only.inline_value == null) i + 1 else i;
    }
    appendCliDiagnostic(opts, .{ .code = 6064, .option = config_only.name });
    if (config_only.inline_value == null and i + 1 < args.len and (args[i + 1].len == 0 or args[i + 1][0] != '-')) return i + 1;
    return i;
}

fn buildStringOptionName(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "--generateCpuProfile")) return "generateCpuProfile";
    if (std.mem.eql(u8, arg, "--generateTrace")) return "generateTrace";
    return null;
}

fn buildModeCompilerOnlyOption(arg: []const u8) ?[]const u8 {
    const name = unknownDashedOptionName(arg) orelse return null;
    const compiler_only = comptime [_][]const u8{
        "all",
        "version",
        "init",
        "project",
        "showConfig",
        "listFilesOnly",
        "strict",
        "target",
        "module",
        "moduleResolution",
        "baseUrl",
        "jsx",
        "outDir",
        "outFile",
        "tsBuildInfoFile",
        "composite",
        "isolatedDeclarations",
        "paths",
        "rootDirs",
        "plugins",
        "allowArbitraryExtensions",
        "allowImportingTsExtensions",
        "rewriteRelativeImportExtensions",
    };
    inline for (compiler_only) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return candidate;
    }
    return null;
}

fn buildBoolCompilerOptionName(arg: []const u8) ?[]const u8 {
    const name = unknownDashedOptionName(arg) orelse return null;
    const accepted = comptime [_][]const u8{
        "incremental",
        "declaration",
        "declarationMap",
        "emitDeclarationOnly",
        "sourceMap",
        "inlineSourceMap",
        "noCheck",
        "noEmit",
        "assumeChangesOnlyAffectDirectDependencies",
        "preserveWatchOutput",
        "listFiles",
        "explainFiles",
        "listEmittedFiles",
        "pretty",
        "traceResolution",
        "diagnostics",
        "extendedDiagnostics",
    };
    inline for (accepted) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return candidate;
    }
    return null;
}

fn buildStringCompilerOptionName(arg: []const u8) ?[]const u8 {
    const name = unknownDashedOptionName(arg) orelse return null;
    const accepted = comptime [_][]const u8{
        "locale",
    };
    inline for (accepted) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return candidate;
    }
    return null;
}

fn applyBuildBoolCompilerOption(args: []const []const u8, i: usize, opts: *Options, name: []const u8) usize {
    const parsed = parseOptionalBoolValue(args, i);
    const value = parsed.value orelse false;

    if (std.mem.eql(u8, name, "incremental")) opts.incremental = value;
    if (std.mem.eql(u8, name, "declaration")) opts.declaration = value;
    if (std.mem.eql(u8, name, "declarationMap")) opts.declaration_map = value;
    if (std.mem.eql(u8, name, "emitDeclarationOnly")) opts.emit_declaration_only = value;
    if (std.mem.eql(u8, name, "sourceMap")) opts.source_map = value;
    if (std.mem.eql(u8, name, "inlineSourceMap")) opts.inline_source_map = value;
    if (std.mem.eql(u8, name, "noCheck")) opts.no_check = value;
    if (std.mem.eql(u8, name, "noEmit")) opts.no_emit = value;
    if (std.mem.eql(u8, name, "assumeChangesOnlyAffectDirectDependencies")) opts.assume_changes_only_affect_direct_dependencies = value;
    if (std.mem.eql(u8, name, "preserveWatchOutput")) opts.preserve_watch_output = value;
    if (std.mem.eql(u8, name, "listFiles")) opts.list_files = value;
    if (std.mem.eql(u8, name, "explainFiles")) opts.explain_files = value;
    if (std.mem.eql(u8, name, "listEmittedFiles")) opts.list_emitted_files = value;
    if (std.mem.eql(u8, name, "pretty")) opts.pretty = value;
    if (std.mem.eql(u8, name, "traceResolution")) opts.trace_resolution = value;
    if (std.mem.eql(u8, name, "diagnostics")) opts.diagnostics = value;
    if (std.mem.eql(u8, name, "extendedDiagnostics")) opts.extended_diagnostics = value;
    return parsed.next_index;
}

fn applyBuildStringCompilerOption(opts: *Options, name: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, name, "locale")) opts.locale = value;
}

const BoolValueParse = struct {
    value: ?bool,
    next_index: usize,
};

fn parseOptionalBoolValue(args: []const []const u8, i: usize) BoolValueParse {
    if (i + 1 < args.len) {
        const next = args[i + 1];
        if (std.mem.eql(u8, next, "true")) return .{ .value = true, .next_index = i + 1 };
        if (std.mem.eql(u8, next, "false")) return .{ .value = false, .next_index = i + 1 };
        if (std.mem.eql(u8, next, "null")) return .{ .value = null, .next_index = i + 1 };
    }
    return .{ .value = true, .next_index = i };
}

fn unknownDashedOptionName(arg: []const u8) ?[]const u8 {
    if (arg.len == 0 or arg[0] != '-') return null;
    const start: usize = if (arg.len > 1 and arg[1] == '-') 2 else 1;
    if (start >= arg.len) return null;
    const body = arg[start..];
    if (std.mem.indexOfScalar(u8, body, '=')) |eq| return body[0..eq];
    return body;
}

fn buildOptionSuggestion(name: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
        "build",
        "clean",
        "dry",
        "force",
        "verbose",
        "stopBuildOnErrors",
        "watch",
        "pretty",
        "generateCpuProfile",
        "generateTrace",
    };
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        const distance = levenshteinIcase(name, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    const threshold = name.len * 4 / 10 + 1;
    return if (best != null and best_distance < threshold) best else null;
}

fn compilerOptionSuggestion(name: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
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
        "sourceMap",
        "inlineSourceMap",
        "noCheck",
        "noEmit",
        "locale",
        "target",
        "module",
        "all",
        "version",
        "init",
        "project",
        "showConfig",
        "listFilesOnly",
        "ignoreConfig",
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
        "importHelpers",
        "importsNotUsedAsValues",
        "downlevelIteration",
        "isolatedModules",
        "verbatimModuleSyntax",
        "isolatedDeclarations",
        "strict",
        "noImplicitAny",
        "strictNullChecks",
        "strictFunctionTypes",
        "strictBindCallApply",
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
        "types",
        "allowSyntheticDefaultImports",
        "esModuleInterop",
        "preserveSymlinks",
        "allowUmdGlobalAccess",
        "moduleSuffixes",
        "allowImportingTsExtensions",
        "rewriteRelativeImportExtensions",
        "resolvePackageJsonExports",
        "resolvePackageJsonImports",
        "customConditions",
        "noUncheckedSideEffectImports",
        "sourceRoot",
        "mapRoot",
        "inlineSources",
        "experimentalDecorators",
        "emitDecoratorMetadata",
        "jsxFactory",
        "jsxFragmentFactory",
        "jsxImportSource",
        "resolveJsonModule",
        "allowArbitraryExtensions",
        "out",
        "reactNamespace",
        "skipDefaultLibCheck",
        "charset",
        "emitBOM",
        "newLine",
        "noErrorTruncation",
        "noLib",
        "noResolve",
        "stripInternal",
        "disableSizeLimit",
        "disableSourceOfProjectReferenceRedirect",
        "disableSolutionSearching",
        "disableReferencedProjectLoad",
        "noImplicitUseStrict",
        "noEmitHelpers",
        "noEmitOnError",
        "preserveConstEnums",
        "declarationDir",
        "skipLibCheck",
        "allowUnusedLabels",
        "allowUnreachableCode",
        "suppressExcessPropertyErrors",
        "suppressImplicitAnyIndexErrors",
        "forceConsistentCasingInFileNames",
        "maxNodeModuleJsDepth",
        "noStrictGenericChecks",
        "useDefineForClassFields",
        "preserveValueImports",
        "keyofStringsOnly",
        "plugins",
        "moduleDetection",
        "ignoreDeprecations",
    };
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        const max_len_diff = @max(@as(usize, 2), name.len * 34 / 100);
        const len_diff = if (name.len > candidate.len) name.len - candidate.len else candidate.len - name.len;
        if (len_diff > max_len_diff) continue;
        const distance = levenshteinIcase(name, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    const threshold = name.len * 4 / 10 + 1;
    return if (best != null and best_distance < threshold) best else null;
}

fn levenshteinIcase(a: []const u8, b: []const u8) usize {
    var previous_buf: [96]usize = undefined;
    var current_buf: [96]usize = undefined;
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

pub fn formatCliDiagnostic(gpa: std.mem.Allocator, diag: CliDiagnostic) ![]const u8 {
    return switch (diag.code) {
        5023 => try std.fmt.allocPrint(gpa, "error TS5023: Unknown compiler option '{s}'.", .{diag.option}),
        5025 => try std.fmt.allocPrint(gpa, "error TS5025: Unknown compiler option '{s}'. Did you mean '{s}'?", .{ diag.option, diag.suggestion.? }),
        6064 => try std.fmt.allocPrint(gpa, "error TS6064: Option '{s}' can only be specified in 'tsconfig.json' file or set to 'null' on command line.", .{diag.option}),
        6230 => try std.fmt.allocPrint(gpa, "error TS6230: Option '{s}' can only be specified in 'tsconfig.json' file or set to 'false' or 'null' on command line.", .{diag.option}),
        6044 => try std.fmt.allocPrint(gpa, "error TS6044: Compiler option '{s}' expects an argument.", .{diag.option}),
        5072 => try std.fmt.allocPrint(gpa, "error TS5072: Unknown build option '{s}'.", .{diag.option}),
        5073 => try std.fmt.allocPrint(gpa, "error TS5073: Build option '{s}' requires a value of type {s}.", .{ diag.option, diag.expected }),
        5077 => try std.fmt.allocPrint(gpa, "error TS5077: Unknown build option '{s}'. Did you mean '{s}'?", .{ diag.option, diag.suggestion.? }),
        5093 => try std.fmt.allocPrint(gpa, "error TS5093: Compiler option '--{s}' may only be used with '--build'.", .{diag.option}),
        5094 => try std.fmt.allocPrint(gpa, "error TS5094: Compiler option '--{s}' may not be used with '--build'.", .{diag.option}),
        6369 => try gpa.dupe(u8, "error TS6369: Option '--build' must be the first command line argument."),
        6370 => try std.fmt.allocPrint(gpa, "error TS6370: Options '{s}' and '{s}' cannot be combined.", .{ diag.option, diag.expected }),
        else => unreachable,
    };
}

pub fn projectDiagnostic(kind: ProjectDiagnosticKind, path: []const u8, detail: []const u8) ProjectDiagnostic {
    return switch (kind) {
        .host_unsupported_option => .{ .code = 5001, .option = path },
        .cannot_read_file_with_reason => .{ .code = 5012, .path = path, .detail = detail },
        .cannot_read_file => .{ .code = 5083, .path = path },
        .could_not_write_file => .{ .code = 5033, .path = path, .detail = detail },
        .config_already_defined => .{ .code = 5054, .path = path },
        .cannot_find_config_at_directory => .{ .code = 5057, .path = path },
        .specified_path_does_not_exist => .{ .code = 5058, .path = path },
        .add_tsconfig_json => .{ .code = 5068 },
        .cannot_find_config_at_current_directory => .{ .code = 5081, .path = path },
        .file_not_found => .{ .code = 6053, .path = path },
        .unsupported_extension => .{ .code = 6054, .path = path, .detail = detail },
    };
}

pub fn formatProjectDiagnostic(gpa: std.mem.Allocator, diag: ProjectDiagnostic) ![]const u8 {
    return switch (diag.code) {
        5001 => try std.fmt.allocPrint(gpa, "error TS5001: The current host does not support the '{s}' option.", .{diag.option}),
        5012 => try std.fmt.allocPrint(gpa, "error TS5012: Cannot read file '{s}': {s}.", .{ diag.path, diag.detail }),
        5033 => try std.fmt.allocPrint(gpa, "error TS5033: Could not write file '{s}': {s}.", .{ diag.path, diag.detail }),
        5054 => try std.fmt.allocPrint(gpa, "error TS5054: A 'tsconfig.json' file is already defined at: '{s}'.", .{diag.path}),
        5057 => try std.fmt.allocPrint(gpa, "error TS5057: Cannot find a tsconfig.json file at the specified directory: '{s}'.", .{diag.path}),
        5058 => try std.fmt.allocPrint(gpa, "error TS5058: The specified path does not exist: '{s}'.", .{diag.path}),
        5068 => try gpa.dupe(u8, "error TS5068: Adding a tsconfig.json file will help organize projects that contain both TypeScript and JavaScript files. Learn more at https://aka.ms/tsconfig."),
        5081 => try std.fmt.allocPrint(gpa, "error TS5081: Cannot find a tsconfig.json file at the current directory: {s}.", .{diag.path}),
        5083 => try std.fmt.allocPrint(gpa, "error TS5083: Cannot read file '{s}'.", .{diag.path}),
        6053 => try std.fmt.allocPrint(gpa, "error TS6053: File '{s}' not found.", .{diag.path}),
        6054 => try std.fmt.allocPrint(gpa, "error TS6054: File '{s}' has an unsupported extension. The only supported extensions are {s}.", .{ diag.path, diag.detail }),
        else => unreachable,
    };
}

pub fn buildStatusCode(kind: BuildStatusKind) u32 {
    for (build_status_messages) |message| {
        if (message.kind == kind) return message.code;
    }
    unreachable;
}

pub fn formatBuildStatusDiagnostic(gpa: std.mem.Allocator, diag: BuildStatusDiagnostic) ![]const u8 {
    return switch (diag.kind) {
        .output_older_than_input => try std.fmt.allocPrint(gpa, "message TS6350: Project '{s}' is out of date because output '{s}' is older than input '{s}'", .{ diag.project, diag.output, diag.input }),
        .newest_input_older_than_output => try std.fmt.allocPrint(gpa, "message TS6351: Project '{s}' is up to date because newest input '{s}' is older than output '{s}'", .{ diag.project, diag.input, diag.output }),
        .output_missing => try std.fmt.allocPrint(gpa, "message TS6352: Project '{s}' is out of date because output file '{s}' does not exist", .{ diag.project, diag.output }),
        .dependency_out_of_date => try std.fmt.allocPrint(gpa, "message TS6353: Project '{s}' is out of date because its dependency '{s}' is out of date", .{ diag.project, diag.dependency }),
        .up_to_date_with_dts_from_dependencies => try std.fmt.allocPrint(gpa, "message TS6354: Project '{s}' is up to date with .d.ts files from its dependencies", .{diag.project}),
        .projects_in_build => try std.fmt.allocPrint(gpa, "message TS6355: Projects in this build: {s}", .{diag.files}),
        .dry_delete_files => try std.fmt.allocPrint(gpa, "message TS6356: A non-dry build would delete the following files: {s}", .{diag.files}),
        .dry_build_project => try std.fmt.allocPrint(gpa, "message TS6357: A non-dry build would build project '{s}'", .{diag.project}),
        .building_project => try std.fmt.allocPrint(gpa, "message TS6358: Building project '{s}'...", .{diag.project}),
        .updating_output_timestamps => try std.fmt.allocPrint(gpa, "message TS6359: Updating output timestamps of project '{s}'...", .{diag.project}),
        .up_to_date => try std.fmt.allocPrint(gpa, "message TS6361: Project '{s}' is up to date", .{diag.project}),
        .skipped_dependency_errors => try std.fmt.allocPrint(gpa, "message TS6362: Skipping build of project '{s}' because its dependency '{s}' has errors", .{ diag.project, diag.dependency }),
        .dependency_errors => try std.fmt.allocPrint(gpa, "message TS6363: Project '{s}' can't be built because its dependency '{s}' has errors", .{ diag.project, diag.dependency }),
        .updating_unchanged_output_timestamps => try std.fmt.allocPrint(gpa, "message TS6371: Updating unchanged output timestamps of project '{s}'...", .{diag.project}),
        .dry_update_timestamps => try std.fmt.allocPrint(gpa, "message TS6374: A non-dry build would update timestamps for output of project '{s}'", .{diag.project}),
        .version_mismatch => try std.fmt.allocPrint(gpa, "message TS6381: Project '{s}' is out of date because output for it was generated with version '{s}' that differs with current version '{s}'", .{ diag.project, diag.version, diag.current_version }),
        .skipped_dependency_not_built => try std.fmt.allocPrint(gpa, "message TS6382: Skipping build of project '{s}' because its dependency '{s}' was not built", .{ diag.project, diag.dependency }),
        .dependency_not_built => try std.fmt.allocPrint(gpa, "message TS6383: Project '{s}' can't be built because its dependency '{s}' was not built", .{ diag.project, diag.dependency }),
        .forcibly_rebuilt => try std.fmt.allocPrint(gpa, "message TS6388: Project '{s}' is being forcibly rebuilt", .{diag.project}),
        .buildinfo_pending_emit => try std.fmt.allocPrint(gpa, "message TS6399: Project '{s}' is out of date because buildinfo file '{s}' indicates that some of the changes were not emitted", .{ diag.project, diag.buildinfo_file }),
        .buildinfo_read_error => try std.fmt.allocPrint(gpa, "message TS6401: Project '{s}' is out of date because there was error reading file '{s}'", .{ diag.project, diag.buildinfo_file }),
        .buildinfo_options_changed => try std.fmt.allocPrint(gpa, "message TS6406: Project '{s}' is out of date because buildinfo file '{s}' indicates there is change in compilerOptions", .{ diag.project, diag.buildinfo_file }),
        .buildinfo_root_removed => try std.fmt.allocPrint(gpa, "message TS6412: Project '{s}' is out of date because buildinfo file '{s}' indicates that file '{s}' was root file of compilation but not any more.", .{ diag.project, diag.buildinfo_file, diag.input }),
        .buildinfo_report_errors => try std.fmt.allocPrint(gpa, "message TS6419: Project '{s}' is out of date because buildinfo file '{s}' indicates that program needs to report errors.", .{ diag.project, diag.buildinfo_file }),
        .out_of_date_reason => try std.fmt.allocPrint(gpa, "message TS6420: Project '{s}' is out of date because {s}.", .{ diag.project, diag.reason }),
    };
}

pub const helpText: []const u8 =
    \\Usage: home tsc [files...] [options]
    \\
    \\Options:
    \\  --project, -p <path>   Compile the project at <path>/tsconfig.json
    \\  --noEmit               Type-check only; do not write output files
    \\  --watch, -w            Watch input files for changes and recompile
    \\  --target <es*>         Target ES version (default es2024)
    \\  --module <kind>        Module form (commonjs / es2022 / nodenext / preserve)
    \\  --outDir <dir>         Output directory for emitted files
    \\  --jsx <mode>           JSX mode (preserve / react / react-jsx / react-jsxdev)
    \\  --sourceMap            Emit a `.js.map` source map alongside each `.js`
    \\  --declarationMap       Emit a `.d.ts.map` / `.d.hm.map` alongside each declaration
    \\  --strict               Enable all --strictXxx options
    \\  --pretty / --no-pretty Force-toggle ANSI-colored diagnostics
    \\  --listFiles            Print all included files and exit
    \\  --listFilesOnly        Same as --listFiles but stops before emit
    \\  --explainFiles         Print files and the reasons they are included
    \\  --showConfig           Print the resolved tsconfig as JSON
    \\  --init                 Write a default tsconfig.json
    \\  --version, -v          Print version
    \\  --help, -h             Print this help
    \\  --all                  Print every flag including advanced
    \\
;

pub const versionText: []const u8 = "home tsc 0.1.0 (TS-compat 5.x)";
pub const InitDiagnostic = struct {
    code: u32,
    message: []const u8,
};
pub const init_success_diagnostic: InitDiagnostic = .{
    .code = 6071,
    .message = "message TS6071: Successfully created a tsconfig.json file.",
};

pub const RunResult = struct {
    code: ExitCode,
    /// One of `helpText`, `versionText`, or empty.
    stdout_text: []const u8 = "",
    /// Diagnostic message when `code` indicates failure.
    stderr_text: []const u8 = "",
};

/// Process parsed Options and decide what the CLI should do. Pure
/// function — no I/O. The actual binary wraps this with stdout /
/// stderr / disk reads.
pub fn dispatch(opts: Options) RunResult {
    if (opts.parse_diagnostic_count > 0) {
        return .{
            .code = .config_error,
            .stderr_text = "error: invalid command line options",
        };
    }
    if (opts.show_version) {
        return .{ .code = .success, .stdout_text = versionText };
    }
    if (opts.show_help or opts.show_all_help) {
        return .{ .code = .success, .stdout_text = helpText };
    }
    if (opts.init_config) {
        return .{ .code = .success, .stdout_text = init_success_diagnostic.message };
    }
    if (opts.target) |target| {
        if (tsconfig_mod.Target.fromString(target) == null) return invalidCustomTypeOption("--target", targetValuesText);
    }
    if (opts.module) |module| {
        if (tsconfig_mod.Module.fromString(module) == null) return invalidCustomTypeOption("--module", moduleValuesText);
    }
    if (opts.module_resolution) |module_resolution| {
        if (tsconfig_mod.ModuleResolution.fromString(module_resolution) == null) return invalidCustomTypeOption("--moduleResolution", moduleResolutionValuesText);
    }
    if (opts.jsx) |jsx| {
        if (tsconfig_mod.Jsx.fromString(jsx) == null) return invalidCustomTypeOption("--jsx", jsxValuesText);
    }
    if (opts.project != null and opts.files.len != 0) {
        const ts_project_cannot_mix_files: u32 = 5042;
        return .{
            .code = .config_error,
            .stderr_text = std.fmt.comptimePrint(
                "error TS{d}: Option 'project' cannot be mixed with source files on a command line.",
                .{ts_project_cannot_mix_files},
            ),
        };
    }
    if (opts.incremental == true and opts.project == null and opts.out_file == null and opts.ts_buildinfo_file == null) {
        return .{
            .code = .config_error,
            .stderr_text = "error TS5074: Option '--incremental' can only be specified using tsconfig, emitting to single file or when option '--tsBuildInfoFile' is specified.",
        };
    }
    if (opts.files.len == 0 and opts.project == null) {
        return .{
            .code = .config_error,
            .stderr_text = "error: no input files; pass paths or --project=<dir>",
        };
    }
    // The full driver flow lands in a Phase 5 follow-up: load the
    // tsconfig from disk, build a Program over the resolved file
    // graph, run compileAll, then either emit to disk or
    // (if --noEmit) just collate diagnostics.
    return .{ .code = .success };
}

const targetValuesText = "'es3', 'es5', 'es6', 'es2015', 'es2016', 'es2017', 'es2018', 'es2019', 'es2020', 'es2021', 'es2022', 'es2023', 'es2024', 'esnext'";
const moduleValuesText = "'none', 'commonjs', 'amd', 'umd', 'system', 'es6', 'es2015', 'es2020', 'es2022', 'esnext', 'node16', 'node18', 'node20', 'nodenext', 'preserve'";
const moduleResolutionValuesText = "'classic', 'node10', 'node16', 'nodenext', 'bundler'";
const jsxValuesText = "'preserve', 'react', 'react-jsx', 'react-jsxdev', 'react-native'";

fn invalidCustomTypeOption(comptime option: []const u8, comptime values: []const u8) RunResult {
    const ts_argument_for_option_must_be: u32 = 6046;
    return .{
        .code = .config_error,
        .stderr_text = std.fmt.comptimePrint(
            "error TS{d}: Argument for '{s}' option must be: {s}.",
            .{ ts_argument_for_option_must_be, option, values },
        ),
    };
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "parseArgs: positional file paths" {
    const argv = [_][]const u8{ "src/a.ts", "src/b.ts" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(usize, 2), opts.files.len);
    try T.expectEqualStrings("src/a.ts", opts.files[0]);
}

test "parseArgs: --noEmit" {
    const argv = [_][]const u8{"--noEmit"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.no_emit);
}

test "parseArgs: --watch and -w both work" {
    {
        const argv = [_][]const u8{"--watch"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expect(opts.watch);
    }
    {
        const argv = [_][]const u8{"-w"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expect(opts.watch);
    }
}

test "parseArgs: --project=path" {
    const argv = [_][]const u8{"--project=./tsconfig.json"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqualStrings("./tsconfig.json", opts.project.?);
}

test "parseArgs: --project path (separate value)" {
    const argv = [_][]const u8{ "-p", "tsconfig.json" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqualStrings("tsconfig.json", opts.project.?);
}

test "parseArgs: --target / --module / --moduleResolution / --outDir / --jsx" {
    const argv = [_][]const u8{ "--target=es2022", "--module=esnext", "--moduleResolution=bundler", "--baseUrl=.", "--outDir=dist", "--jsx=react-jsx" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqualStrings("es2022", opts.target.?);
    try T.expectEqualStrings("esnext", opts.module.?);
    try T.expectEqualStrings("bundler", opts.module_resolution.?);
    try T.expectEqualStrings(".", opts.base_url.?);
    try T.expectEqualStrings("dist", opts.out_dir.?);
    try T.expectEqualStrings("react-jsx", opts.jsx.?);
}

test "parseArgs: incremental output options" {
    const argv = [_][]const u8{ "--incremental", "--outFile", "bundle.js", "--tsBuildInfoFile=.cache/build.tsbuildinfo" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(?bool, true), opts.incremental);
    try T.expectEqualStrings("bundle.js", opts.out_file.?);
    try T.expectEqualStrings(".cache/build.tsbuildinfo", opts.ts_buildinfo_file.?);
}

test "parseArgs: modern module-resolution booleans are accepted on the command line" {
    const argv = [_][]const u8{
        "--allowArbitraryExtensions",
        "--allowImportingTsExtensions",
        "--rewriteRelativeImportExtensions",
        "--noCheck",
        "--emitDeclarationOnly",
        "--inlineSourceMap",
        "--assumeChangesOnlyAffectDirectDependencies",
    };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 0), opts.parse_diagnostic_count);
    try T.expectEqual(@as(?bool, true), opts.allow_arbitrary_extensions);
    try T.expectEqual(@as(?bool, true), opts.allow_importing_ts_extensions);
    try T.expectEqual(@as(?bool, true), opts.rewrite_relative_import_extensions);
    try T.expectEqual(@as(?bool, true), opts.no_check);
    try T.expectEqual(@as(?bool, true), opts.emit_declaration_only);
    try T.expectEqual(@as(?bool, true), opts.inline_source_map);
    try T.expectEqual(@as(?bool, true), opts.assume_changes_only_affect_direct_dependencies);
}

test "parseArgs: --pretty and --no-pretty" {
    {
        const argv = [_][]const u8{"--pretty"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, true), opts.pretty);
    }
    {
        const argv = [_][]const u8{"--no-pretty"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, false), opts.pretty);
    }
}

test "parseArgs: --pretty default + tsc_main resolution semantics" {
    // No flag -> null (auto). tsc_main resolves null/true to pretty,
    // and only `--no-pretty` (opts.pretty == false) falls back to the
    // single-line `formatDefault` shape — this test pins down both
    // halves of that resolution rule so the wiring can't drift.
    const argv = [_][]const u8{};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(?bool, null), opts.pretty);
    try T.expect((opts.pretty orelse true) == true);

    const argv_no = [_][]const u8{"--no-pretty"};
    const opts_no = try parseArgs(T.allocator, &argv_no);
    defer T.allocator.free(opts_no.files);
    try T.expect((opts_no.pretty orelse true) == false);
}

test "parseArgs: --sourceMap / --no-sourceMap" {
    {
        const argv = [_][]const u8{"--sourceMap"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, true), opts.source_map);
    }
    {
        const argv = [_][]const u8{"--no-sourceMap"};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(?bool, false), opts.source_map);
    }
}

test "parseArgs: --strict" {
    const argv = [_][]const u8{"--strict"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(?bool, true), opts.strict);
}

test "parseArgs: --version sets show_version" {
    const argv = [_][]const u8{"--version"};
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.show_version);
}

test "parseArgs: --help / -h / -?" {
    const variants = [_][]const u8{ "--help", "-h", "-?" };
    for (variants) |flag| {
        const argv = [_][]const u8{flag};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expect(opts.show_help);
    }
}

test "parseArgs: mixed flags + files" {
    const argv = [_][]const u8{ "--noEmit", "a.ts", "--strict", "b.ts" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.no_emit);
    try T.expectEqual(@as(?bool, true), opts.strict);
    try T.expectEqual(@as(usize, 2), opts.files.len);
    try T.expectEqualStrings("a.ts", opts.files[0]);
    try T.expectEqualStrings("b.ts", opts.files[1]);
}

test "parseArgs: --listFiles / --listFilesOnly / --explainFiles / --showConfig / --init" {
    const argv = [_][]const u8{ "--listFiles", "--listFilesOnly", "--explainFiles", "--showConfig", "--init" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.list_files);
    try T.expect(opts.list_files_only);
    try T.expect(opts.explain_files);
    try T.expect(opts.show_config);
    try T.expect(opts.init_config);
}

test "parseArgs: build-only options outside build report TS5093" {
    const argv = [_][]const u8{ "--clean", "--dry", "--force", "--verbose" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 4), opts.parse_diagnostic_count);
    const expected = [_][]const u8{ "clean", "dry", "force", "verbose" };
    for (expected, 0..) |name, i| {
        try T.expectEqual(@as(u32, 5093), opts.parse_diagnostics[i].code);
        try T.expectEqualStrings(name, opts.parse_diagnostics[i].option);
        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[i]);
        defer T.allocator.free(text);
        try T.expect(std.mem.indexOf(u8, text, "may only be used with '--build'") != null);
    }
}

test "parseArgs: --build after another option reports TS6369" {
    const argv = [_][]const u8{ "--pretty", "--build" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 1), opts.parse_diagnostic_count);
    try T.expectEqual(@as(u32, 6369), opts.parse_diagnostics[0].code);
    const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[0]);
    defer T.allocator.free(text);
    try T.expectEqualStrings("error TS6369: Option '--build' must be the first command line argument.", text);
}

test "parseArgs: build mode reports unknown build options and suggestions" {
    const argv = [_][]const u8{ "--build", "--invalidOption", "--verbse" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.build);
    try T.expectEqual(@as(u8, 2), opts.parse_diagnostic_count);
    try T.expectEqual(@as(u32, 5072), opts.parse_diagnostics[0].code);
    try T.expectEqualStrings("--invalidOption", opts.parse_diagnostics[0].option);
    {
        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[0]);
        defer T.allocator.free(text);
        try T.expectEqualStrings("error TS5072: Unknown build option '--invalidOption'.", text);
    }
    try T.expectEqual(@as(u32, 5077), opts.parse_diagnostics[1].code);
    try T.expectEqualStrings("verbose", opts.parse_diagnostics[1].suggestion.?);
    {
        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[1]);
        defer T.allocator.free(text);
        try T.expectEqualStrings("error TS5077: Unknown build option '--verbse'. Did you mean 'verbose'?", text);
    }
}

test "parseArgs: build mode reports TS6370 for nonsensical option pairs" {
    const argv = [_][]const u8{ "--build", "--clean", "--force", "--verbose", "--watch" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 3), opts.parse_diagnostic_count);
    const expected = [_][2][]const u8{
        .{ "clean", "force" },
        .{ "clean", "verbose" },
        .{ "clean", "watch" },
    };
    for (expected, 0..) |pair, i| {
        try T.expectEqual(@as(u32, 6370), opts.parse_diagnostics[i].code);
        try T.expectEqualStrings(pair[0], opts.parse_diagnostics[i].option);
        try T.expectEqualStrings(pair[1], opts.parse_diagnostics[i].expected);
    }
    const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[0]);
    defer T.allocator.free(text);
    try T.expectEqualStrings("error TS6370: Options 'clean' and 'force' cannot be combined.", text);
}

test "parseArgs: build mode defaults project and accepts common build compiler options" {
    const argv = [_][]const u8{
        "--build",
        "--listEmittedFiles",
        "--diagnostics",
        "--extendedDiagnostics",
        "--traceResolution",
        "--preserveWatchOutput",
        "--noEmit",
        "false",
        "--emitDeclarationOnly",
        "--inlineSourceMap",
        "--noCheck",
        "--assumeChangesOnlyAffectDirectDependencies",
        "--locale",
        "en-us",
        "--generateTrace",
        ".trace",
    };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.build);
    try T.expectEqual(@as(u8, 0), opts.parse_diagnostic_count);
    try T.expectEqual(@as(usize, 1), opts.files.len);
    try T.expectEqualStrings(".", opts.files[0]);
    try T.expect(opts.list_emitted_files);
    try T.expect(opts.diagnostics);
    try T.expect(opts.extended_diagnostics);
    try T.expect(opts.trace_resolution);
    try T.expect(opts.preserve_watch_output);
    try T.expect(!opts.no_emit);
    try T.expectEqual(@as(?bool, true), opts.emit_declaration_only);
    try T.expectEqual(@as(?bool, true), opts.inline_source_map);
    try T.expectEqual(@as(?bool, true), opts.no_check);
    try T.expectEqual(@as(?bool, true), opts.assume_changes_only_affect_direct_dependencies);
    try T.expectEqualStrings("en-us", opts.locale.?);
    try T.expectEqualStrings(".trace", opts.generate_trace.?);
}

test "parseArgs: tsconfig-only options on command line report TS6064 and TS6230" {
    const argv = [_][]const u8{ "--composite", "--paths", "src/*", "--rootDirs=null", "--disableSolutionSearching", "false" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 2), opts.parse_diagnostic_count);
    try T.expectEqual(@as(u32, 6230), opts.parse_diagnostics[0].code);
    try T.expectEqualStrings("composite", opts.parse_diagnostics[0].option);
    {
        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[0]);
        defer T.allocator.free(text);
        try T.expectEqualStrings("error TS6230: Option 'composite' can only be specified in 'tsconfig.json' file or set to 'false' or 'null' on command line.", text);
    }
    try T.expectEqual(@as(u32, 6064), opts.parse_diagnostics[1].code);
    try T.expectEqualStrings("paths", opts.parse_diagnostics[1].option);
    {
        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[1]);
        defer T.allocator.free(text);
        try T.expectEqualStrings("error TS6064: Option 'paths' can only be specified in 'tsconfig.json' file or set to 'null' on command line.", text);
    }
}

test "parseArgs: missing string compiler option values report TS6044" {
    const cases = [_]struct { flag: []const u8, option: []const u8 }{
        .{ .flag = "--project", .option = "project" },
        .{ .flag = "-p", .option = "project" },
        .{ .flag = "--target", .option = "target" },
        .{ .flag = "--moduleResolution", .option = "moduleResolution" },
        .{ .flag = "--baseUrl", .option = "baseUrl" },
        .{ .flag = "--locale", .option = "locale" },
        .{ .flag = "--generateCpuProfile", .option = "generateCpuProfile" },
        .{ .flag = "--generateTrace", .option = "generateTrace" },
        .{ .flag = "--outDir", .option = "outDir" },
        .{ .flag = "--outFile", .option = "outFile" },
        .{ .flag = "--tsBuildInfoFile", .option = "tsBuildInfoFile" },
        .{ .flag = "--module", .option = "module" },
        .{ .flag = "--jsx", .option = "jsx" },
    };
    for (cases) |entry| {
        const argv = [_][]const u8{entry.flag};
        const opts = try parseArgs(T.allocator, &argv);
        defer T.allocator.free(opts.files);
        try T.expectEqual(@as(u8, 1), opts.parse_diagnostic_count);
        try T.expectEqual(@as(u32, 6044), opts.parse_diagnostics[0].code);
        try T.expectEqualStrings(entry.option, opts.parse_diagnostics[0].option);

        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[0]);
        defer T.allocator.free(text);
        var expected_buf: [96]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "error TS6044: Compiler option '{s}' expects an argument.", .{entry.option});
        try T.expectEqualStrings(expected, text);
    }
}

test "parseArgs: unknown compiler options report TS5023 and TS5025" {
    const argv = [_][]const u8{ "--modul", "--totallyUnknown" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 2), opts.parse_diagnostic_count);

    try T.expectEqual(@as(u32, 5025), opts.parse_diagnostics[0].code);
    try T.expectEqualStrings("modul", opts.parse_diagnostics[0].option);
    try T.expectEqualStrings("module", opts.parse_diagnostics[0].suggestion.?);
    {
        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[0]);
        defer T.allocator.free(text);
        try T.expectEqualStrings("error TS5025: Unknown compiler option 'modul'. Did you mean 'module'?", text);
    }

    try T.expectEqual(@as(u32, 5023), opts.parse_diagnostics[1].code);
    try T.expectEqualStrings("totallyUnknown", opts.parse_diagnostics[1].option);
    {
        const text = try formatCliDiagnostic(T.allocator, opts.parse_diagnostics[1]);
        defer T.allocator.free(text);
        try T.expectEqualStrings("error TS5023: Unknown compiler option 'totallyUnknown'.", text);
    }
}

test "parseArgs: build mode reports TS5073 and TS5094 option mismatches" {
    const argv = [_][]const u8{ "--build", "--generateTrace", "--tsBuildInfoFile", "cache.tsbuildinfo", "--strict" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 3), opts.parse_diagnostic_count);
    try T.expectEqual(@as(u32, 5073), opts.parse_diagnostics[0].code);
    try T.expectEqualStrings("generateTrace", opts.parse_diagnostics[0].option);
    try T.expectEqualStrings("string", opts.parse_diagnostics[0].expected);
    try T.expectEqual(@as(u32, 5094), opts.parse_diagnostics[1].code);
    try T.expectEqualStrings("tsBuildInfoFile", opts.parse_diagnostics[1].option);
    try T.expectEqual(@as(u32, 5094), opts.parse_diagnostics[2].code);
    try T.expectEqualStrings("strict", opts.parse_diagnostics[2].option);
    try T.expectEqual(@as(usize, 1), opts.files.len);
    try T.expectEqualStrings("cache.tsbuildinfo", opts.files[0]);
}

test "parseArgs: build mode rejects command-line-only and module-resolution-only options" {
    const argv = [_][]const u8{ "--build", "--project", "tsconfig.json", "--showConfig", "--init", "--version", "--all", "--moduleResolution", "bundler", "--allowArbitraryExtensions" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expectEqual(@as(u8, 7), opts.parse_diagnostic_count);
    const expected = [_][]const u8{ "project", "showConfig", "init", "version", "all", "moduleResolution", "allowArbitraryExtensions" };
    for (expected, 0..) |name, i| {
        try T.expectEqual(@as(u32, 5094), opts.parse_diagnostics[i].code);
        try T.expectEqualStrings(name, opts.parse_diagnostics[i].option);
    }
    try T.expectEqual(@as(usize, 2), opts.files.len);
    try T.expectEqualStrings("tsconfig.json", opts.files[0]);
    try T.expectEqualStrings("bundler", opts.files[1]);
}

test "parseArgs: build mode accepts build bool options and projects" {
    const argv = [_][]const u8{ "--build", "--dry", "--force", "-v", "--stopBuildOnErrors", "packages/a" };
    const opts = try parseArgs(T.allocator, &argv);
    defer T.allocator.free(opts.files);
    try T.expect(opts.build);
    try T.expect(!opts.build_clean);
    try T.expect(opts.build_dry);
    try T.expect(opts.build_force);
    try T.expect(opts.build_verbose);
    try T.expect(opts.build_stop_on_errors);
    try T.expectEqual(@as(u8, 0), opts.parse_diagnostic_count);
    try T.expectEqual(@as(usize, 1), opts.files.len);
    try T.expectEqualStrings("packages/a", opts.files[0]);

    const clean_argv = [_][]const u8{ "--build", "--clean", "packages/b" };
    const clean_opts = try parseArgs(T.allocator, &clean_argv);
    defer T.allocator.free(clean_opts.files);
    try T.expect(clean_opts.build_clean);
    try T.expectEqual(@as(u8, 0), clean_opts.parse_diagnostic_count);
}

test "option help metadata includes upstream message diagnostics" {
    const show_config = tsconfig_mod.compilerOptionMessageDiagnostic("showConfig").?;
    try T.expectEqual(@as(u32, 1350), show_config.code);
    try T.expectEqualStrings("Print the final configuration instead of building.", show_config.message);

    const preserve_value_imports = tsconfig_mod.compilerOptionMessageDiagnostic("preserveValueImports").?;
    try T.expectEqual(@as(u32, 1449), preserve_value_imports.code);

    const module_detection_default = tsconfig_mod.compilerOptionMessageDiagnostic("moduleDetection.default").?;
    try T.expectEqual(@as(u32, 1476), module_detection_default.code);

    const newline = tsconfig_mod.compilerOptionMessageDiagnostic("newLine").?;
    try T.expectEqual(@as(u32, 6060), newline.code);

    const experimental_decorators = tsconfig_mod.compilerOptionMessageDiagnostic("experimentalDecorators").?;
    try T.expectEqual(@as(u32, 6065), experimental_decorators.code);

    const init = tsconfig_mod.compilerOptionMessageDiagnostic("init").?;
    try T.expectEqual(@as(u32, 6070), init.code);

    const suppress_excess = tsconfig_mod.compilerOptionMessageDiagnostic("suppressExcessPropertyErrors").?;
    try T.expectEqual(@as(u32, 6072), suppress_excess.code);

    const pretty_legacy = tsconfig_mod.compilerOptionMessageDiagnostic("pretty.legacy").?;
    try T.expectEqual(@as(u32, 6073), pretty_legacy.code);

    const base_url = tsconfig_mod.compilerOptionMessageDiagnostic("baseUrl").?;
    try T.expectEqual(@as(u32, 6083), base_url.code);

    const build = tsconfig_mod.compilerOptionMessageDiagnostic("build").?;
    try T.expectEqual(@as(u32, 6302), build.code);

    const ts_build_info = tsconfig_mod.compilerOptionMessageDiagnostic("tsBuildInfoFile").?;
    try T.expectEqual(@as(u32, 6380), ts_build_info.code);
}

test "dispatch: --version returns versionText to stdout" {
    var opts: Options = .{};
    opts.show_version = true;
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.success, r.code);
    try T.expect(std.mem.indexOf(u8, r.stdout_text, "home tsc") != null);
}

test "dispatch: --help returns helpText to stdout" {
    var opts: Options = .{};
    opts.show_help = true;
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.success, r.code);
    try T.expect(std.mem.indexOf(u8, r.stdout_text, "Usage:") != null);
}

test "dispatch: --init returns TS6071 success message" {
    var opts: Options = .{};
    opts.init_config = true;
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.success, r.code);
    try T.expect(std.mem.indexOf(u8, r.stdout_text, "TS6071") != null);
}

test "dispatch: missing input is a config error" {
    const opts: Options = .{};
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.config_error, r.code);
    try T.expect(std.mem.indexOf(u8, r.stderr_text, "no input files") != null);
}

test "dispatch: --project sets up a compile run" {
    var opts: Options = .{};
    opts.project = "tsconfig.json";
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.success, r.code);
}

test "dispatch: --project with source files reports TS5042" {
    const files = [_][]const u8{"src/main.ts"};
    var opts: Options = .{ .files = &files };
    opts.project = "tsconfig.json";
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.config_error, r.code);
    try T.expect(std.mem.indexOf(u8, r.stderr_text, "TS5042") != null);
}

test "dispatch: --incremental without config, outFile, or tsBuildInfoFile reports TS5074" {
    const files = [_][]const u8{"src/main.ts"};
    var opts: Options = .{ .files = &files, .incremental = true };
    const r = dispatch(opts);
    try T.expectEqual(ExitCode.config_error, r.code);
    try T.expect(std.mem.indexOf(u8, r.stderr_text, "TS5074") != null);

    opts.ts_buildinfo_file = ".cache/build.tsbuildinfo";
    const ok = dispatch(opts);
    try T.expectEqual(ExitCode.success, ok.code);
}

test "formatProjectDiagnostic: project and file diagnostics mirror upstream messages" {
    const cases = [_]ProjectDiagnostic{
        projectDiagnostic(.host_unsupported_option, "watch", ""),
        projectDiagnostic(.cannot_read_file_with_reason, "tsconfig.json", "Permission denied"),
        projectDiagnostic(.cannot_read_file, "tsconfig.json", ""),
        projectDiagnostic(.could_not_write_file, "dist/out.js", "EACCES"),
        projectDiagnostic(.config_already_defined, "/repo/tsconfig.json", ""),
        projectDiagnostic(.cannot_find_config_at_directory, "packages/app", ""),
        projectDiagnostic(.specified_path_does_not_exist, "missing/tsconfig.json", ""),
        projectDiagnostic(.add_tsconfig_json, "", ""),
        projectDiagnostic(.cannot_find_config_at_current_directory, "/repo", ""),
        projectDiagnostic(.file_not_found, "src/missing.ts", ""),
        projectDiagnostic(.unsupported_extension, "src/style.css", "'.ts', '.tsx', '.d.ts', '.js', '.jsx'"),
    };
    const expected_codes = [_]u32{ 5001, 5012, 5083, 5033, 5054, 5057, 5058, 5068, 5081, 6053, 6054 };
    for (cases, expected_codes) |diag, code| {
        try T.expectEqual(code, diag.code);
        const text = try formatProjectDiagnostic(T.allocator, diag);
        defer T.allocator.free(text);
        var code_buf: [16]u8 = undefined;
        const code_text = try std.fmt.bufPrint(&code_buf, "TS{d}", .{code});
        try T.expect(std.mem.indexOf(u8, text, code_text) != null);
    }
}

test "formatBuildStatusDiagnostic: build graph messages mirror upstream codes" {
    const cases = [_]struct {
        diag: BuildStatusDiagnostic,
        code: u32,
        fragment: []const u8,
    }{
        .{
            .diag = .{ .kind = .output_older_than_input, .project = "packages/a", .output = "dist/a.js", .input = "src/a.ts" },
            .code = 6350,
            .fragment = "output 'dist/a.js' is older than input 'src/a.ts'",
        },
        .{
            .diag = .{ .kind = .projects_in_build, .files = "packages/a, packages/b" },
            .code = 6355,
            .fragment = "Projects in this build: packages/a, packages/b",
        },
        .{
            .diag = .{ .kind = .skipped_dependency_errors, .project = "packages/app", .dependency = "packages/lib" },
            .code = 6362,
            .fragment = "because its dependency 'packages/lib' has errors",
        },
        .{
            .diag = .{ .kind = .version_mismatch, .project = "packages/app", .version = "5.9.3", .current_version = "6.0.0-dev" },
            .code = 6381,
            .fragment = "generated with version '5.9.3' that differs with current version '6.0.0-dev'",
        },
        .{
            .diag = .{ .kind = .buildinfo_root_removed, .project = "packages/app", .buildinfo_file = ".tsbuildinfo", .input = "src/old.ts" },
            .code = 6412,
            .fragment = "file 'src/old.ts' was root file of compilation but not any more.",
        },
        .{
            .diag = .{ .kind = .out_of_date_reason, .project = "packages/app", .reason = "compilerOptions changed" },
            .code = 6420,
            .fragment = "because compilerOptions changed.",
        },
    };
    for (cases) |case| {
        try T.expectEqual(case.code, buildStatusCode(case.diag.kind));
        const text = try formatBuildStatusDiagnostic(T.allocator, case.diag);
        defer T.allocator.free(text);
        var code_buf: [16]u8 = undefined;
        const code_text = try std.fmt.bufPrint(&code_buf, "TS{d}", .{case.code});
        try T.expect(std.mem.indexOf(u8, text, code_text) != null);
        try T.expect(std.mem.indexOf(u8, text, case.fragment) != null);
    }
}

test "dispatch: invalid custom-type option values report TS6046" {
    {
        var opts: Options = .{ .files = &.{"src/main.ts"} };
        opts.target = "tomorrow-script";
        const r = dispatch(opts);
        try T.expectEqual(ExitCode.config_error, r.code);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "TS6046") != null);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "Argument for '--target' option must be") != null);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "'es2024'") != null);
    }
    {
        var opts: Options = .{ .files = &.{"src/main.ts"} };
        opts.module = "sandwich";
        const r = dispatch(opts);
        try T.expectEqual(ExitCode.config_error, r.code);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "Argument for '--module' option must be") != null);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "'nodenext'") != null);
    }
    {
        var opts: Options = .{ .files = &.{"src/main.ts"} };
        opts.module_resolution = "telepathy";
        const r = dispatch(opts);
        try T.expectEqual(ExitCode.config_error, r.code);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "Argument for '--moduleResolution' option must be") != null);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "'bundler'") != null);
    }
    {
        var opts: Options = .{ .files = &.{"src/main.ts"} };
        opts.jsx = "sparkles";
        const r = dispatch(opts);
        try T.expectEqual(ExitCode.config_error, r.code);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "Argument for '--jsx' option must be") != null);
        try T.expect(std.mem.indexOf(u8, r.stderr_text, "'react-jsxdev'") != null);
    }
}
