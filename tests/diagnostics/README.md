# Diagnostic snapshot tests

This directory contains the corpus and harness for end-to-end diagnostic
regression tests. Each `*.home` file under `cases/` is a small program
intentionally designed to trigger a specific compiler error. The harness
runs `home check` against each case, normalizes the output (strips ANSI
colors, drops debug-allocator leak dumps, rewrites absolute paths to
`<repo>/...`), and compares the result to a checked-in `<file>.expected`
snapshot.

## Running

```sh
zig build test-diagnostics                 # verify (fails CI on diff)
zig build test-diagnostics -- --update     # accept new output
```

`zig build test` also depends on `test-diagnostics`, so the umbrella
test target covers diagnostic regressions too.

## Layout

```
tests/diagnostics/
├── harness.zig                    # the runner (not a library; built via build.zig)
├── README.md
└── cases/
    ├── types/      # type-checker errors (mismatch, arity, fields, …)
    ├── parse/      # parse errors (unclosed delimiters, keywords as idents, …)
    ├── imports/    # module-resolution errors
    └── recovery/   # programs that exercise multi-error reporting
```

## Adding a case

1. Drop a small `.home` file under the appropriate subdirectory. Aim for
   one diagnostic per case unless you're explicitly testing recovery /
   multi-error reporting.
2. Run `zig build test-diagnostics -- --update` to produce a snapshot.
3. **Read the resulting `.expected` file**. If it doesn't actually
   demonstrate a useful diagnostic for that category (e.g. "Type
   checking passed ✓"), the compiler doesn't yet diagnose what you
   intended — delete the case (or leave a `// TODO:` note in the source
   and document it as a known gap rather than checking in misleading
   "expected" output).
4. `git add` both the `.home` and the `.expected` file.

## Snapshot honesty

We only commit `.expected` files that match what the compiler **actually
produces today**. Fabricating ideal output that doesn't match current
behavior would defeat the regression-detection purpose of the harness.
If a diagnostic category isn't implemented yet (e.g. borrow checking,
exhaustive match analysis, generic monomorphization), leaving it out of
the corpus is the right move — the harness is meant to lock in current
UX so refactors can't silently degrade it.

## Categories not yet exercised

The following diagnostic categories are mentioned in `docs/ERROR_MESSAGES.md`
but the compiler currently doesn't emit useful errors for them, so they
are intentionally absent from the corpus:

- **Missing return** — the type checker doesn't currently flag
  functions that fall off the end without returning.
- **Match exhaustiveness** — non-exhaustive `match` arms type-check.
- **Borrow / move violations** — the borrow checker pass exists but
  doesn't currently surface diagnostics through `home check`.
- **Generic monomorphization failures** — generics resolve too eagerly
  to produce a useful surface error.
- **"Did you mean?" suggestions for typo'd identifiers** —
  `pritnln(...)` currently type-checks rather than triggering an
  undefined-function diagnostic with a Levenshtein hint.

When any of those land, add cases here. The `// TODO: not yet implemented`
naming convention is fine for tracking the gap without committing
fake output.

## Why a custom harness instead of shell + diff

- Cross-platform normalization (Linux/macOS/Windows produce slightly
  different paths and ANSI behavior).
- The debug build of `home` emits `error(DebugAllocator): ...` leak
  dumps at exit. These are unrelated to diagnostic UX, very noisy, and
  vary per run; the harness filters them out.
- A 30 s per-case wall-clock budget catches genuine compiler infinite
  loops (we've seen at least one — `fn 123 invalid()` — where the
  parser doesn't terminate).
- A shared `--update` mode reduces the friction of intentional snapshot
  refreshes.
