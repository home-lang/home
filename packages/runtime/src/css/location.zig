const std = @import("std");

/// A source location shared by the CSS parser, rule graph, and diagnostics.
/// Keeping this in a dependency-free leaf prevents the parser stub and the
/// live rule graph from manufacturing structurally identical but distinct
/// Zig types.
pub const Location = struct {
    /// The index of the source file within the source map.
    source_index: u32,
    /// The line number, starting at 0.
    line: u32,
    /// The column number within a line, starting at 1 and measured in UTF-16
    /// code units.
    column: u32,

    pub fn dummy() Location {
        return .{
            .source_index = std.math.maxInt(u32),
            .line = std.math.maxInt(u32),
            .column = std.math.maxInt(u32),
        };
    }
};

test "dummy CSS location uses invalid coordinates" {
    const location = Location.dummy();
    try std.testing.expectEqual(std.math.maxInt(u32), location.source_index);
    try std.testing.expectEqual(std.math.maxInt(u32), location.line);
    try std.testing.expectEqual(std.math.maxInt(u32), location.column);
}
