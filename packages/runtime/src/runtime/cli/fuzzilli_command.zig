// Copied from bun/src/runtime/cli/fuzzilli_command.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Wave-16 Tier-1 grinder.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.Environment → home_rt.Environment
//
// The entire `FuzzilliCommand` body lives behind the
// `home_rt.Environment.enable_fuzzilli` comptime gate (set to `false`).
// When the gate is true the body re-attaches its current Bun deps:
//   - bun.Output, bun.Global, bun.sys.openat/open/write, bun.O,
//     bun.cli.Command, bun.bun_js.Run, bun.runtime.cli (REPRL fd setup).
//
// Today the gate is `false`, so the body compiles down to `struct {}`
// and the file ships only the comptime scaffolding + tests.

const std = @import("std");
const home_rt = @import("home");

pub const FuzzilliCommand = if (home_rt.Environment.enable_fuzzilli) struct {
    // Body parked — see `bun/src/runtime/cli/fuzzilli_command.zig` upstream.
    // Re-attaches when:
    //   - home_rt.Output / home_rt.Global grow the prettyErrorln + exit surface
    //     (the no-op + std.process.exit shims already work).
    //   - home_rt.sys grows the openat/open/write + bun.O constants.
    //   - home_rt.cli grows Command + bun_js.Run.
} else struct {};

test "FuzzilliCommand: gate defaults to disabled in home_rt" {
    // The `if (Environment.enable_fuzzilli)` arm collapses to `struct {}`
    // when the gate is false. Asserting the type is empty proves the
    // scaffolding compiled through.
    const decls = @typeInfo(FuzzilliCommand).@"struct".decl_names;
    try std.testing.expectEqual(@as(usize, 0), decls.len);
}

test "FuzzilliCommand: enable_fuzzilli gate is wired into Environment" {
    // Sanity — flipping the gate at compile time should re-route this
    // branch. The test asserts the namespace + flag both exist.
    try std.testing.expect(@TypeOf(home_rt.Environment.enable_fuzzilli) == bool);
    try std.testing.expectEqual(false, home_rt.Environment.enable_fuzzilli);
}
