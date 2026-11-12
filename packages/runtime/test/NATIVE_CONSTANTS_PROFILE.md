# Native constants profile

`home-tool-native-constants-smoke` verifies a bounded constants surface:

- `os.constants.errno` and legacy `constants` errno names come from the target
  libc's `errno.h`, translated by the existing Zig build toolchain. Absent
  macros stay absent. macOS POSIX `EOPNOTSUPP` is not taken from Zig's BSD errno
  enum alias: the actual target headers decide its value.
- `process.binding('constants')` returns a stable object whose `fs` and `os`
  aliases are the actual public constants objects. Filesystem flags remain
  backed by the native host implementation. This does not load Node internals.
- Only this private constants lookup is implemented. Other private bindings,
  crypto/zlib/trace/internal namespaces, OS signal/priority/dlopen tables and
  buffer limits remain unavailable. Unknown bindings throw a truthful
  `ERR_HOME_UNSUPPORTED`; no empty success objects or fabricated values exist.
- Real descriptor errors carry the native negative errno, matching the existing
  path-error facade. The fixture closes an actual descriptor twice, removes a
  missing path, and attempts exclusive creation over existing bytes.

The 18-group script checks aliases, descriptors and actual filesystem errors.
Python independently compares every published errno and flag against its native
constants and opens a physical file with the returned exclusive-create flags.
The original bytes survive a rejected second open. Native Node is the reference;
Bun descriptor differences remain failed evidence. The Home-only profile tests
explicit private-binding refusals and removal of the native installation hook.

The unmodified `@napi-rs/cli` 2.18.4 help entry gets past its temporary-file
library's private constant lookup after this repair. It reaches the separate
missing `console.assert` API in its argument parser. A complete help/build/test,
native addon, or application pass is not claimed.
