// Home Runtime — ported from Bun.
// Upstream:  packages/runtime/upstream/src/ast/use_directive.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Renames applied (per packages/runtime/README.md naming convention):
//   - `@import("bun")` -> `@import("home")`
//   - removed the unused `Flags` re-export pulled from `bun.ast`.
//   - Zig 0.17 compat: `std.mem.trimLeft` -> `std.mem.trimStart`.
//
// `"use client"` / `"use server"` directive parser used by the server-
// components boundary detection pass. Pure-data — only depends on
// `home_rt.strings.eqlComptime`.

pub const UseDirective = enum(u2) {
    // TODO: Remove this, and provide `UseDirective.Optional` instead
    none,
    /// "use client"
    client,
    /// "use server"
    server,

    pub const Boundering = enum(u2) {
        client = @intFromEnum(UseDirective.client),
        server = @intFromEnum(UseDirective.server),
    };

    pub const Flags = struct {
        has_any_client: bool = false,
    };

    pub fn isBoundary(this: UseDirective, other: UseDirective) bool {
        if (this == other or other == .none)
            return false;

        return true;
    }

    pub fn boundering(this: UseDirective, other: UseDirective) ?Boundering {
        if (this == other or other == .none)
            return null;
        return @enumFromInt(@intFromEnum(other));
    }

    pub fn parse(contents: []const u8) ?UseDirective {
        const truncated = std.mem.trimStart(u8, contents, " \t\n\r;");

        if (truncated.len < "'use client';".len)
            return .none;

        const directive_string = truncated[0.."'use client';".len].*;

        const first_quote = directive_string[0];
        const last_quote = directive_string[directive_string.len - 2];
        if (first_quote != last_quote or (first_quote != '"' and first_quote != '\'' and first_quote != '`'))
            return .none;

        const unquoted = directive_string[1 .. directive_string.len - 2];

        if (strings.eqlComptime(unquoted, "use client")) {
            return .client;
        }

        if (strings.eqlComptime(unquoted, "use server")) {
            return .server;
        }

        return null;
    }
};

const std = @import("std");

const home_rt = @import("home");
const strings = home_rt.strings;

test "UseDirective.parse recognises 'use client' / 'use server'" {
    try std.testing.expectEqual(UseDirective.client, UseDirective.parse("'use client';").?);
    try std.testing.expectEqual(UseDirective.server, UseDirective.parse("\"use server\";").?);
    try std.testing.expectEqual(UseDirective.client, UseDirective.parse("  \n\t'use client';\nrest").?);
}

test "UseDirective.parse rejects non-directives" {
    // Mismatched quotes -> not a directive (returns .none).
    try std.testing.expectEqual(UseDirective.none, UseDirective.parse("'use client\";").?);
    // Body length doesn't match either "use client"/"use server" -> the
    // quote-pair check fails (last char of the 13-byte window is "n", not
    // a quote), so we still hit the .none early-return rather than null.
    try std.testing.expectEqual(UseDirective.none, UseDirective.parse("'use unknown';").?);
    // Too short -> .none.
    try std.testing.expectEqual(UseDirective.none, UseDirective.parse("short").?);
    // 13-byte well-quoted directive whose body is neither client nor
    // server -> the explicit `return null` branch.
    try std.testing.expect(UseDirective.parse("'use foobar';") == null);
}

test "UseDirective.isBoundary / boundering" {
    try std.testing.expect(UseDirective.client.isBoundary(.server));
    try std.testing.expect(!UseDirective.client.isBoundary(.client));
    try std.testing.expect(!UseDirective.client.isBoundary(.none));

    try std.testing.expectEqual(
        UseDirective.Boundering.server,
        UseDirective.client.boundering(.server).?,
    );
    try std.testing.expect(UseDirective.client.boundering(.client) == null);
}
