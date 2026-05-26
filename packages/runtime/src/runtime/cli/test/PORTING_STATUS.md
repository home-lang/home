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
`Frame` are compile-wired leaves today. The five process-pool modules are copied
as source backlog only; they stay unwired until Home's spawn/sys/uws/JSC
test-runner surfaces are ready.

Current blocker status is tracked by
`./pantry/.bin/zig build test -Dfilter=home_rt --summary failures`.
