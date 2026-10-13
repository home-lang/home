const std = @import("std");

/// SQLite amalgamation compile flags (Bun's feature set: fast, small,
/// threadsafe). Used only when statically compiling the vendored sqlite3.c.
pub const sqlite_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_ENABLE_COLUMN_METADATA=1",
    "-DSQLITE_MAX_VARIABLE_NUMBER=250000",
    "-DSQLITE_ENABLE_RTREE=1",
    "-DSQLITE_ENABLE_FTS3=1",
    "-DSQLITE_ENABLE_FTS3_PARENTHESIS=1",
    "-DSQLITE_ENABLE_FTS5=1",
    "-DSQLITE_ENABLE_JSON1=1",
    "-DSQLITE_ENABLE_MATH_FUNCTIONS=1",
    "-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1",
    "-DSQLITE_UDL_CAPABLE_PARSER=1",
    "-DSQLITE_DQS=0",
    "-Wno-incompatible-pointer-types-discards-qualifiers",
};

/// Wire SQLite into `module` the Bun way: translate-c the vendored header for
/// every target (so no system <sqlite3.h> is required, even cross-compiling),
/// then link the system libsqlite3 on macOS or statically compile the vendored
/// amalgamation on Linux/Windows. `pkg_root` is this package's directory as a
/// LazyPath, so the helper works whether built standalone or vendored elsewhere.
pub fn addSqlite(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const sqlite_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("c", sqlite_c.createModule());
    module.link_libc = true;
    if (target.result.os.tag == .macos) {
        module.linkSystemLibrary("sqlite3", .{});
    } else {
        module.addCSourceFile(.{
            .file = b.path("vendor/sqlite3.c"),
            .flags = &sqlite_flags,
        });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public modules. Every auxiliary module receives the same database root
    // that the installed library uses, so tests cannot accidentally compile a
    // different SQLite/libc graph than consumers.
    const database_module = b.addModule("database", .{
        .root_source_file = b.path("src/database.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(b, database_module, target, optimize);

    const migrations_module = b.addModule("migrations", .{
        .root_source_file = b.path("src/migrations.zig"),
        .target = target,
        .optimize = optimize,
    });
    migrations_module.addImport("database", database_module);

    const mysql_module = b.addModule("mysql", .{
        .root_source_file = b.path("src/mysql.zig"),
        .target = target,
        .optimize = optimize,
    });
    const postgres_module = b.addModule("postgres", .{
        .root_source_file = b.path("src/postgres.zig"),
        .target = target,
        .optimize = optimize,
    });
    const redis_module = b.addModule("redis", .{
        .root_source_file = b.path("src/redis.zig"),
        .target = target,
        .optimize = optimize,
    });
    const orm_module = b.addModule("orm", .{
        .root_source_file = b.path("src/orm.zig"),
        .target = target,
        .optimize = optimize,
    });
    orm_module.addImport("database", database_module);
    const typed_orm_module = b.addModule("typed_orm", .{
        .root_source_file = b.path("src/typed_orm.zig"),
        .target = target,
        .optimize = optimize,
    });
    typed_orm_module.addImport("database", database_module);

    const lib = b.addLibrary(.{
        .name = "database",
        .linkage = .static,
        .root_module = database_module,
    });
    b.installArtifact(lib);

    const public_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/database_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    public_tests.root_module.addImport("database", database_module);
    public_tests.root_module.addImport("migrations", migrations_module);
    public_tests.root_module.addImport("orm", orm_module);
    public_tests.root_module.addImport("typed_orm", typed_orm_module);

    const compile_tests = [_]*std.Build.Step.Compile{
        b.addTest(.{ .root_module = database_module }),
        b.addTest(.{ .root_module = migrations_module }),
        b.addTest(.{ .root_module = mysql_module }),
        b.addTest(.{ .root_module = postgres_module }),
        b.addTest(.{ .root_module = redis_module }),
        b.addTest(.{ .root_module = orm_module }),
        b.addTest(.{ .root_module = typed_orm_module }),
        public_tests,
    };

    const check_step = b.step("check", "Compile the shipped database library and every public module test");
    check_step.dependOn(&lib.step);

    const test_step = b.step("test", "Run database tests");
    for (compile_tests) |test_artifact| {
        check_step.dependOn(&test_artifact.step);
        test_step.dependOn(&b.addRunArtifact(test_artifact).step);
    }
}
