const std = @import("std");
const testing = std.testing;
const pkg = @import("package_manager");

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var resolver = pkg.DependencyResolver.init(allocator);
    defer resolver.deinit();

    try testing.expectEqual(@as(usize, 0), resolver.dependencies.items.len);
}

test "DependencyResolver: add dependency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var resolver = pkg.DependencyResolver.init(allocator);
    defer resolver.deinit();

    const resolved = try resolver.resolve();
    defer allocator.free(resolved);

    try testing.expectEqual(@as(usize, 0), resolved.len);
}

test "EdgeCase: empty lockfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const packages: []pkg.ResolvedPackage = &[_]pkg.ResolvedPackage{};

    const lock = try pkg.LockFile.create(allocator, packages);
    defer lock.deinit();

    try testing.expectEqual(@as(usize, 0), lock.packages.items.len);
    try testing.expectEqual(@as(u32, 1), lock.version);
}
