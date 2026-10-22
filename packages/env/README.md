# Environment access

The public `get` now reads the process environment on Linux when linked with
libc, preserving missing versus empty values. The existing no-libc Linux fallback
still returns null. POSIX `get`, `set` and `unset` delegate to the standalone
`PosixEnv` export. Values are raw bytes without embedded NUL; keys are nonempty
without `=` or NUL. Owned reads survive later mutations and must be freed with
the supplied allocator. Long values are not constrained by filesystem path limits.

`src/posix_env.zig` supports pinned Zig 0.15.2 and current Zig with libc on Linux
and macOS. Windows/no-libc calls report UnsupportedEnvironment. The larger env
package also imports current runtime APIs; its public wrapper regression runs on
the current compiler rather than claiming the whole package supports 0.15.2.

`PosixEnv.Override.init(allocator, key, value)` copies the key, exact expected
value and previous value before changing anything. It distinguishes absent and
empty previous values. `matchesCurrent` observes byte equality. `close` needs no
new allocations through the supplied allocator (libc setters may still fail).
It restores only if the current value still matches, otherwise
preserves the different external value and returns `superseded`. Write failure
retains a live owner for retry. Successful close frees every copy and is idempotent.
Do not copy a live override or abandon it after a failed close.

Callers serialize process-environment access. This helper cannot make unrelated
writers cooperate or distinguish an external same-value write from its own
override. It is a lifetime/ownership primitive, not a process sandbox or a way
to give concurrent users different values for one environment key.

Three standalone tests cover raw/long/owned reads, restoration and external
changes, retryable failure, and exhaustive allocation-failure atomicity:

```sh
zig test -lc packages/env/src/posix_env.zig
zig test -lc -O ReleaseSafe packages/env/src/posix_env.zig
```

`tests/posix_exports.zig` is a separate executable exercising the public
get/set/unset wrappers, including Linux/libc and an 8192-byte value. The dedicated
workflow runs the helper on pinned/master and the public executable on master.
