const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the notifications module
    const notifications_mod = b.addModule("notifications", .{
        .root_source_file = b.path("src/notifications.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create a library for linking
    const lib = b.addStaticLibrary(.{
        .name = "notifications",
        .root_source_file = b.path("src/notifications.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/notifications.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Email driver tests
    const email_tests = b.addTest(.{
        .root_source_file = b.path("src/drivers/email.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_email_tests = b.addRunArtifact(email_tests);

    // SMS driver tests
    const sms_tests = b.addTest(.{
        .root_source_file = b.path("src/drivers/sms.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_sms_tests = b.addRunArtifact(sms_tests);

    // Push driver tests
    const push_tests = b.addTest(.{
        .root_source_file = b.path("src/drivers/push.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_push_tests = b.addRunArtifact(push_tests);

    // Chat driver tests
    const chat_tests = b.addTest(.{
        .root_source_file = b.path("src/drivers/chat.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_chat_tests = b.addRunArtifact(chat_tests);

    // Test step runs all tests
    const test_step = b.step("test", "Run all notification tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_email_tests.step);
    test_step.dependOn(&run_sms_tests.step);
    test_step.dependOn(&run_push_tests.step);
    test_step.dependOn(&run_chat_tests.step);

    // Export module for other packages
    _ = notifications_mod;
}
