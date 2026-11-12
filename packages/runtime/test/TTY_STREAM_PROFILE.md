# Repository-tool terminal output

`home-tool-tty-stream-smoke` creates actual POSIX pseudo-terminals. Python sets
their dimensions independently and inspects the bytes written to the master.
Both windows execute 29 stream/terminal groups and 119 saved Node v26.10.0 color
environment cases. The 41 physical output bytes include UTF-8, NUL, `0xff`, and
cursor/clear ANSI sequences. No terminal output or size query is mocked.

The tool-host `tty.WriteStream` uses the managed `Writable` implementation and
native file-descriptor writes. It requires a real terminal on macOS or Linux
and opens an independently owned `/dev/fd` copy. Destruction closes the copy and
retains the caller's descriptor; the Home profile verifies descriptor counts
before construction, during use and after close. `getWindowSize()` returns the
current columns/rows snapshot. `_refreshSize()` queries the kernel and emits a
resize event when that snapshot changes.

This bounded host accepts default options only (`undefined`/`null`). Options
objects, non-terminal constructors, read streams, raw input and automatic
SIGWINCH watching are not supported. These are not counted as implemented
Node features. Color queries use the licensed POSIX Node v26.10.0 rules retained
in `tool_tty.js`; the private native query/factory hooks are removed after setup.
HTTP remains a separate missing host capability.

Refresh the checked-in color matrix intentionally with the pinned reference:

    node packages/runtime/test/tool_tty_oracle.mjs

Run the independent physical fixture with either provider:

    python3 packages/runtime/test/tool_tty_stream_fixture.py \
      zig-out/bin/home-tool packages/runtime/test/tool_modules/node_tty_stream.mjs \
      --home-profile

For Node, pass its binary and `--node`. The Bun reference retains actual API
mismatches and must not be recast as a complete fixture pass. This fixture does
not establish a bundled CLI, N-API/Rust build, or upstream-test pass.
