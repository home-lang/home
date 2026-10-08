//! Resolve the `tsconfig.json` graph embedded in a TypeScript harness fixture.
//!
//! The upstream runner mounts every `@filename:` section in a virtual file
//! system and asks the normal config parser to expand `extends`.  Keeping this
//! adapter separate from the conformance runner makes the input boundary
//! explicit: compiler options come from the mounted config graph, never from
//! expected diagnostics.

const std = @import("std");
const tsconfig = @import("tsconfig");
const ts_resolver = @import("ts_resolver");

pub const File = struct {
    path: []const u8,
    source: []const u8,
};

pub const Failure = struct {
    kind: Kind,
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

const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    files: []const File,
    package_resolver: *ts_resolver.Resolver,
    stack: std.ArrayListUnmanaged([]const u8) = .empty,

    fn resolveFile(self: *Context, requested_path: []const u8) !Resolution {
        const config_path = try canonicalPath(self.arena, requested_path);
        for (self.stack.items) |ancestor| {
            if (std.ascii.eqlIgnoreCase(ancestor, config_path)) {
                return .{
                    .config_path = config_path,
                    .failure = .{ .kind = .circular, .path = config_path },
                };
            }
        }

        const file = try self.findFile(config_path) orelse return .{
            .config_path = config_path,
            .failure = .{ .kind = .missing, .path = config_path },
        };
        var own = tsconfig.parseString(self.gpa, self.arena, file.source) catch |err| switch (err) {
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
                .failure = .{ .kind = .missing, .path = try self.arena.dupe(u8, specifier) },
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

    fn findFile(self: *Context, requested_path: []const u8) !?File {
        for (self.files) |file| {
            const path = try canonicalPath(self.arena, file.path);
            if (std.ascii.eqlIgnoreCase(path, requested_path)) return file;
        }
        return null;
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

        const package_resolution = self.package_resolver.resolve(specifier, containing_config) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotFound, error.Ambiguous, error.InvalidSpecifier => null,
        };
        if (package_resolution) |resolved| {
            return try canonicalPath(self.arena, resolved.path);
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
            const package_json = try self.findFile(package_json_path);
            var exports_configured = false;
            if (package_json) |manifest| {
                var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, manifest.source, .{}) catch null;
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
        if (try self.findFile(base) != null) return base;
        if (!std.mem.endsWith(u8, base, ".json")) {
            const json_path = try std.fmt.allocPrint(self.arena, "{s}.json", .{base});
            if (try self.findFile(json_path) != null) return json_path;
        }
        const directory_config = try std.fs.path.resolvePosix(self.arena, &.{ base, "tsconfig.json" });
        if (try self.findFile(directory_config) != null) return directory_config;
        return null;
    }
};

/// Resolve the first virtual file whose basename is `tsconfig.json`, matching
/// the compiler-runner fixture contract. Returned strings and config slices
/// borrow from `arena`.
pub fn resolveRoot(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    files: []const File,
) !Resolution {
    var root_path: ?[]const u8 = null;
    for (files) |file| {
        const canonical = try canonicalPath(arena, file.path);
        if (std.ascii.eqlIgnoreCase(std.fs.path.basename(canonical), "tsconfig.json")) {
            root_path = canonical;
            break;
        }
    }
    if (root_path == null) return .{};

    var vfs = ts_resolver.VirtualFs.init(gpa);
    defer vfs.deinit();
    for (files) |file| {
        const canonical = try canonicalPath(arena, file.path);
        try vfs.addFile(canonical, file.source);
    }
    const config_extensions = [_][]const u8{".json"};
    var package_resolver = ts_resolver.Resolver.init(gpa, vfs.fs(), .{
        .strategy = .node16,
        .module_kind = "esnext",
        .resolve_json = true,
        .extensions = &config_extensions,
    });
    defer package_resolver.deinit();

    var context = Context{
        .gpa = gpa,
        .arena = arena,
        .files = files,
        .package_resolver = &package_resolver,
    };
    defer context.stack.deinit(gpa);
    return context.resolveFile(root_path.?);
}

pub fn formatFailure(gpa: std.mem.Allocator, failure: Failure) ![]u8 {
    return switch (failure.kind) {
        .missing => std.fmt.allocPrint(gpa, "extended tsconfig is missing: {s}", .{failure.path}),
        .circular => std.fmt.allocPrint(gpa, "circular tsconfig extends chain: {s}", .{failure.path}),
        .invalid => std.fmt.allocPrint(gpa, "extended tsconfig is invalid: {s}", .{failure.path}),
    };
}

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

    inline for (.{ "out_dir", "declaration_dir", "root_dir" }) |field_name| {
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
        rebased.compiler_options.root_dirs = try rebasePathOptions(arena, paths, base_path, child_path);
    }
    if (base.compiler_options.type_roots) |paths| {
        rebased.compiler_options.type_roots = try rebasePathOptions(arena, paths, base_path, child_path);
    }
    // `baseUrl` is normalized to an absolute virtual path when each config is
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

fn rebasePathOptions(
    arena: std.mem.Allocator,
    paths: []const []const u8,
    base_path: []const u8,
    child_path: []const u8,
) ![][]const u8 {
    return rebaseSpecs(arena, paths, base_path, child_path);
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

const T = std.testing;

test "virtual tsconfig: extends arrays merge left to right before the child" {
    const files = [_]File{
        .{ .path = "/tsconfig1.json", .source = "{\"compilerOptions\":{\"strictNullChecks\":true,\"noImplicitAny\":false}}" },
        .{ .path = "/tsconfig2.json", .source = "{\"compilerOptions\":{\"noImplicitAny\":true}}" },
        .{ .path = "/tsconfig.json", .source = "{\"extends\":[\"./tsconfig1.json\",\"./tsconfig2.json\"]}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.strict_null_checks);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.no_implicit_any);
}

test "virtual tsconfig: inherited file specs stay relative to their declaring config" {
    const files = [_]File{
        .{ .path = "/base/tsconfig.base.json", .source = "{\"files\":[\"src/a.ts\"],\"include\":[\"generated/**/*\"]}" },
        .{ .path = "/project/tsconfig.json", .source = "{\"extends\":\"../base/tsconfig.base.json\"}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqualStrings("../base/src/a.ts", resolved.config.?.files.?[0]);
    try T.expectEqualStrings("../base/generated/**/*", resolved.config.?.include.?[0]);
}

test "virtual tsconfig: package exports wildcards resolve config bases" {
    const files = [_]File{
        .{ .path = "/node_modules/foo/package.json", .source = "{\"name\":\"foo\",\"exports\":{\"./*.json\":\"./configs/*.json\"}}" },
        .{ .path = "/node_modules/foo/configs/strict.json", .source = "{\"compilerOptions\":{\"strict\":true}}" },
        .{ .path = "/tsconfig.json", .source = "{\"extends\":\"foo/strict.json\"}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.strict);
}

test "virtual tsconfig: package tsconfig fields and defaults resolve config bases" {
    const files = [_]File{
        .{ .path = "/tsconfig.json", .source = "{\"extends\":[\"field\",\"default\"]}" },
        .{ .path = "/node_modules/field/package.json", .source = "{\"tsconfig\":\"./configs/base.json\"}" },
        .{ .path = "/node_modules/field/configs/base.json", .source = "{\"compilerOptions\":{\"strictNullChecks\":true}}" },
        .{ .path = "/node_modules/default/package.json", .source = "{\"name\":\"default\"}" },
        .{ .path = "/node_modules/default/tsconfig.json", .source = "{\"compilerOptions\":{\"noImplicitAny\":true}}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.strict_null_checks);
    try T.expectEqual(@as(?bool, true), resolved.config.?.compiler_options.no_implicit_any);
}

test "virtual tsconfig: missing and circular parents are retained failures" {
    const missing_files = [_]File{
        .{ .path = "/tsconfig.json", .source = "{\"extends\":\"./missing.json\"}" },
    };
    var missing_arena = std.heap.ArenaAllocator.init(T.allocator);
    defer missing_arena.deinit();
    const missing = try resolveRoot(T.allocator, missing_arena.allocator(), &missing_files);
    try T.expectEqual(Failure.Kind.missing, missing.failure.?.kind);

    const circular_files = [_]File{
        .{ .path = "/base.json", .source = "{\"extends\":\"./tsconfig.json\"}" },
        .{ .path = "/tsconfig.json", .source = "{\"extends\":\"./base.json\"}" },
    };
    var circular_arena = std.heap.ArenaAllocator.init(T.allocator);
    defer circular_arena.deinit();
    const circular = try resolveRoot(T.allocator, circular_arena.allocator(), &circular_files);
    try T.expectEqual(Failure.Kind.circular, circular.failure.?.kind);
}

test "virtual tsconfig: inherited paths retain the base config directory" {
    const files = [_]File{
        .{ .path = "/other/tsconfig.base.json", .source = "{\"compilerOptions\":{\"paths\":{\"p1\":[\"./lib/p1\"]}}}" },
        .{ .path = "/project/tsconfig.json", .source = "{\"extends\":\"../other/tsconfig.base.json\"}" },
    };
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const resolved = try resolveRoot(T.allocator, arena.allocator(), &files);
    try T.expect(resolved.failure == null);
    try T.expectEqualStrings("/other", resolved.config.?.compiler_options.base_url.?);
    try T.expectEqualStrings("p1", resolved.config.?.compiler_options.paths.?.patterns[0]);
}
