// Copied from bun/src/cli/which_npm_client.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").

pub const NPMClient = struct {
    bin: string,
    tag: Tag,

    pub const Tag = enum {
        home,
    };
};

const string = []const u8;

const home_rt = @import("home");
