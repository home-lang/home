# Bun Node Runtime Port

This directory is a faithful source copy of Bun's Zig Node runtime modules from
`/Users/chrisbreuer/Code/bun/src/runtime/node/` at Bun upstream
`fd0b6f1a271fca0b8124b69f230b100f4d636af6`.

The util/file/stream parity slice depends on these copied modules rather than
JavaScript harness stubs:

- `node_fs.zig`, `node_fs_binding.zig`, `node_fs_constant.zig`
- `node_os.zig`, `os/constants.zig`
- `path.zig`, `path_watcher.zig`
- `node_util_binding.zig`, `util/parse_args.zig`,
  `util/parse_args_utils.zig`, `util/validators.zig`
- `dir_iterator.zig`, `Stat.zig`, `StatFS.zig`, `fs_events.zig`,
  `node_fs_watcher.zig`, `node_fs_stat_watcher.zig`

`packages/runtime/src/runtime/webcore/PORTING_STATUS.md` tracks the companion
WebCore file/blob/body/stream copy (`Blob.zig`, `FileSink.zig`,
`ArrayBufferSink.zig`, `ReadableStream.zig`, `Body.zig`, and related leaves).

## Current State

- **Copied:** all `.zig` files under Bun `src/runtime/node/` are present under
  Home `packages/runtime/src/runtime/node/`.
- **Verified:** direct `diff -q` checks for the fs/os/path/util files above
  match the Bun checkout before local Zig 0.17 compatibility edits.
- **Adapted:** Pantry Zig 0.17 rejects one-sided whitespace around `**`, so
  `util/parse_args.zig` tightens the copied array-repeat expression.
- **Build wiring:** `home_rt.jsc` now exposes Bun's copied host-function aliases
  used by JSC-backed node/webcore modules, and `home_rt` exports Bun's copied
  `TaggedPointer` / `TaggedPointerUnion` helpers for copied stream/sink code.

## Blockers

`./pantry/.bin/zig build test -Dfilter=home_rt --summary failures` currently
progresses past the fs/os/path/util and webcore sink surface, then fails in
broader runtime leaves outside this slice: missing copied `bundler_jsc/*`,
missing copied `install_jsc/*`, missing CLI test support files, and remaining
Zig 0.17 syntax in install/CLI/test-runner files.
