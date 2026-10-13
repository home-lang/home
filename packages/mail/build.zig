const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mail_module = b.addModule("mail", .{
        .root_source_file = b.path("src/mail.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "mail",
        .linkage = .static,
        .root_module = mail_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = mail_module });
    const public_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mail_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    public_tests.root_module.addImport("mail", mail_module);

    const check_step = b.step("check", "Compile the shipped mail library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&public_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_public_tests = b.addRunArtifact(public_tests);
    const test_step = b.step("test", "Run mail tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_public_tests.step);
}
