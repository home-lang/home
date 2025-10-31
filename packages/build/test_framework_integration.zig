const std = @import("std");
const test_framework = @import("zig-test-framework");

test "zig-test-framework is accessible" {
    // Just verify we can import it
    try std.testing.expect(true);
}

test "can use test_framework features" {
    // Verify we can use the framework's types
    const options = test_framework.CoverageOptions{
        .enabled = true,
        .output_dir = "test-coverage",
    };
    
    try std.testing.expect(options.enabled == true);
    try std.testing.expectEqualStrings("test-coverage", options.output_dir);
}
