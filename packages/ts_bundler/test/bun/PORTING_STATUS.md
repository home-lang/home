# Bun Bundler Test Corpus — Phase 4.5 Validation

This directory is a verbatim copy of upstream Bun's bundler test
corpus (`bun/test/bundler/*`, MIT-licensed — see `LICENSE.bun.md`).
It is the test-side companion to the Zig source port that lives at
`packages/ts_bundler/src/bun/`.

The corpus stays as TypeScript / JavaScript on disk for now. Once
Home's bundler is functional enough to drive these fixtures, a Zig
side runner (see "Activation plan" below) will shell out to
`home bundle <fixture>` and diff the resulting output against the
golden snapshots in `__snapshots__/`.

> **Why a verbatim copy?** Same reasoning as the Zig port: we want a
> single, large, real-world test surface that already exercises every
> major bundler feature (CJS/ESM interop, code-splitting, tree
> shaking, JSX, decorators, plugins, sourcemaps, minification, CSS,
> HTML asset graphs, …). Holding the corpus in-tree means we can
> ratchet pass-rate visibly as the bundler matures, without depending
> on a sibling Bun checkout.

---

## Inventory

| Bucket | Count |
|---|---:|
| Total files copied | 145 |
| `.test.ts` (top level) | 49 |
| `.test.ts` (nested — `transpiler/`, `esbuild/`, `css/`, `resolver/`) | 38 |
| `.test.js` | 2 |
| Other `.ts` (helpers — `expectBundled.ts`, `buildNoThrow.ts`, fixtures) | 21 |
| `.tsx` (JSX fixtures) | 2 |
| `.js` (input fixtures) | 13 |
| `.json` (tsconfig / package.json fixtures) | 6 |
| Golden snapshots (`*.snap`) | 3 |
| Native plugin sources (`.cc`) | 2 |
| Helper shell scripts (`.sh`) | 2 |
| Misc (`.wasm`, `.png`, `.csv`, `.hbs`, `.jsx`, `.patch`, `.md`) | 7 |

Disk footprint: ~2.9 MB.

### Subdirectories preserved verbatim

```
__snapshots__/                  Top-level golden output snapshots
css/                            CSS bundling tests
  wpt/                            Web Platform Test cases
esbuild/                        esbuild-comparison tests
  __snapshots__/
fixtures/                       Input fixtures used by top-level tests
  jsx-warning/
  trivial/
  with-assets/                    .csv / .png / .js asset fixtures
resolver/                       Module resolver tests + node_modules layouts
scripts/                        Helper scripts (acorn fuzz harness)
transpiler/                     Transpiler-only tests + their own fixtures
  __snapshots__/
  fixtures/
    bun-pragma/
      fail/
      pass/
  jsx-dev/
```

## Attribution

Every `.test.ts` file (87 total) and `expectBundled.ts` carries a
3-line header at the very top of the file:

```ts
// Copied from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: test/bundler/<relative-path>
// See LICENSE.bun.md for full license text.
```

Other artifacts (input fixtures, snapshots, JSON configs, native
plugin C++ sources, shell scripts, binary assets) are intentionally
left byte-identical so Bun upstream stays diff-friendly. The
top-level `LICENSE.bun.md` covers the entire tree.

---

## Activation plan

The corpus is **not wired into `zig build test`** at this point —
running it requires a working `home bundle` CLI subcommand, which
does not exist yet (the Zig port at `packages/ts_bundler/src/bun/`
is still in the "blocked on `bun` stdlib aggregator" state per
`packages/ts_bundler/src/bun/PORTING_STATUS.md`).

The intended runner shape, once the bundler can produce output:

1. **`packages/ts_bundler/test/run_bun_corpus.zig`** — a Zig test
   that walks `packages/ts_bundler/test/bun/`, parses each
   `itBundled(...)` block out of the `.test.ts` files (or, more
   pragmatically, defers to a small TypeScript-side adapter that
   re-implements `expectBundled.ts` to spawn `home bundle` instead
   of `Bun.build`), runs the bundle, and diffs the output against
   the golden `__snapshots__/` artifacts.
2. **`expectBundled.ts` adapter** — Bun's framework calls
   `Bun.build({...})` and `bun build <args>` directly. The minimum
   adaptation is:
   - `Bun.build({...})` → spawn our `home-tsc bundle …` (or
     equivalent) and read the on-disk output back.
   - `bun build <args>` CLI invocations → translate flags to
     `home bundle` flags.
   - Snapshot comparisons stay byte-for-byte; mismatches surface as
     test failures.
3. **Pass-rate ratchet** — until the runner exists, this README
   tracks the deferred ratchet:

| Date | Tests passing | Tests skipped | Tests failing | Notes |
|---|---:|---:|---:|---|
| 2026-05-14 | 0 | 0 | 0 | Corpus copied; no runner yet — bundler still blocked. |

Bump the row above (or add a new row) every time the bundler
crosses a new pass-rate milestone.

---

## Known surface-area mismatches

The following will need adapter work before the corpus runs cleanly
against Home:

- **`Bun.build({...})` JS API** — used pervasively by `expectBundled.ts`
  and a handful of direct callers (`bun-build-api.test.ts`,
  `bun-build-compile*.test.ts`, `bundler_html_server.test.ts`).
  Home will expose its own JS bundle API (TBD); the framework
  adapter above translates between the two.
- **`bun build` CLI invocations** — `cli.test.ts`, `standalone.test.ts`,
  `compile-*.test.ts`, `compile-windows-metadata.test.ts` all spawn
  the `bun` binary directly. These need `home-tsc bundle` /
  `home compile` translations.
- **`bun:test` runner** — every `.test.ts` imports from `"bun:test"`.
  When run via `bun test` against this directory, the runner is
  Bun's. When the Zig-side `run_bun_corpus.zig` driver takes over,
  it will either (a) keep invoking `bun test` and assert externally
  on bundle output, or (b) parse the test bodies directly. (a) is
  easier and is the recommended starting point.
- **Native plugin tests** (`native_plugin.cc`, `not_native_plugin.cc`,
  `native-plugin.test.ts`) — depend on Bun's NAPI plugin ABI. These
  are deferred until Home decides on its own native plugin surface.
- **`bun:wrap` / `JSC`-specific paths** — a few `bundler_bun.test.ts`
  cases assume Bun's runtime `import.meta` shape and `bun:wrap`
  helpers. These will need either Home equivalents or `it.skip`
  marking by the adapter.
- **Compile-to-binary tests** (`bundler_compile*.test.ts`,
  `compile-argv.test.ts`, `compile-process-execargv.test.ts`,
  `compile-sourcemap-internal.test.ts`,
  `compile-windows-metadata.test.ts`, `standalone.test.ts`) — depend
  on Bun's standalone-binary feature (`bun build --compile`).
  Defer until Home implements the equivalent.
- **HTML/CSS/asset graph tests** — `bundler_html.test.ts`,
  `bundler_html_server.test.ts`, `html-import-manifest.test.ts`, all
  of `css/`. These need Home's HTML and CSS pipelines to come
  online; unlikely to pass before §4.5.B.
- **`__snapshots__/` regeneration** — Bun's snapshots include
  Bun-specific banner comments and import-meta paths. We may need
  per-snapshot transforms (or a regen pass on first green run) to
  account for Home-specific output differences (e.g. our chunk
  hashes, our runtime helper names).

Anything else should run unmodified once `Bun.build` is plumbed.

---

## Re-syncing from upstream

To pick up new tests from Bun:

```sh
rsync -av --delete \
  ~/Code/bun/test/bundler/ \
  packages/ts_bundler/test/bun/ \
  --exclude LICENSE.bun.md \
  --exclude PORTING_STATUS.md
# Then re-run the attribution-header pass over .test.ts and
# expectBundled.ts files (see commit dca93374 for the loop).
```

Keep this file (`PORTING_STATUS.md`) and `LICENSE.bun.md` excluded
from the rsync so resync passes don't clobber local notes.
