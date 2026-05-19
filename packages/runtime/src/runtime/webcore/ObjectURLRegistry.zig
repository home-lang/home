// Copied (partial) from bun/src/runtime/webcore/ObjectURLRegistry.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Scope:
//   * Only the pure URL-shape helpers — `specifier_len` and `isBlobURL` —
//     plus the matching size constant. These are what callers reach for
//     before even touching the registry, e.g. specifier resolution and
//     `loadAndResolveAsByteSourceProvider` short-circuits.
//
//   * The actual registry (Mutex, AutoHashMap, Entry, register, resolve*,
//     revoke, has, singleton) is JSC-heavy: it owns
//     `jsc.WebCore.Blob` entries, allocates with `bun.default_allocator`,
//     and is keyed on `bun.UUID`. None of those substrates are ported,
//     so the stateful surface stays parked.
//
// Rewritten:
//   * `bun.strings.hasPrefixComptime(url, "blob:")` is the upstream check;
//     Home's `strings.startsWith` does the same runtime-prefix test without
//     needing the comptime-known specialisation. (At call sites the literal
//     is still a `comptime []const u8`, so the lowering is equivalent.)
//
//   * `UUID.stringLength` (36 in upstream's `bun/src/jsc/uuid.zig`) is
//     inlined as `uuid_string_len`. Canonical UUID textual form is always
//     36 bytes ("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"), so this stays
//     stable even after the real UUID port lands.

const std = @import("std");
const home_rt = @import("home_rt");
const strings = home_rt.strings;

/// Canonical UUID string length: 8 + 4 + 4 + 4 + 12 + 4 separators = 36.
/// Mirrors upstream's `UUID.stringLength` until the UUID port lands.
pub const uuid_string_len: usize = 36;

pub const specifier_len: usize = "blob:".len + uuid_string_len;

pub fn isBlobURL(url: []const u8) bool {
    return url.len >= specifier_len and strings.startsWith(url, "blob:");
}

test "ObjectURLRegistry.specifier_len: 5 + 36 = 41" {
    try std.testing.expectEqual(@as(usize, 41), specifier_len);
}

test "ObjectURLRegistry.isBlobURL: well-formed blob URL" {
    // 41-byte URL: "blob:" + 36 hex/separator chars
    const sample = "blob:12345678-1234-1234-1234-123456789012";
    try std.testing.expectEqual(@as(usize, 41), sample.len);
    try std.testing.expect(isBlobURL(sample));
}

test "ObjectURLRegistry.isBlobURL: rejects short prefix" {
    try std.testing.expect(!isBlobURL("blob:short"));
    try std.testing.expect(!isBlobURL("blob:"));
}

test "ObjectURLRegistry.isBlobURL: rejects non-blob scheme of the right length" {
    // 41 bytes but not "blob:"-prefixed.
    const not_blob = "http://example.com/some/long/path/here.htm";
    try std.testing.expect(not_blob.len >= specifier_len);
    try std.testing.expect(!isBlobURL(not_blob));
}

test "ObjectURLRegistry.isBlobURL: empty input is not a blob URL" {
    try std.testing.expect(!isBlobURL(""));
}
