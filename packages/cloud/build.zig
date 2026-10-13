const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cloud_module = b.addModule("cloud", .{
        .root_source_file = b.path("src/cloud.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shipped library
    const lib = b.addLibrary(.{
        .name = "cloud",
        .linkage = .static,
        .root_module = cloud_module,
    });

    b.installArtifact(lib);

    // Exercise the public root and each service that performs request signing.
    // Testing only cloud.zig leaves service methods lazily uninstantiated.
    const test_step = b.step("test", "Run all cloud tests");
    for ([_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "cloud", .path = "src/cloud.zig" },
        .{ .name = "sqs", .path = "src/sqs.zig" },
        .{ .name = "ses", .path = "src/ses.zig" },
        .{ .name = "sns", .path = "src/sns.zig" },
    }) |test_case| {
        const tests = b.addTest(.{
            .name = b.fmt("test-{s}", .{test_case.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_case.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
