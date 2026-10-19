const std = @import("std");
const build_pipeline = @import("build_pipeline.zig");
const integration_tests = @import("integration_tests.zig");

test {
    _ = build_pipeline;
    _ = @import("cross_compilation.zig");
    _ = @import("file_watcher.zig");
    _ = @import("incremental_test.zig");
    _ = @import("kernel_build.zig");
    _ = integration_tests;
    _ = @import("linker_script.zig");
    _ = @import("packaging.zig");
    _ = @import("parallel_build.zig");

    std.testing.refAllDecls(build_pipeline.BuildPipeline);
    std.testing.refAllDecls(integration_tests.IntegrationTestRunner);
    std.testing.refAllDecls(integration_tests.Scenarios);
}
