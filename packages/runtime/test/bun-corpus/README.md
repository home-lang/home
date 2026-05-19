# Bun test corpus (Phase 12 acceptance gate substrate)

Verbatim mirror of `~/Code/bun/test/` at the pinned upstream SHA recorded in
`UPSTREAM_SHA.txt` (matches `packages/runtime/UPSTREAM_SHA.txt`). This is the
**substrate** for the runtime acceptance gate in `packages/runtime/README.md`:
once the Home runtime is feature-complete it must pass 100 % of these tests on
macOS, Linux, and the WASM target.

## Status

- **Not wired into `zig build test`.** Staged only; wiring lands alongside the
  Phase 12.8 test-runner copy.
- No source renames. `Bun.serve`, `Bun.write`, `Bun.spawn`, etc. appear
  verbatim. The `Bun.* -> Home.*` rename happens at **test-runtime** (via the
  host runtime's surface aliasing), not at copy time, so the corpus stays a
  clean diff against upstream and re-syncs cleanly.
- Tests marked `bun-only` (e.g. macOS Bonjour) are preserved verbatim and must
  pass — no skipping at the gate.

## What was filtered out of the copy

The sync script drops these patterns when they appear **outside** any
`fixtures/` or `_util/` directory (test inputs under those trees are kept
verbatim, even if they look binary): `node_modules/`, `.zig-cache/`,
`.bun-cache/`, `coverage/`, `dist/`, `*.log`, `.DS_Store`, `*.exe`, `*.dylib`,
`*.so`, `*.wasm`, `*.png`, `*.gif`, `*.mp4`, `*.zip`.

Nested `node_modules/` under `fixtures/` are kept on disk (test inputs) but
excluded from git by the repo's global rule — re-run the sync after a fresh
clone to restore them.

## Re-sync

```sh
./scripts/sync-bun-tests.sh
```

The script verifies `~/Code/bun` HEAD matches the pinned SHA and aborts if not.
Override the Bun checkout location with `BUN_REPO=/path/to/bun`.
