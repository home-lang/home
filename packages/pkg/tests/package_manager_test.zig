const std = @import("std");
const testing = std.testing;
const pkg = @import("package_manager");

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
