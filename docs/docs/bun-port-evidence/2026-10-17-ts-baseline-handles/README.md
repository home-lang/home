# TypeScript conformance baseline handles

This is a partial input-fidelity repair for [#841](https://github.com/home-lang/home/issues/841). The previous loader validated baseline paths with `access` and later reopened them by pathname. A baseline root replaced between those operations could redirect expected diagnostics to a different file. The shared `readFileAlloc` also returned a short slice when a file shrank after `stat`, although the allocation had the original larger length.

The loader now opens the primary and fallback baseline directories once, keeps those handles until corpus loading ends, and opens each selected `.errors.txt` or `.errors.txt.diff` relative to the held handle. The selected error file remains open through exact-header extraction. Only `FileNotFound` means an absent per-case baseline; other open/read failures propagate. Fixture, diff and shared physical-file reads use the same exact-read helper, which rejects a short read and frees the full allocation. Existing primary no-content-diff precedence over the fallback baseline is unchanged.

The directory-identity control renames an opened baseline root, replaces its old pathname with a different directory containing the same filename, and confirms that the held root reads `original` while a newly opened root reads `replacement`. This control passed on the current macOS host with both Zig toolchains. It does not prove Windows rename semantics or every linked SDK.

All substantial runs were serial through `run_bounded` with `HOME_RUN_MAX_MB=3840`:

| Control | Zig 0.17 | Zig 0.18 | Peak tree footprint, MB (0.17 / 0.18) |
| --- | --- | --- | --- |
| Held-root identity after pathname replacement | 2/2 | 2/2 | 354 / 301 |
| Primary no-content diff versus fallback error baseline | 2/2 | 2/2 | 349 / 306 |
| Pinned real no-content diff helper | 2/2 | 2/2 | 282 / 313 |
| Exact configured baseline file | 2/2 | not run | 359 / — |
| Baseline availability and selected variant | 2/2 | not run | 377 / — |
| Invalid root remains an error | 2/2 | not run | 352 / — |
| Direct ES5 entry construction | 2/2 | not run | 317 / — |
| Pinned checkJs matrix baseline | 2/2 | not run | 367 / — |
| Pinned bundled library bytes and VFS identity | 2/2 | not run | 318 / — |

The opt-in exact corpus window `START=0 LIMIT=5` reached its unchanged **240-second wall bound (exit 124)** without a terminal aggregate. It receives no passing-case credit. `zig fmt --check` passed; scoped Pickier status is recorded in the manifest. The full TypeScript corpus, per-fixture I/O failure records, Windows/platform behavior, and entire Bun parity objective [#66](https://github.com/home-lang/home/issues/66) remain open.
