const std = @import("std");
const testing = std.testing;
const pkg = @import("package_manager");

fn resolveRegisteredVersionsForAllocationFailure(allocator: std.mem.Allocator) !void {
    const Resolver = pkg.AdvancedDependencyResolver;
    const foo_v1 = Resolver.SemanticVersion{ .major = 1, .minor = 0, .patch = 0 };
    const foo_v12 = Resolver.SemanticVersion{ .major = 1, .minor = 2, .patch = 0 };
    const foo_v2 = Resolver.SemanticVersion{ .major = 2, .minor = 0, .patch = 0 };
    const constraint = try Resolver.parseConstraint("^1.0.0");

    var registry = pkg.PackageRegistry.init(allocator);
    defer registry.deinit();
    try registry.addPackage("foo", &.{ foo_v1, foo_v12, foo_v2 });
    const borrowed_name = try allocator.dupe(u8, "metadata-dependency");
    defer allocator.free(borrowed_name);
    try registry.addDependencies("foo", foo_v12, &.{.{ .name = borrowed_name, .constraint = constraint }});
    @memset(borrowed_name, 'x');
    try registry.addDependencies("foo", foo_v12, &.{.{ .name = "replacement-dependency", .constraint = constraint }});
    const cloned_dependencies = try registry.getDependencies("foo", foo_v12);
    defer pkg.PackageRegistry.freeDependencies(allocator, cloned_dependencies);
    try testing.expectEqualStrings("replacement-dependency", cloned_dependencies[0].name);

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.addDependency("root", .{ .name = "foo", .constraint = constraint });
    const solved_once = try resolver.resolve(&registry);
    try testing.expectEqual(@as(usize, 1), solved_once.len);
    allocator.free(solved_once);
    const solved = try resolver.resolve(&registry);
    defer allocator.free(solved);
    try testing.expectEqual(@as(usize, 1), solved.len);
    const foo = resolver.solution.get("foo") orelse return error.MissingResolvedPackage;
    try testing.expectEqual(@as(u32, 1), foo.version.major);
    try testing.expectEqual(@as(u32, 2), foo.version.minor);
    try testing.expectEqualStrings("replacement-dependency", foo.dependencies[0].name);
}

test "AdvancedDependencyResolver: selects a compatible version and owns registry data" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        resolveRegisteredVersionsForAllocationFailure,
        .{},
    );
}

test "AdvancedDependencyResolver: resolver and registry use independent allocators" {
    var registry_debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = registry_debug_allocator.deinit();
    var resolver_debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = resolver_debug_allocator.deinit();

    const Resolver = pkg.AdvancedDependencyResolver;
    var registry = pkg.PackageRegistry.init(registry_debug_allocator.allocator());
    defer registry.deinit();
    try registry.addPackage("foo", &.{.{ .major = 1, .minor = 0, .patch = 0 }});
    try registry.addDependencies("foo", .{ .major = 1, .minor = 0, .patch = 0 }, &.{.{
        .name = "bar",
        .constraint = try Resolver.parseConstraint("^1.0.0"),
    }});

    var resolver = Resolver.init(resolver_debug_allocator.allocator());
    defer resolver.deinit();
    try resolver.addConstraint("foo", try Resolver.parseConstraint("^1.0.0"));
    const result = try resolver.resolve(&registry);
    defer resolver_debug_allocator.allocator().free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("bar", result[0].dependencies[0].name);
}

fn detectCycleForAllocationFailure(allocator: std.mem.Allocator) !void {
    const Resolver = pkg.AdvancedDependencyResolver;
    const exact = try Resolver.parseConstraint("1.0.0");
    var graph = Resolver.DependencyGraph.init(allocator);
    defer graph.deinit();
    try graph.addEdge("a", .{ .name = "b", .constraint = exact });
    try graph.addEdge("b", .{ .name = "c", .constraint = exact });
    try graph.addEdge("c", .{ .name = "a", .constraint = exact });
    const cycle = (try graph.detectCycles()) orelse return error.MissingCycle;
    defer graph.freeCycle(cycle);
    try testing.expectEqual(@as(usize, 4), cycle.len);
}

test "AdvancedDependencyResolver: cycle detection frees partial paths" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        detectCycleForAllocationFailure,
        .{},
    );
}

test "AdvancedDependencyResolver: reports the complete owned cycle" {
    const allocator = testing.allocator;
    const Resolver = pkg.AdvancedDependencyResolver;
    const exact = try Resolver.parseConstraint("1.0.0");
    var graph = Resolver.DependencyGraph.init(allocator);
    defer graph.deinit();
    try graph.addEdge("a", .{ .name = "b", .constraint = exact });
    try graph.addEdge("b", .{ .name = "c", .constraint = exact });
    try graph.addEdge("c", .{ .name = "a", .constraint = exact });
    const cycle = (try graph.detectCycles()) orelse return error.MissingCycle;
    defer graph.freeCycle(cycle);
    try testing.expectEqual(@as(usize, 4), cycle.len);
    try testing.expectEqualStrings(cycle[0], cycle[3]);
    try testing.expect(!std.mem.eql(u8, cycle[0], cycle[1]));
    try testing.expect(!std.mem.eql(u8, cycle[1], cycle[2]));
}

test "AdvancedDependencyResolver: rejects incompatible constraints without leaking" {
    const allocator = testing.allocator;
    const Resolver = pkg.AdvancedDependencyResolver;
    var registry = pkg.PackageRegistry.init(allocator);
    defer registry.deinit();
    try registry.addPackage("foo", &.{.{ .major = 1, .minor = 0, .patch = 0 }});

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
    try resolver.addConstraint("foo", try Resolver.parseConstraint(">=2.0.0"));
    try testing.expectError(error.ConflictingDependencies, resolver.resolve(&registry));
    try testing.expectEqual(@as(usize, 1), resolver.conflicts.items.len);
    try testing.expectError(error.ConflictingDependencies, resolver.resolve(&registry));
    try testing.expectEqual(@as(usize, 1), resolver.conflicts.items.len);
}

test "AdvancedDependencyResolver: rejects extra version components" {
    try testing.expectError(error.InvalidVersion, pkg.AdvancedDependencyResolver.SemanticVersion.parse("1.2.3.4"));
}

fn buildDependencyTreeForAllocationFailure(allocator: std.mem.Allocator) !void {
    var lockfile = pkg.LockFile{
        .allocator = allocator,
        .version = 1,
        .packages = .empty,
    };
    defer lockfile.packages.deinit(allocator);
    try lockfile.packages.append(allocator, .{
        .name = "compiler",
        .version = "1.0.0",
        .checksum = "test",
        .source = .{ .Registry = "https://example.test" },
    });
    try lockfile.packages.append(allocator, .{
        .name = "runtime",
        .version = "2.0.0",
        .checksum = "test",
        .source = .{ .Registry = "https://example.test" },
    });
    var tree = try pkg.buildDependencyTreeFromLockFile(allocator, &lockfile, "root", "3.0.0");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 2), tree.nodes.items.len);
}

test "DependencyTree: owns roots and nodes across allocation failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        buildDependencyTreeForAllocationFailure,
        .{},
    );
}

test "DependencyTree: preserves names and renders deep UTF-8 branches" {
    const allocator = testing.allocator;
    const name = try allocator.dupe(u8, "root");
    defer allocator.free(name);
    var tree = try pkg.DependencyTree.init(allocator, name, "1.0.0");
    defer tree.deinit();
    @memset(name, 'x');
    try testing.expectEqualStrings("root", tree.root_name);

    const child_name = try allocator.dupe(u8, "child");
    defer allocator.free(child_name);
    try tree.addNode(child_name, "2.0.0", 100, true);
    @memset(child_name, 'x');
    try testing.expectEqualStrings("child", tree.nodes.items[0].name);

    tree.render();
    tree.renderCompact();
    var sizes = std.StringHashMap(f64).init(allocator);
    defer sizes.deinit();
    try sizes.put("child", 2.0);
    try tree.renderWithSizes(sizes);
}

fn addScriptsForAllocationFailure(allocator: std.mem.Allocator) !void {
    var runner = pkg.ScriptRunner.initWithIo(allocator, testing.io, "/unused");
    defer runner.deinit();
    try runner.addScript("build", "first");
    try runner.addScript("test", "second");
    try runner.addScript("build", "replacement");
}

fn addProgressForAllocationFailure(allocator: std.mem.Allocator) !void {
    var tracker = try pkg.ProgressTracker.initWithIo(allocator, testing.io, 2);
    defer tracker.deinit();
    _ = try tracker.addPackage("compiler", 1024);
    _ = try tracker.addPackage("runtime", 2048);
}

test "ScriptRunner: owns replacements across allocation failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        addScriptsForAllocationFailure,
        .{},
    );
}

test "ScriptRunner: executes owned commands with explicit IO" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    var runner = pkg.ScriptRunner.initWithIo(allocator, testing.io, root);
    defer runner.deinit();
    const name = try allocator.dupe(u8, "mark");
    defer allocator.free(name);
    const command = try allocator.dupe(u8, "printf old > marker.txt");
    defer allocator.free(command);
    try runner.addScript(name, command);
    @memset(name, 'x');
    @memset(command, 'x');
    try runner.addScript("mark", "printf current > marker.txt");
    try runner.addScript("fail", "exit 7");

    try runner.run("mark");
    const marker = try std.fs.path.join(allocator, &.{ root, "marker.txt" });
    defer allocator.free(marker);
    const contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, marker, allocator, .limited(32));
    defer allocator.free(contents);
    try testing.expectEqualStrings("current", contents);
    try testing.expectError(error.ScriptFailed, runner.run("fail"));
    try testing.expectError(error.ScriptNotFound, runner.run("missing"));
}

test "ProgressTracker: owns names and completes packages once" {
    const allocator = testing.allocator;
    var tracker = try pkg.ProgressTracker.initWithIo(allocator, testing.io, 2);
    defer tracker.deinit();
    const name = try allocator.dupe(u8, "compiler");
    defer allocator.free(name);
    const bar = try tracker.addPackage(name, 1024);
    @memset(name, 'x');

    try testing.expectEqualStrings("compiler", bar.name);
    bar.update(2048);
    try testing.expectEqual(@as(usize, 1024), bar.current);
    try testing.expect(bar.completed);
    try testing.expectEqual(@as(f64, 100.0), bar.getPercent());
    tracker.markComplete(bar);
    tracker.markComplete(bar);
    try testing.expectEqual(@as(usize, 1), tracker.completed_packages);

    const pending = try tracker.addPackage("runtime", 0);
    try testing.expectEqual(@as(f64, 100.0), pending.getPercent());
    tracker.markComplete(pending);
    tracker.markComplete(pending);
    try testing.expectEqual(@as(usize, 2), tracker.completed_packages);
}

test "ProgressTracker: allocation failures release owned bars" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        addProgressForAllocationFailure,
        .{},
    );
}

fn addWorkspacePatternsForAllocationFailure(allocator: std.mem.Allocator) !void {
    var workspace = pkg.Workspace.initWithIo(allocator, testing.io, "/unused");
    defer workspace.deinit();
    try workspace.addPattern("packages/*");
    try workspace.addPattern("apps/*");
    try workspace.addPattern("packages/*");
}

fn findWorkspacePackage(workspace: *pkg.Workspace, name: []const u8) ?*pkg.WorkspacePackage {
    for (workspace.packages.items) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

test "Workspace: owns patterns across allocation failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        addWorkspacePatternsForAllocationFailure,
        .{},
    );
}

test "Workspace: discovers installs links and runs packages with explicit IO" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const package_a = try std.fs.path.join(allocator, &.{ root, "packages", "a" });
    defer allocator.free(package_a);
    const package_b = try std.fs.path.join(allocator, &.{ root, "packages", "b" });
    defer allocator.free(package_b);
    try std.Io.Dir.cwd().createDirPath(testing.io, package_a);
    try std.Io.Dir.cwd().createDirPath(testing.io, package_b);

    const config_a = try std.fs.path.join(allocator, &.{ package_a, "home.toml" });
    defer allocator.free(config_a);
    const config_b = try std.fs.path.join(allocator, &.{ package_b, "home.toml" });
    defer allocator.free(config_b);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = config_a,
        .data =
        \\[dependencies]
        \\b = "workspace:*"
        \\external = "1.0.0"
        \\duplicate = "first"
        \\duplicate = "second"
        \\[scripts]
        \\mark = "printf alpha > marker.txt"
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = config_b,
        .data = "[dependencies]\n",
    });

    var workspace = pkg.Workspace.initWithIo(allocator, testing.io, root);
    defer workspace.deinit();
    const pattern = try allocator.dupe(u8, "packages/*");
    defer allocator.free(pattern);
    try workspace.addPattern(pattern);
    @memset(pattern, 'x');
    try workspace.addPattern("packages/*");
    try testing.expectEqual(@as(usize, 1), workspace.patterns.items.len);

    try workspace.discover();
    try workspace.discover();
    try testing.expectEqual(@as(usize, 2), workspace.packages.items.len);

    try workspace.installAll();
    try workspace.installAll();
    const a = findWorkspacePackage(&workspace, "a") orelse return error.MissingWorkspacePackage;
    try testing.expectEqualStrings("workspace:*", a.dependencies.get("b").?);
    try testing.expectEqualStrings("1.0.0", a.dependencies.get("external").?);
    try testing.expectEqualStrings("second", a.dependencies.get("duplicate").?);

    try workspace.linkPackages();
    const linked_b = try std.fs.path.join(allocator, &.{ package_a, "node_modules", "b" });
    defer allocator.free(linked_b);
    const linked_target = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, linked_b, allocator);
    defer allocator.free(linked_target);
    const expected_target = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, package_b, allocator);
    defer allocator.free(expected_target);
    try testing.expectEqualStrings(expected_target, linked_target);

    try workspace.runAll("mark");
    const marker = try std.fs.path.join(allocator, &.{ package_a, "marker.txt" });
    defer allocator.free(marker);
    const marker_contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, marker, allocator, .limited(32));
    defer allocator.free(marker_contents);
    try testing.expectEqualStrings("alpha", marker_contents);
}

fn addLockfilePackagesForAllocationFailure(allocator: std.mem.Allocator) !void {
    var lockfile = pkg.Lockfile.init(allocator);
    defer lockfile.deinit();

    var dependencies = std.StringHashMap([]const u8).init(allocator);
    defer dependencies.deinit();
    try dependencies.put("parser", "1.0.0");
    try dependencies.put("runtime", "2.0.0");

    try lockfile.addPackage("compiler", .{
        .name = "compiler",
        .version = "1.0.0",
        .resolved = "https://example.test/compiler.tgz",
        .integrity = "sha256-first",
        .dependencies = dependencies,
        .source = .{ .Git = .{
            .url = "https://example.test/compiler.git",
            .commit = "abc123",
        } },
    });
    try lockfile.addPackage("compiler", .{
        .name = "compiler",
        .version = "2.0.0",
        .resolved = "../compiler",
        .integrity = "sha256-second",
        .dependencies = dependencies,
        .source = .{ .Path = "../compiler" },
    });
}

test "Lockfile: package cloning releases every partial allocation" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        addLockfilePackagesForAllocationFailure,
        .{},
    );
}

test "Lockfile: explicit IO round trip escapes data and replaces packages" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "escaped.freezer" });
    defer allocator.free(path);

    var dependencies = std.StringHashMap([]const u8).init(allocator);
    defer dependencies.deinit();
    try dependencies.put("dep\"name", "1\\2");

    var lockfile = pkg.Lockfile.init(allocator);
    defer lockfile.deinit();
    try lockfile.addPackage("pkg\"key", .{
        .name = "quoted \"package\"",
        .version = "1.2.3",
        .resolved = "https://example.test/pkg\\archive",
        .integrity = "sha256-abc",
        .dependencies = dependencies,
        .source = .{ .Git = .{
            .url = "https://example.test/repo\"name.git",
            .commit = "dead\\beef",
        } },
    });
    try lockfile.addPackage("registry", .{
        .name = "registry",
        .version = "3.0.0",
        .resolved = "https://registry.test/pkg",
        .integrity = "sha256-registry",
        .dependencies = dependencies,
        .source = .{ .Registry = "https://registry.test" },
    });
    try lockfile.addPackage("url", .{
        .name = "url",
        .version = "4.0.0",
        .resolved = "https://example.test/direct.tgz",
        .integrity = "sha256-url",
        .dependencies = dependencies,
        .source = .{ .Url = "https://example.test/direct.tgz" },
    });
    try lockfile.saveWithIo(testing.io, path);
    try testing.expect(pkg.Lockfile.existsWithIo(testing.io, path));

    const first_serialization = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(first_serialization);
    try lockfile.saveWithIo(testing.io, path);
    const second_serialization = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(second_serialization);
    try testing.expectEqualStrings(first_serialization, second_serialization);

    var loaded = try pkg.Lockfile.loadWithIo(allocator, testing.io, path);
    defer loaded.deinit();
    const first = loaded.getPackage("pkg\"key").?;
    try testing.expectEqualStrings("quoted \"package\"", first.name);
    try testing.expectEqualStrings("1\\2", first.dependencies.get("dep\"name").?);
    switch (first.source) {
        .Git => |git| {
            try testing.expectEqualStrings("https://example.test/repo\"name.git", git.url);
            try testing.expectEqualStrings("dead\\beef", git.commit);
        },
        else => return error.WrongSourceType,
    }
    switch (loaded.getPackage("registry").?.source) {
        .Registry => |url| try testing.expectEqualStrings("https://registry.test", url),
        else => return error.WrongSourceType,
    }
    switch (loaded.getPackage("url").?.source) {
        .Url => |url| try testing.expectEqualStrings("https://example.test/direct.tgz", url),
        else => return error.WrongSourceType,
    }

    try loaded.addPackage("pkg\"key", .{
        .name = "replacement",
        .version = "2.0.0",
        .resolved = "../replacement",
        .integrity = "sha256-next",
        .dependencies = dependencies,
        .source = .{ .Path = "../replacement" },
    });
    try testing.expectEqual(@as(usize, 3), loaded.packages.count());
    try testing.expectEqualStrings("2.0.0", loaded.getPackage("pkg\"key").?.version);

    // Exercise the compatibility entry points as well as the explicit-I/O API.
    try loaded.save(path);
    var compatibility_loaded = try pkg.Lockfile.load(allocator, path);
    defer compatibility_loaded.deinit();
    try testing.expectEqualStrings("2.0.0", compatibility_loaded.getPackage("pkg\"key").?.version);
}

test "Lockfile: malformed versions fail without retaining allocations" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "invalid.freezer" });
    defer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "{\"version\":-1,\"packages\":{}}",
    });
    try testing.expectError(
        error.InvalidLockfile,
        pkg.Lockfile.loadWithIo(allocator, testing.io, path),
    );
}

// ═══════════════════════════════════════════════════════════════
// Version Type Tests
// ═══════════════════════════════════════════════════════════════

test "Version: semantic version" {
    const version = pkg.Version{
        .semantic = .{
            .major = 1,
            .minor = 2,
            .patch = 3,
        },
    };

    switch (version) {
        .semantic => |sem| {
            try testing.expectEqual(@as(u32, 1), sem.major);
            try testing.expectEqual(@as(u32, 2), sem.minor);
            try testing.expectEqual(@as(u32, 3), sem.patch);
        },
        else => return error.WrongVersionType,
    }
}

test "Version: git version" {
    const version = pkg.Version{ .git = "main" };

    switch (version) {
        .git => |rev| {
            try testing.expectEqualStrings("main", rev.?);
        },
        else => return error.WrongVersionType,
    }
}

test "Version: url version" {
    const version = pkg.Version{ .url = "https://example.com/package.tar.gz" };

    switch (version) {
        .url => |url| {
            try testing.expectEqualStrings("https://example.com/package.tar.gz", url);
        },
        else => return error.WrongVersionType,
    }
}

// ═══════════════════════════════════════════════════════════════
// DependencySource Type Tests
// ═══════════════════════════════════════════════════════════════

test "DependencySource: Registry" {
    const source = pkg.DependencySource{ .Registry = "https://packages.home-lang.org" };

    switch (source) {
        .Registry => |url| {
            try testing.expectEqualStrings("https://packages.home-lang.org", url);
        },
        else => return error.WrongSourceType,
    }
}

test "DependencySource: Git" {
    const source = pkg.DependencySource{
        .Git = .{
            .url = "https://github.com/user/repo.git",
            .rev = "v1.0.0",
        },
    };

    switch (source) {
        .Git => |git| {
            try testing.expectEqualStrings("https://github.com/user/repo.git", git.url);
            try testing.expectEqualStrings("v1.0.0", git.rev.?);
        },
        else => return error.WrongSourceType,
    }
}

test "DependencySource: Url" {
    const source = pkg.DependencySource{ .Url = "https://example.com/package.tar.gz" };

    switch (source) {
        .Url => |url| {
            try testing.expectEqualStrings("https://example.com/package.tar.gz", url);
        },
        else => return error.WrongSourceType,
    }
}

// ═══════════════════════════════════════════════════════════════
// Dependency Tests
// ═══════════════════════════════════════════════════════════════

test "Dependency: create with semantic version" {
    const dep = pkg.Dependency{
        .name = "http-router",
        .version = pkg.Version{
            .semantic = .{
                .major = 1,
                .minor = 0,
                .patch = 0,
            },
        },
        .source = pkg.DependencySource{ .Registry = "https://packages.home-lang.org" },
    };

    try testing.expectEqualStrings("http-router", dep.name);
}

test "Dependency: create with git version" {
    const dep = pkg.Dependency{
        .name = "zyte",
        .version = pkg.Version{ .git = "main" },
        .source = pkg.DependencySource{
            .Git = .{
                .url = "https://github.com/ion-lang/zyte.git",
                .rev = "main",
            },
        },
    };

    try testing.expectEqualStrings("zyte", dep.name);
}

test "Dependency: create with URL" {
    const dep = pkg.Dependency{
        .name = "custom-lib",
        .version = pkg.Version{ .url = "https://example.com/lib.tar.gz" },
        .source = pkg.DependencySource{ .Url = "https://example.com/lib.tar.gz" },
    };

    try testing.expectEqualStrings("custom-lib", dep.name);
}

// ═══════════════════════════════════════════════════════════════
// DependencyResolver Tests
// ═══════════════════════════════════════════════════════════════

test "DependencyResolver: init and deinit" {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var resolver = pkg.DependencyResolver.init(allocator);
    defer resolver.deinit();

    try testing.expectEqual(@as(usize, 0), resolver.dependencies.items.len);
}

test "DependencyResolver: add dependency" {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var resolver = pkg.DependencyResolver.init(allocator);
    defer resolver.deinit();

    const dep = pkg.Dependency{
        .name = "test-pkg",
        .version = pkg.Version{ .semantic = .{ .major = 1, .minor = 0, .patch = 0 } },
        .source = pkg.DependencySource{ .Registry = "https://packages.home-lang.org" },
    };

    try resolver.addDependency(dep);
    try testing.expectEqual(@as(usize, 1), resolver.dependencies.items.len);
}

// ═══════════════════════════════════════════════════════════════
// Edge Case Tests
// ═══════════════════════════════════════════════════════════════

test "EdgeCase: resolve with no dependencies" {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var resolver = pkg.DependencyResolver.init(allocator);
    defer resolver.deinit();

    const resolved = try resolver.resolve();
    defer allocator.free(resolved);

    try testing.expectEqual(@as(usize, 0), resolved.len);
}

test "EdgeCase: empty lockfile" {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const packages: []pkg.ResolvedPackage = &[_]pkg.ResolvedPackage{};

    const lock = try pkg.LockFile.create(allocator, packages);
    defer lock.deinit();

    try testing.expectEqual(@as(usize, 0), lock.packages.items.len);
    try testing.expectEqual(@as(u32, 1), lock.version);
}
