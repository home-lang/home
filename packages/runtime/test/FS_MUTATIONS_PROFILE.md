# Callback filesystem mutation profile

`home-tool-fs-mutations-smoke` exercises actual kernel I/O through the Home
repository tool. It adds callback `writeFile`, `mkdir`, `unlink` and `copyFile`,
plus real sync/promise unlink and copy aliases. Callbacks are deferred onto the
protected owner task queue; the operations themselves run on that thread. This
is not a libuv worker pool and does not promise nonblocking throughput.

Argument validation happens before scheduling. Callback exceptions escape the
I/O error handler and enter native uncaught-exception dispatch. Borrowed write
descriptors retain their open flags and offset and are never closed by Home.
Copies stream bytes through actual opened descriptors, preserve an existing
destination inode and its hard links, follow destination symlinks, and compare
source/destination device and inode before truncating. `COPYFILE_EXCL` uses an
exclusive kernel open. Reflink flags and nonregular-file copy remain explicit
unsupported errors; no successful clone or special-device operation is claimed.
String writes support UTF-8, with actual ArrayBuffer-view bytes for binary data.
Other encodings, iterable writes and unsupported options retain their refusals.

The Python fixture prepares a 1,048,593-byte physical source, hard links and
symlinks. It verifies all destination bytes, permissions and original inode
identity independently of JavaScript assertions. The script has 43 groups; 16
separate children verify callback error identity, fatal throws and task liveness
for successful and failed mutations. Node is the reference; Bun differences
remain failures. The `--home-profile` assertions check explicit clone refusals.

This repair lets the unmodified `@napi-rs/cli` 2.18.4 help entry get past its six
filesystem `promisify` calls. It then fails at missing `process.binding`.
Neither a complete CLI run, native addon support nor application compatibility
is claimed by these filesystem tests.
