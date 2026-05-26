# Bun CLI/Spawn/Process/FS/File Source Slice

Upstream: `/Users/chrisbreuer/Code/bun`, SHA `fd0b6f1a271fca0b8124b69f230b100f4d636af6`.

This slice tracks faithful source migration only. It does not add JS harness
workarounds and does not promote corpus files by simulating Bun behavior.

Build-visible provenance lives in
`packages/runtime/src/bun/cli_spawn_process_fs_file.zig`.

## Copied Source

- CLI run: `src/runtime/cli/Arguments.zig`, `src/runtime/cli/run_command.zig`
- Spawn: `src/runtime/api/bun/js_bun_spawn_bindings.zig`,
  `src/runtime/api/bun/spawn.zig`, `src/runtime/api/bun/spawn/stdio.zig`,
  `src/runtime/api/bun/subprocess.zig`, and the subprocess pipe/resource
  leaves under `src/runtime/api/bun/subprocess/`
- Process: `src/runtime/api/bun/process.zig`,
  `src/runtime/node/node_process.zig`
- Node fs: `src/runtime/node/node_fs.zig`,
  `src/runtime/node/node_fs_binding.zig`,
  `src/runtime/node/node_fs_constant.zig`,
  `src/runtime/node/node_fs_watcher.zig`,
  `src/runtime/node/node_fs_stat_watcher.zig`,
  `src/runtime/node/fs_events.zig`
- Bun.file/Bun.write: `src/runtime/webcore/blob/read_file.zig`,
  `src/runtime/webcore/blob/write_file.zig`,
  `src/runtime/webcore/blob/copy_file.zig`, `src/sys/copy_file.zig`

All files above are byte-for-byte copies from Bun except
`runtime/api/bun/spawn.zig`, which is already adapted for Pantry Zig 0.17-dev
and Home package boundaries. That adaptation is limited to import/allocator/fd
aliases and Zig 0.17 POSIX spawn flag handling; high-level request execution
remains parked until the surrounding Bun process/JSC substrate is wired.

## Runnable Surface

The source manifest is compiled through `home_rt` and verifies provenance for
the slice. The real copied implementations become logically runnable when the
following dependencies attach:

- Bun spawn: `Process`, IPC, terminal ownership, `jsc.Codegen.JSSubprocess`,
  and the Bun C++ spawn shim.
- Node fs: `jsc.Node` path/value coercion, async work-pool tasks, libuv fs
  requests, and JS callback/promise plumbing.
- Bun.file/Bun.write: WebCore Blob/FileSink integration and the JSC
  `ArrayBuffer`/`ReadableStream` bridge.
- CLI run: Bun CLI environment, script resolution, package manager state, and
  subprocess execution.

Corpus files in `cli/run`, `js/bun/spawn`, `js/node/fs`, and
`js/bun/util/bun-file*.test.*` should be promoted only after they exercise this
copied source path directly.
