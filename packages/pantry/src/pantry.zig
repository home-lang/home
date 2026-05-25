// Home Programming Language - Pantry Package
// Package management and dependency resolution

const std = @import("std");

pub const platform_match = @import("platform_match.zig");
pub const currentArchitecture = platform_match.currentArchitecture;
pub const currentOperatingSystem = platform_match.currentOperatingSystem;
pub const isArchitectureMatch = platform_match.isArchitectureMatch;
pub const isCurrentArchitectureMatch = platform_match.isCurrentArchitectureMatch;
pub const isCurrentOperatingSystemMatch = platform_match.isCurrentOperatingSystemMatch;
pub const isOperatingSystemMatch = platform_match.isOperatingSystemMatch;

test "pantry stub" {
    try std.testing.expect(true);
}

test "pantry exports Bun-compatible platform matching" {
    try std.testing.expect(isArchitectureMatch(&.{currentArchitecture()}, currentArchitecture()));
    try std.testing.expect(!isArchitectureMatch(&.{ "any", "!x64" }, "x64"));
    try std.testing.expect(isOperatingSystemMatch(&.{ "wombo.com", "!aix" }, currentOperatingSystem()));
    try std.testing.expect(!isOperatingSystemMatch(&.{ "any", "!darwin" }, "darwin"));
}
