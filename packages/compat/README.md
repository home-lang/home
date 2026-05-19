# `compat` — Bun compatibility shim

Tier-0 shim that re-exports the minimal `bun.*` surface vendored
Bun source needs in order to compile against Home's stdlib without
modification.

- **Parity status:** [`docs/PARITY-BUN-COMPAT.md`](../../docs/PARITY-BUN-COMPAT.md) (per-symbol drill-down)
- **Tier-0 surface:** 7 / ~103 `bun.*` identifiers (~6.8%)
- **Consumers:** [`packages/bundler/`](../bundler/) (Bun bundler vendor), [`packages/runtime/`](../runtime/) (Bun runtime port)

## Why this exists

The [Bun bundler](https://github.com/oven-sh/bun) and Bun runtime
are vendored verbatim into Home under MIT. Their source pervasively
writes `@import("bun")` and reaches for `bun.X` helpers — `bun.OOM`,
`bun.assert`, `bun.default_allocator`, etc. To compile that code
without rewriting every file (and to keep the vendored copy
diff-clean so it can be re-synced from upstream), Home ships a
`bun` shim package — this one — that re-exports a Bun-shaped surface
against Home's stdlib.

The build wires `@import("bun")` to this package at
[`build.zig:349-350`](../../build.zig):

```zig
const bundler_compat_pkg = createPackage(b, "packages/bundler/src/compat_tests.zig", ...);
bundler_compat_pkg.addImport("bun", compat_pkg);
```

Each tier of vendored code that comes online tells the shim what
new `bun.*` identifiers it needs. The shim grows just enough to
satisfy them — no more.

## Tier-0 surface (landed)

The seven symbols required by `IndexStringMap.zig` and
`PathToSourceIndexMap.zig`, the first two bundler vendors brought
online:

| Symbol | Purpose |
|---|---|
| `bun.OOM` | `error{OutOfMemory}` alias for explicit error-return signatures (`bun.OOM!void`) |
| `bun.handleOom` | Convert `error.OutOfMemory` into a panic for call sites that can't propagate |
| `bun.default_allocator` | Process-wide allocator (re-exports `std.heap.smp_allocator`) |
| `bun.assert` | Alias for `std.debug.assert` |
| `bun.ast.Index` | Source-file / module index newtype with `.Int = u32` companion |
| `bun.StringHashMapUnmanaged` | Alias for the std-lib generic |
| `bun.fs.Path` | Path record (Tier-0 callers read only `.text`) |

Full source: [`src/compat.zig`](./src/compat.zig).

## Adding a Tier-1 symbol

When a new vendored Bun file lands and the build fails because some
`bun.X` identifier is missing, here's the workflow:

1. **Identify the failing symbol** from the Zig compile error. The
   error message will name the missing identifier, e.g.
   `error: root struct of file 'bun' has no member named 'Output'`.

2. **Add a minimal shim** in [`src/compat.zig`](./src/compat.zig).
   Re-export against Home's stdlib where possible. Stub out
   subsystem-coupled fields with `// TODO(phase-12-N): wire to <real implementation>`
   comments so future tiers know what to fill in.

3. **Mirror upstream Bun's shape exactly.** Field names, struct
   layout, function signatures — match. The whole point is that
   vendored callers stay diff-clean.

4. **Add an inline test** in `src/compat.zig` (the file already has
   three): a shape check that the new symbol exists with the right
   type, plus a smoke call exercising it.

5. **Add an integration test** in
   [`../bundler/src/compat_tests.zig`](../bundler/src/compat_tests.zig)
   (or the runtime equivalent) that exercises the new symbol through
   a real vendored Bun file.

6. **Update the parity doc** at
   [`docs/PARITY-BUN-COMPAT.md`](../../docs/PARITY-BUN-COMPAT.md) —
   move the new symbol from the "Tier 1+" 🔴 list to the implemented
   table, bumping the percentage.

7. **Refresh the README headline** by running
   `scripts/measure-parity.sh` (writes the updated count to stdout)
   and pasting the result into the top-of-README headline table.

## Known Tier-1+ candidates

Upstream `bun.*` identifiers we'll likely need to shim as more
vendored files come online — currently all 🔴, listed at
[`docs/PARITY-BUN-COMPAT.md`](../../docs/PARITY-BUN-COMPAT.md):

`bun.Output`, `bun.JSC.*`, `bun.strings`, `bun.path`, `bun.options`,
`bun.resolver`, `bun.MutableString`, `bun.bake`, `bun.css`,
`bun.transpiler`, `bun.SourceMap`.

## Testing

Two test surfaces:

**Inline** (3 tests, pin Tier-0 shape):

```bash
zig build test -Dfilter=compat
```

**Integration** (7 tests, exercise the shim against real vendored
Bun files):

```bash
zig build test -Dfilter=bundler
```

Both run as part of `zig build test --summary all`.

## License

The shim itself is under the same license as the Home project. The
vendored Bun source it serves is MIT; see
[`packages/bundler/src/LICENSE.bun.md`](../bundler/src/LICENSE.bun.md)
and [`packages/runtime/`](../runtime/) for the upstream license
and pinned commit.
