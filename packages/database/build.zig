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

    // Module for use as dependency
    const database_module = b.createModule(.{
        .root_source_file = b.path("src/database.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(b, database_module, target, optimize);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/database_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("database", database_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run database tests");
    test_step.dependOn(&run_unit_tests.step);
}
