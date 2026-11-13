# Native Node synchronous subprocess profile

`home-tool-spawn-sync-smoke` exercises `node:child_process.spawnSync` and the
legacy module alias over the existing native owner-context child host. Real
POSIX processes supply their PID, status or signal and captured bytes. Normal
nonzero exits and signals return result objects without fabricating an error;
failed spawns return the actual mapped error with zero PID, null status/output
and undefined stdout/stderr. Error text is not an exact Node message contract.

The bounded macOS/Linux profile supports literal string argv, both call
signatures, string cwd, replacement/inherited environments, Buffer/UTF-8 output,
string/binary-view input, and real pipe/ignore/inherit modes for the three
standard descriptors. Bare commands use the supplied environment's PATH;
missing PATH uses `/usr/bin:/bin`. Relative commands and PATH components use the
child's cwd. Ignored streams use actual null devices. Inherited streams retain
the parent's real descriptors; captured results contain null entries for them.
Native IO tasks drain both output pipes while feeding input. They execute no
JavaScript, and cleanup joins tasks before releasing buffers and reaps the
owned direct child before returning. Each returned Buffer owns its bytes.

Input and requested output limits retain the existing 32 MiB bound. Exceeding
maxBuffer kills and reaps the actual child with SIGKILL and returns ENOBUFS with
real partial output, including up to one read chunk beyond the requested bound.
This differs from Node's default SIGTERM limit policy; it never reports clipped
output as success. Child timeouts, shell mode, custom kill signals, IPC, numeric
or transferred descriptors, identity changes, detached processes and other
options are explicitly refused before spawning. Windows remains unsupported.
The asynchronous `node:child_process.spawn` API is a separate capability.

Thirty actual child/error cases are checked against independent Python bytes,
PID files, cwd/environment/argv and descriptor observations. A 512 KiB input
probe requires simultaneous draining of both large output streams. ESM alias,
inherited binary stdin/stdout/stderr, and capture-limit kill/reap controls run as
additional processes. Eleven profile refusals verify that no child starts.
Node is checked separately against the same physical fixture; native transport
unit tests retain existing pipe/limit/scheduling/EPIPE checks and add real PATH,
null-device and reaping checks. This is a bounded subprocess profile, not a
complete Node or Bun test runner; unexecuted upstream tests earn no credit.
