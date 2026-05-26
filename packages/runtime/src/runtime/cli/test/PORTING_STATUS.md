# Bun CLI Test Support Port

Upstream: `/Users/chrisbreuer/Code/bun/src/runtime/cli/test/` at
`fd0b6f1a271fca0b8124b69f230b100f4d636af6`.

Copied checked-in Zig support modules for the Home runtime test command:

- `ChangedFilesFilter.zig`
- `Scanner.zig`
- `ParallelRunner.zig`
- `parallel/FileRange.zig`
- `parallel/Frame.zig`
- `parallel/Channel.zig`
- `parallel/Coordinator.zig`
- `parallel/Worker.zig`
- `parallel/aggregate.zig`
- `parallel/runner.zig`

Adaptation: `@import("bun")` is rewritten to `@import("home_rt")` so the copied
files bind through Home's Bun-compatible runtime aggregator. `FileRange` and
`Frame` are compile-wired leaves today. The five process-pool modules are also
module-parse-wired behind `home_rt.enable_parallel_process_pool_smoke`; the
`ParallelRunner` runtime entrypoint re-exports remain parked so no spawn/IPC
behavior is exposed yet.
The smoke gate is currently enabled in `home_rt.zig` intentionally so the
copied modules stay visible to the aggregator's parse/type surface without
un-parking `runAsCoordinator`, `runAsWorker`, or worker IPC behavior.

Current blocker status is tracked by
`./pantry/.bin/zig build test -Dfilter=home_rt --summary failures`.
With `-Denable_jsc=false`, the current front is 24 compile errors. The
first blockers are `strings.convertUTF16ToUTF8Append`, `bun.O`,
`bun.sys.write`, `Output.printError*`, `jsc.PlatformEventLoop`, and
the parked WebCore/JSC request, stream, sink, S3, and SystemError
bridges.
