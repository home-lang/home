//! Resolve a `tsconfig.json` together with its `extends` chain.
//!
//! TypeScript loads every config named by `extends` (a path, a package
//! specifier, or an array of either), merges them left to right, and then
//! applies the extending config on top. Path-valued options and file specs
//! stay relative to the config that declared them. `references` are never
//! inherited.
//!
//! The graph walk is host-agnostic: the CLI reads configs from disk and the
//! conformance runner from a harness fixture's virtual files. Both use the
//! same merge, rebase and failure rules, so a project behaves identically in
//! either setting.

const std = @import("std");
const tsconfig = @import("tsconfig.zig");
const ts_resolver = @import("ts_resolver");

pub const Failure = struct {
    kind: Kind,
    /// The config (or extends specifier) that could not be loaded.
    path: []const u8,

    pub const Kind = enum {
        missing,
        circular,
        invalid,
    };
};

pub const Resolution = struct {
    config: ?tsconfig.TsConfig = null,
    config_path: []const u8 = "",
    failure: ?Failure = null,
};

/// Where configs come from. `readFile` returns null for a missing file;
/// returned bytes must stay alive as long as the resolved config (the JSONC
/// parser borrows strings from them). `package_resolver` resolves bare
/// `extends` specifiers such as `@tsconfig/node20/tsconfig.json`.
pub const Host = struct {
    context: *anyopaque,
    readFile: *const fn (context: *anyopaque, path: []const u8) anyerror!?[]const u8,
    package_resolver: ?*ts_resolver.Resolver = null,
};

/// Resolve the config at `config_path` (absolute, POSIX separators) and its
/// complete `extends` graph. All returned strings borrow from `arena`.
pub fn resolve(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    host: Host,
    config_path: []const u8,
) !Resolution {
    var context = Context{ .gpa = gpa, .arena = arena, .host = host };
    defer context.stack.deinit(gpa);
    return context.resolveFile(config_path);
}

/// The `tsc` diagnostic for a failed resolution.
pub fn formatFailure(gpa: std.mem.Allocator, failure: Failure) ![]u8 {
    return switch (failure.kind) {
        .missing => std.fmt.allocPrint(gpa, "error TS5083: Cannot read file '{s}'.", .{failure.path}),
        .circular => std.fmt.allocPrint(gpa, "error TS18000: Circularity detected while resolving configuration: {s}", .{failure.path}),
        .invalid => std.fmt.allocPrint(gpa, "error TS5083: Cannot read file '{s}'.", .{failure.path}),
    };
}

const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    host: Host,
    stack: std.ArrayListUnmanaged([]const u8) = .empty,

    fn resolveFile(self: *Context, requested_path: []const u8) !Resolution {
        const config_path = try canonicalPath(self.arena, requested_path);
        for (self.stack.items) |ancestor| {
            if (std.ascii.eqlIgnoreCase(ancestor, config_path)) {
                return .{
                    .config_path = config_path,
                    .failure = .{ .kind = .circular, .path = try self.circularChain(config_path) },
                };
            }
        }

        const source = try self.read(config_path) orelse return .{
            .config_path = config_path,
            .failure = .{ .kind = .missing, .path = config_path },
        };
        var own = tsconfig.parseString(self.gpa, self.arena, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{
                .config_path = config_path,
                .failure = .{ .kind = .invalid, .path = config_path },
            },
        };
        own.file_path = config_path;
        try normalizeOwnPathOptions(self.arena, &own, config_path);

        try self.stack.append(self.gpa, config_path);
        defer _ = self.stack.pop();

        var inherited: ?tsconfig.TsConfig = null;
        for (own.extends) |specifier| {
            const extended_path = try self.resolveExtendsPath(config_path, specifier) orelse return .{
                .config_path = config_path,
                .failure = .{ .kind = .missing, .path = try self.missingExtendsPath(config_path, specifier) },
            };
            const extended = try self.resolveFile(extended_path);
            if (extended.failure != null) return extended;
            var rebased = try rebaseInheritedConfig(
                self.arena,
                extended.config.?,
                extended.config_path,
                config_path,
            );
            rebased.file_path = config_path;
            // `references` belong to the config that lists them.
            rebased.references = &.{};
            inherited = if (inherited) |prior|
                try tsconfig.merge(self.arena, prior, rebased)
            else
                rebased;
        }

        var resolved = if (inherited) |base|
            try tsconfig.merge(self.arena, base, own)
        else
            own;
        resolved.file_path = config_path;
        resolved.references = own.references;
        // Since TypeScript 4.1, `paths` is legal without `baseUrl`. In that
        // shape its substitutions are relative to the config that declared
        // them. A recursively resolved parent reaches this point before it is
        // rebased into its child, so recording the absolute origin here keeps
        // both direct and inherited mappings faithful.
        if (resolved.compiler_options.paths != null and resolved.compiler_options.base_url == null) {
            resolved.compiler_options.base_url = try self.arena.dupe(u8, dirname(config_path));
        }
        return .{ .config = resolved, .config_path = config_path };
    }

    fn read(self: *Context, path: []const u8) !?[]const u8 {
        return self.host.readFile(self.host.context, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }

    fn exists(self: *Context, path: []const u8) !bool {
        return try self.read(path) != null;
    }

    /// `a -> b -> a`, matching TS18000's chain display.
    fn circularChain(self: *Context, repeated: []const u8) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (self.stack.items) |ancestor| {
            try out.appendSlice(self.arena, ancestor);
            try out.appendSlice(self.arena, " -> ");
        }
        try out.appendSlice(self.arena, repeated);
        return out.items;
    }

    /// TS5083 names the file tsc tried to read. For a relative specifier that
    /// is the joined path (with `.json` appended when absent).
    fn missingExtendsPath(self: *Context, containing_config: []const u8, specifier: []const u8) ![]const u8 {
        if (specifier.len == 0 or (specifier[0] != '.' and specifier[0] != '/')) {
            return self.arena.dupe(u8, specifier);
        }
        const base = if (specifier[0] == '/')
            try canonicalPath(self.arena, specifier)
        else
            try std.fs.path.resolvePosix(self.arena, &.{ dirname(containing_config), specifier });
        if (std.mem.endsWith(u8, base, ".json")) return base;
        return std.fmt.allocPrint(self.arena, "{s}.json", .{base});
    }

    fn resolveExtendsPath(
        self: *Context,
        containing_config: []const u8,
        specifier: []const u8,
    ) !?[]const u8 {
        if (specifier.len == 0) return null;
        if (specifier[0] == '.' or specifier[0] == '/') {
            const base = if (specifier[0] == '/')
                try canonicalPath(self.arena, specifier)
            else
                try std.fs.path.resolvePosix(self.arena, &.{ dirname(containing_config), specifier });
            return try self.firstConfigCandidate(base);
        }

        if (self.host.package_resolver) |package_resolver| {
            const package_resolution = package_resolver.resolve(specifier, containing_config) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotFound, error.Ambiguous, error.InvalidSpecifier => null,
            };
            if (package_resolution) |resolved| {
                return try canonicalPath(self.arena, resolved.path);
            }
        }
        return self.resolvePackageConfigFallback(containing_config, specifier);
    }

    fn resolvePackageConfigFallback(
        self: *Context,
        containing_config: []const u8,
        specifier: []const u8,
    ) !?[]const u8 {
        const split = ts_resolver.packageNameSplit(specifier);
        if (split.name.len == 0) return null;
        var directory = dirname(containing_config);
        while (true) {
            const package_dir = try std.fs.path.resolvePosix(
                self.arena,
                &.{ directory, "node_modules", split.name },
            );
            const package_json_path = try std.fs.path.resolvePosix(
                self.arena,
                &.{ package_dir, "package.json" },
            );
            const package_json = try self.read(package_json_path);
            var exports_configured = false;
            if (package_json) |manifest| {
                var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, manifest, .{}) catch null;
                if (parsed) |*json| {
                    defer json.deinit();
                    if (json.value == .object) {
                        exports_configured = json.value.object.get("exports") != null;
                        if (split.subpath.len == 0) {
                            if (json.value.object.get("tsconfig")) |value| {
                                if (value == .string) {
                                    const target = try std.fs.path.resolvePosix(
                                        self.arena,
                                        &.{ package_dir, value.string },
                                    );
                                    if (try self.firstConfigCandidate(target)) |found| return found;
                                }
                            }
                        }
                    }
                }
            }
            // A package exports map is authoritative. If the normal resolver
            // could not match it, do not bypass that rejection with a legacy
            // direct-file probe.
            if (!exports_configured) {
                const target = if (split.subpath.len == 0)
                    package_dir
                else
                    try std.fs.path.resolvePosix(self.arena, &.{ package_dir, split.subpath });
                if (try self.firstConfigCandidate(target)) |found| return found;
            }

            if (std.mem.eql(u8, directory, "/") or directory.len == 0) break;
            const parent = dirname(directory);
            if (std.mem.eql(u8, parent, directory)) break;
            directory = parent;
        }
        return null;
    }

    fn firstConfigCandidate(self: *Context, base: []const u8) !?[]const u8 {
        if (try self.exists(base)) return base;
        if (!std.mem.endsWith(u8, base, ".json")) {
            const json_path = try std.fmt.allocPrint(self.arena, "{s}.json", .{base});
            if (try self.exists(json_path)) return json_path;
        }
        const directory_config = try std.fs.path.resolvePosix(self.arena, &.{ base, "tsconfig.json" });
        if (try self.exists(directory_config)) return directory_config;
        return null;
    }
};

fn normalizeOwnPathOptions(
    arena: std.mem.Allocator,
    config: *tsconfig.TsConfig,
    config_path: []const u8,
) !void {
    if (config.compiler_options.base_url) |base_url| {
        config.compiler_options.base_url = try resolveFromConfig(arena, config_path, base_url);
    }
}

fn rebaseInheritedConfig(
    arena: std.mem.Allocator,
    base: tsconfig.TsConfig,
    base_path: []const u8,
    child_path: []const u8,
) !tsconfig.TsConfig {
    var rebased = base;
    if (base.files) |specs| rebased.files = try rebaseSpecs(arena, specs, base_path, child_path);
    if (base.include) |specs| rebased.include = try rebaseSpecs(arena, specs, base_path, child_path);
    if (base.exclude) |specs| rebased.exclude = try rebaseSpecs(arena, specs, base_path, child_path);

    inline for (.{ "out_dir", "declaration_dir", "root_dir", "ts_buildinfo_file" }) |field_name| {
        if (@field(base.compiler_options, field_name)) |value| {
            @field(rebased.compiler_options, field_name) = try rebasePathOption(
                arena,
                value,
                base_path,
                child_path,
            );
        }
    }
    if (base.compiler_options.root_dirs) |paths| {
        rebased.compiler_options.root_dirs = try rebaseSpecs(arena, paths, base_path, child_path);
    }
    if (base.compiler_options.type_roots) |paths| {
        rebased.compiler_options.type_roots = try rebaseSpecs(arena, paths, base_path, child_path);
    }
    // `baseUrl` is normalized to an absolute path when each config is
    // parsed, so it already preserves the declaring config's directory.
    return rebased;
}

fn rebaseSpecs(
    arena: std.mem.Allocator,
    specs: []const []const u8,
    base_path: []const u8,
    child_path: []const u8,
) ![][]const u8 {
    const out = try arena.alloc([]const u8, specs.len);
    for (specs, 0..) |spec, index| {
        out[index] = try rebasePathOption(arena, spec, base_path, child_path);
    }
    return out;
}

fn rebasePathOption(
    arena: std.mem.Allocator,
    value: []const u8,
    base_path: []const u8,
    child_path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolutePosix(value)) return value;
    const absolute = try std.fs.path.resolvePosix(arena, &.{ dirname(base_path), value });
    return std.fs.path.relativePosix(arena, "/", dirname(child_path), absolute);
}

fn resolveFromConfig(
    arena: std.mem.Allocator,
    config_path: []const u8,
    value: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolutePosix(value)) return value;
    return std.fs.path.resolvePosix(arena, &.{ dirname(config_path), value });
}

fn canonicalPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolutePosix(path)) return std.fs.path.resolvePosix(arena, &.{path});
    return std.fs.path.resolvePosix(arena, &.{ "/", path });
}

fn dirname(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    if (slash == 0) return "/";
    return path[0..slash];
}

// ---------------------------------------------------------------------------
// Tests: an in-memory host keyed by absolute path.

const T = std.testing;

const MemoryHost = struct {
    files: []const struct { []const u8, []const u8 },

    fn readFile(context: *anyopaque, path: []const u8) anyerror!?[]const u8 {
        const self: *MemoryHost = @ptrCast(@alignCast(context));
        for (self.files) |file| if (std.mem.eql(u8, file[0], path)) return file[1];
        return null;
    }

    fn host(self: *MemoryHost) Host {
        return .{ .context = self, .readFile = readFile };
    }
};

test "config graph: a package config inherits the root compiler options" {
    var memory = MemoryHost{ .files = &.{
        .{ "/repo/tsconfig.json", "{\"compilerOptions\":{\"declaration\":true,\"isolatedDeclarations\":true,\"strict\":true,\"types\":[\"bun\"],\"paths\":{\"craft\":[\"./packages/ts/src/index.ts\"]}}}" },
        .{ "/repo/packages/cli/tsconfig.json", "{\"extends\":\"../../tsconfig.json\",\"compilerOptions\":{\"types\":[\"node\",\"bun\"]},\"include\":[\"bin\"]}" },
    } };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolve(T.allocator, arena.allocator(), memory.host(), "/repo/packages/cli/tsconfig.json");
    try T.expect(resolved.failure == null);
    const config = resolved.config.?;
    const options = config.compiler_options;
    try T.expectEqual(@as(?bool, true), options.declaration);
    try T.expectEqual(@as(?bool, true), options.isolated_declarations);
    try T.expectEqual(@as(?bool, true), options.strict);
    try T.expectEqual(@as(usize, 2), options.types.?.len);
    try T.expectEqualStrings("/repo", options.base_url.?);
    try T.expectEqualStrings("/repo/packages/cli/tsconfig.json", config.file_path);
    try T.expectEqualStrings("bin", config.include.?[0]);
    // The extended config's validation must not see a missing `declaration`.
    const diagnostics = try config.validate(T.allocator);
    defer tsconfig.freeValidationDiagnostics(T.allocator, diagnostics);
    for (diagnostics) |diagnostic| try T.expect(diagnostic.code != 5069);
}

test "config graph: inherited specs and output paths are rebased, references are not inherited" {
    var memory = MemoryHost{ .files = &.{
        .{ "/repo/base/tsconfig.json", "{\"compilerOptions\":{\"outDir\":\"dist\",\"rootDir\":\"src\"},\"include\":[\"src\"],\"references\":[{\"path\":\"../other\"}]}" },
        .{ "/repo/app/tsconfig.json", "{\"extends\":\"../base\"}" },
    } };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolve(T.allocator, arena.allocator(), memory.host(), "/repo/app/tsconfig.json");
    try T.expect(resolved.failure == null);
    const config = resolved.config.?;
    try T.expectEqualStrings("../base/src", config.include.?[0]);
    try T.expectEqualStrings("../base/dist", config.compiler_options.out_dir.?);
    try T.expectEqualStrings("../base/src", config.compiler_options.root_dir.?);
    try T.expectEqual(@as(usize, 0), config.references.len);
}

test "config graph: a chain of local extends applies the nearest override" {
    var memory = MemoryHost{ .files = &.{
        .{ "/p/tsconfig.json", "{\"compilerOptions\":{\"noEmit\":true,\"isolatedDeclarations\":true}}" },
        .{ "/p/tsconfig.build.json", "{\"extends\":\"./tsconfig.json\",\"compilerOptions\":{\"noEmit\":false,\"emitDeclarationOnly\":true,\"declaration\":true}}" },
    } };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolve(T.allocator, arena.allocator(), memory.host(), "/p/tsconfig.build.json");
    const options = resolved.config.?.compiler_options;
    try T.expectEqual(@as(?bool, false), options.no_emit);
    try T.expectEqual(@as(?bool, true), options.emit_declaration_only);
    try T.expectEqual(@as(?bool, true), options.isolated_declarations);
}

test "config graph: missing and circular configs report tsc diagnostics" {
    var missing = MemoryHost{ .files = &.{
        .{ "/p/tsconfig.json", "{\"extends\":\"./base\"}" },
    } };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const missing_result = try resolve(T.allocator, arena.allocator(), missing.host(), "/p/tsconfig.json");
    const missing_message = try formatFailure(T.allocator, missing_result.failure.?);
    defer T.allocator.free(missing_message);
    try T.expectEqualStrings("error TS5083: Cannot read file '/p/base.json'.", missing_message);

    var circular = MemoryHost{ .files = &.{
        .{ "/p/a.json", "{\"extends\":\"./b.json\"}" },
        .{ "/p/b.json", "{\"extends\":\"./a.json\"}" },
    } };
    const circular_result = try resolve(T.allocator, arena.allocator(), circular.host(), "/p/a.json");
    try T.expectEqual(Failure.Kind.circular, circular_result.failure.?.kind);
    try T.expectEqualStrings("/p/a.json -> /p/b.json -> /p/a.json", circular_result.failure.?.path);
}
