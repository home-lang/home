# Phase 12 — `packages/runtime/src/cli/` porting status

Upstream SHA: `fd0b6f1a271fca0b8124b69f230b100f4d636af6` (see
`../../UPSTREAM_SHA.txt`).

Each row tracks one file copied from `~/Code/bun/src/cli/` or, for the
runtime CLI leaves, `~/Code/bun/src/runtime/cli/`. `bun=N` counts `bun.X`
references in the upstream file (rough porting effort proxy). `Compile` is
the local status after the import rewrite.

| File | LOC | bun | Compile | Top externs needed / status |
|---|---:|---:|---|---|
| `which_npm_client.zig` | 12 | 0 | **clean (Tier 0)** | `home_rt` (no members yet) |
| `list-of-yarn-commands.zig` | 70 | 1 | **clean** | `home_rt.ComptimeStringMap` ✓ |
| `colon_list_type.zig` | 62 | 6 | **clean (parked loaders)** | `home_rt.options.Loader`, `home_rt.schema.api.Loader` paths parked until Loader vocabulary ports |
| `discord_command.zig` | 10 | 1 | **clean (parked opener)** | `open.openURL` parked until spawn + JSC.EventLoopHandle land; fallback URL print path tested |
| `ci_info.zig` | 27 | 4 | **clean (parked codegen)** | codegen-generated `ci_info` table and `home_rt.once` parked; env-var fallback shape tested |
| `shell_completions.zig` | 75 | 2 | **clean (parked embeds)** | completion embeds parked as empty literals until generated completion files port |
| `pm_why_command.zig` | 12 | 2 | blocked | `home_rt.cli.Command` + `home_rt.install.PackageManager` (huge substrate — Phase 12.9) |
| `add_command.zig` | 11 | 2 | blocked | same as pm_why_command (Command + PackageManager) |
| `remove_command.zig` | 11 | 2 | blocked | same |
| `update_command.zig` | 18 | 2 | blocked | same |
| `patch_command.zig` | 17 | 2 | blocked | same |
| `patch_commit_command.zig` | 11 | 2 | blocked | same |
| `exec_command.zig` | 46 | 9 | blocked | `home_rt.Transpiler`, `home_rt.jsc.MiniEventLoop`, `home_rt.shell.Interpreter`, `home_rt.path.join`, `home_rt.sys.getcwd` (Phase 12.3 + 12.6) |
| `add_completions.zig` | 105 | 2 | blocked (auto-gen) | `home_rt.zstd` (compressed completions blob — needs zstd substrate) |
| `Arguments.zig` | 1744 | 62 | blocked | `home_rt.options.*`, `home_rt.api.*`, `home_rt.allocators.*`, ... (the full bundler/runtime arg-parser dependency graph) |

47 cli files total (33 129 LOC upstream); 6 clean + 9 documented-blocked rows
above. The other ~32 follow the same pattern — most are thin shells over
`PackageManager` / `Command` / JSC.

## Adding a row

1. Verify the upstream SHA matches `../../UPSTREAM_SHA.txt`
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
6. Wire the file into `../home_rt.zig` only after it compiles, and add
   at least one test (either inline or via the `test {}` pull-in at the
   bottom of `home_rt.zig`).
7. Run `zig build test --summary all` and verify the total test count
   went UP (not just stayed equal — adding a copy without a test is not
   complete).

## Acceptance gate

Per user direction (2026-05-17): once feature-complete, Home must
pass **100 %** of Bun's test suite, no exceptions, no skips. See
`../../README.md` §"Acceptance gate" and `docs/TS_PARITY_PLAN.md`
§12 for the full contract.
