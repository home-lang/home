# Native kernel release query

`home-tool-kernel-release-smoke` checks the repository-tool `os.release()`
against independent Python `os.uname().release` reads. The implementation calls
libc `uname` with Zig's target-specific `std.c.utsname` on macOS and Linux;
it does not use environment variables or compile-time version strings.
Each call owns its native buffer, and a failed query throws rather than
returning a placeholder. Other platforms remain unsupported.

The 16-group fixture also checks CJS/ESM module identity, unbound calls,
ignored arguments, the function's name/arity/descriptors, primitive conversion,
and independence from replaceable JS platform/conversion metadata. Primitive
coercion calls the same captured native query. The observed kernel release is
host-specific; no checked-in release number is used as a passing oracle.

This is an OS query, not a test runner. Progressing an upstream runner beyond
its machine-information step gives no credit for unexecuted tests. Other
unimplemented OS or worker APIs remain separate capabilities.
