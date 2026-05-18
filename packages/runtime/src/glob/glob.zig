// Copied (partial) from bun/src/glob/glob.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: the upstream aggregator also re-exports `./matcher.zig`
// and `./GlobWalker.zig` which depend on `bun.sys`, `bun.path`, the JSC
// surface, and several syscall accessors that aren't ported yet — those
// re-exports are parked and only `detectGlobSyntax` lands now.

//! Pure-Zig glob helpers. Today this is just `detectGlobSyntax`, a heuristic
//! that decides whether a pattern needs the full glob walker or can be
//! treated as a literal path. The walker + matcher land alongside `bun.sys`.

const std = @import("std");

/// Returns true if the given string contains glob syntax,
/// excluding those escaped with backslashes
/// TODO: this doesn't play nicely with Windows directory separator and
/// backslashing, should we just require the user to supply posix filepaths?
pub fn detectGlobSyntax(potential_pattern: []const u8) bool {
    // Negation only allowed in the beginning of the pattern
    if (potential_pattern.len > 0 and potential_pattern[0] == '!') return true;

    // In descending order of how popular the token is
    const SPECIAL_SYNTAX: [4]u8 = comptime [_]u8{ '*', '{', '[', '?' };

    inline for (SPECIAL_SYNTAX) |token| {
        var slice = potential_pattern[0..];
        while (slice.len > 0) {
            if (std.mem.indexOfScalar(u8, slice, token)) |idx| {
                // Check for even number of backslashes preceding the
                // token to know that it's not escaped
                var i = idx;
                var backslash_count: u16 = 0;

                while (i > 0 and potential_pattern[i - 1] == '\\') : (i -= 1) {
                    backslash_count += 1;
                }

                if (backslash_count % 2 == 0) return true;
                slice = slice[idx + 1 ..];
            } else break;
        }
    }

    return false;
}

test "detectGlobSyntax returns true for negation + the four special tokens" {
    try std.testing.expect(detectGlobSyntax("!foo"));
    try std.testing.expect(detectGlobSyntax("src/*.zig"));
    try std.testing.expect(detectGlobSyntax("foo/{a,b}"));
    try std.testing.expect(detectGlobSyntax("foo/[abc].zig"));
    try std.testing.expect(detectGlobSyntax("foo?.zig"));
}

test "detectGlobSyntax returns false for plain paths and escaped tokens" {
    try std.testing.expect(!detectGlobSyntax(""));
    try std.testing.expect(!detectGlobSyntax("src/main.zig"));
    try std.testing.expect(!detectGlobSyntax("path/to/file.txt"));
    // Single backslash before * escapes it -> literal *
    try std.testing.expect(!detectGlobSyntax("foo\\*bar"));
    // Two backslashes before * are themselves an escaped backslash, so the *
    // is a real glob token.
    try std.testing.expect(detectGlobSyntax("foo\\\\*bar"));
}

test "detectGlobSyntax does not treat mid-string '!' as negation" {
    try std.testing.expect(!detectGlobSyntax("foo!bar"));
}
