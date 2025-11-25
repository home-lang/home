const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // PostgreSQL Module
    // ========================================================================

    const postgresql_module = b.addModule("postgresql", .{
        .root_source_file = b.path("src/postgresql.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Redis Module
    // ========================================================================

    const redis_module = b.addModule("redis", .{
        .root_source_file = b.path("src/redis.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Database Module (combines all drivers)
    // ========================================================================

    const database_module = b.addModule("database", .{
        .root_source_file = b.path("src/database.zig"),
        .target = target,
        .optimize = optimize,
    });
    database_module.addImport("postgresql", postgresql_module);
    database_module.addImport("redis", redis_module);

    // ========================================================================
    // Tests
    // ========================================================================

    // PostgreSQL tests
    const postgresql_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/postgresql_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    postgresql_tests.root_module.addImport("postgresql", postgresql_module);

    const run_postgresql_tests = b.addRunArtifact(postgresql_tests);

    // Redis tests
    const redis_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/redis_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    redis_tests.root_module.addImport("redis", redis_module);

    const run_redis_tests = b.addRunArtifact(redis_tests);

    const test_step = b.step("test", "Run database tests");
    test_step.dependOn(&run_postgresql_tests.step);
    test_step.dependOn(&run_redis_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // PostgreSQL example
    const pg_example = b.addExecutable(.{
        .name = "postgresql_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/postgresql_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pg_example.root_module.addImport("postgresql", postgresql_module);
    b.installArtifact(pg_example);

    const run_pg_example = b.addRunArtifact(pg_example);
    const pg_example_step = b.step("example-postgresql", "Run PostgreSQL example");
    pg_example_step.dependOn(&run_pg_example.step);

    // Redis example
    const redis_example = b.addExecutable(.{
        .name = "redis_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/redis_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    redis_example.root_module.addImport("redis", redis_module);
    b.installArtifact(redis_example);

    const run_redis_example = b.addRunArtifact(redis_example);
    const redis_example_step = b.step("example-redis", "Run Redis example");
    redis_example_step.dependOn(&run_redis_example.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all database examples");
    examples_step.dependOn(&run_pg_example.step);
    examples_step.dependOn(&run_redis_example.step);

    // ========================================================================
    // Documentation
    // ========================================================================

    const docs_install = b.addInstallDirectory(.{
        .source_dir = postgresql_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/database",
    });

    const docs_step = b.step("docs", "Generate database documentation");
    docs_step.dependOn(&docs_install.step);
}
