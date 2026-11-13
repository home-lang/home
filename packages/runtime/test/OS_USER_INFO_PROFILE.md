# Native effective-account query

`home-tool-user-info-smoke` verifies repository-tool `os.userInfo()` against
independent Python `pwd.getpwuid(os.geteuid())` snapshots before and after the
actual CJS and ESM executions. The macOS/Linux implementation calls reentrant
`getpwuid_r(geteuid())`, grows its private buffer on ERANGE up to 1 MiB, and
copies the returned account's uid, gid, username, home directory and shell.
It never derives account data from HOME, USER, LOGNAME or SHELL.
Other platforms and failed/missing native records throw rather than returning
an invented account. Exact Node failure text and SystemError metadata are not
part of this bounded profile.

The native callback serializes string bytes as hex before freeing libc storage.
The JS wrapper returns fresh null-prototype objects and real owned Buffers for
`encoding: 'buffer'`, including its uppercase spelling. String encodings include
UTF-8, hex, base64/base64url, ASCII, Latin-1/binary and little-endian UTF-16/UCS-2
aliases. Invalid/non-string encodings retain Node's UTF-8 default. These account
conversions do not expand the separate Buffer module's supported encodings.

The 44 behavior groups cover physical IDs and encoded account bytes, field/key
shape, aliases, descriptors, name/arity, unbound and constructor calls, options,
encoding getters and their exception identity, fresh results, repeated native
queries, and environment independence. The ESM control checks both aliases
and actual raw account bytes. The fixture does not print account contents.
This verifies the host's actual account, not a synthetic password database;
it does not exercise privilege changes or injected libc failures.

This OS query does not implement a test scheduler. Advancing an upstream runner
beyond account lookup gives no passing credit to unexecuted tests, builds or
other missing host APIs.
