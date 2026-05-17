# Phase 12 — `packages/runtime/src/cli/` porting status

Upstream SHA: `fd0b6f1a271fca0b8124b69f230b100f4d636af6` (see
`../../UPSTREAM_SHA.txt`).

Each row tracks one file copied from `~/Code/bun/src/cli/`. `bun=N`
counts `bun.X` references in the upstream file (rough porting effort
proxy). `Compile` is the local status after the import rewrite.

| File | LOC | bun | Compile | Top externs needed |
|---|---:|---:|---|---|
| `which_npm_client.zig` | 12 | 0 | **clean (Tier 0)** | `home_rt` (no members yet) |
| `colon_list_type.zig` | 62 | 6 | blocked | `home_rt.Global`, `home_rt.Output`, `home_rt.strings`, `home_rt.fmt`, `home_rt.options.Loader`, `home_rt.schema.api.Loader` |
| `discord_command.zig` | 10 | 1 | blocked | `./open.zig` (not yet copied) |
| `ci_info.zig` | 27 | 4 | blocked | `home_rt.once`, `home_rt.env_var.CI`, codegen-generated `ci_info` module |

## Adding a row

1. Verify the upstream SHA in `~/Code/bun` matches the one above
   (`git -C ~/Code/bun rev-parse HEAD`). If not, **stop** and either
   rewind Bun or bump the SHA in a separate commit before continuing.
2. Copy the source verbatim into this directory.
3. Replace `const bun = @import("bun");` with
   `const home_rt = @import("home_rt");` and update every `bun.X`
   reference to `home_rt.X`. **No semantic edits in the same commit.**
4. Add a header to the copied file recording the upstream path + SHA
   and pointing at `LICENSE.bun.md`.
5. Append a row to this table with the compile status. If blocked,
   list the top external symbols needed so the next agent can pick
   them up.
6. Wire the file into `build.zig` only after it compiles.

## Acceptance gate

`packages/runtime/` is feature-complete when every file under
`~/Code/bun/src/cli/` has either a `clean` row here or an
`intentionally-different` row in `../../README.md`, and `home test
packages/runtime/test/bun-corpus/` passes 100 %. See
`docs/TS_PARITY_PLAN.md` §12.
