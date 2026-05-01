# Lexer + parser fuzzing

This directory holds the mutation-based fuzz harness for the Home compiler's
lexer and parser. It tracks [issue #10](https://github.com/home-lang/home/issues/10).

## Layout

```text
tests/fuzz/
  harness.zig        # the driver
  corpus/
    lex/             # seeds for the lexer fuzz target (`home parse`)
    parse/           # seeds for the parser fuzz target (`home ast`)
  README.md          # this file
```

Crash and timeout reproducers are written to
`.home-cache/fuzz-findings/{lex,parse}/` (override with `--findings`).

## Running locally

```sh
# Default: both targets, 30 seconds budget each.
zig build fuzz

# Single target.
zig build fuzz-lexer
zig build fuzz-parser

# Tune the budget. Pass-through args go after `--`.
zig build fuzz -- --seconds 120

# Reproduce a specific run.
zig build fuzz-parser -- --seed 42 --seconds 10

# Hard cap on iterations (useful for smoke tests).
zig build fuzz -- --max-iters 50

# Custom findings directory.
zig build fuzz -- --findings /tmp/home-fuzz-out
```

Pass `--help` to the harness to see every flag:

```sh
./zig-out/bin/home --help        # not the fuzzer
zig build fuzz -- --help         # the fuzzer
```

## How it works

The harness loads files from `corpus/<target>/`, mutates them with
byte-level edits (bit flips, byte inserts, keyword splices, etc.),
writes each mutation to a scratch file, and shells out to the compiled
`home` binary as a subprocess:

- `home parse <file>` for the **lexer** target — tokenises only.
- `home ast <file>`   for the **parser** target — tokenises + parses.

Each subprocess gets a hard wall-clock timeout (default 2s per input).
Outcomes are classified as:

| outcome           | exit/signal                          | CI status |
| ----------------- | ------------------------------------ | --------- |
| `ok`              | exit 0                               | pass      |
| `compiler_error`  | exit 1 (parse error, type error, …)  | pass      |
| `timeout`         | killed by harness after `--timeout`s | pass\*    |
| `crash`           | signal, or unexpected exit code      | **fail**  |

\* timeouts are saved to `findings/<target>/timeout-NNNN.home` and
counted, but they do not fail the build. See "Why timeouts don't fail"
below.

Crashes are saved to `findings/<target>/crash-NNNN.home`.

## Why subprocess isolation, and why timeouts don't fail CI

The parser is known to infinite-loop on certain malformed inputs —
tracked as **issue #16**. The minimal repro that motivates this harness
is `fn 123 invalid() {}`, which hangs `home ast` indefinitely. The
home-os audit (2026-05-01) found 110/166 parse-failing kernel modules
also hang the parser past 15s.

If we ran the fuzzer in-process, the very first hang would wedge the
harness itself. Instead we spawn a fresh `home` subprocess per
iteration so `std.process.run`'s `timeout` option can kill it cleanly.

Treating timeouts as recoverable findings (rather than fatal crashes)
keeps the fuzzer green against the *current* compiler — otherwise CI
would go red on every run. As issue #16 closes, we expect the timeout
count to fall to zero. Until then, every saved timeout reproducer is
useful: it's a candidate test case to attach to #16.

If a timeout is found that does **not** look like the same hang as
issue #16 — different shape, different region of the parser — please
attach it to #16 with a brief description.

## Adding to the corpus

Drop a new file under `corpus/lex/` or `corpus/parse/`. Anything goes
— you don't even need a `.home` extension. Files larger than 1 MiB are
ignored (mutations stay small anyway).

Good seeds are:

- short, focused programs that exercise one feature
- known-tricky diagnostics inputs (we already mirror a few from
  `tests/diagnostics/cases/`)
- minimised reproducers from real bugs

When a fuzz finding turns out to be a real bug worth fixing forever,
copy the reproducer into `tests/diagnostics/cases/` (with a paired
`.expected`) so the snapshot suite catches future regressions.

## Mutation strategy

Per iteration:

1. Pick a corpus seed at random (1-in-16 we generate pure random bytes
   instead — covers the "lexer chokes on raw garbage" surface).
2. Apply 1–3 of these AFL-style edits:
   - bit flip
   - replace byte with random
   - insert random byte
   - delete byte
   - splice "interesting" punctuation (`{`, `::`, `=>`, `${`, …)
   - splice a Home keyword (`fn`, `match`, `comptime`, …)
   - truncate
   - splice an "interesting" int literal (`0xFFFFFFFF`,
     `9223372036854775808`, `1.7976931348623157e308`, …)

This is intentionally simple. Coverage-guided fuzzing (libFuzzer
style) would be strictly better but isn't wired up in this Zig version
yet. The mutation set is calibrated for the kinds of inputs that have
historically broken the lexer/parser: malformed string escapes,
mismatched delimiters, oversized literals, keyword-as-identifier.

## CI

- **Pull request runs (`.github/workflows/ci.yml`):** short fuzz
  session — 60s per target, fails the PR only on actual crashes.
- **Nightly (`.github/workflows/fuzz-nightly.yml`):** longer session
  (15min per target) on a schedule. Findings are uploaded as build
  artifacts so we can inspect timeout/crash reproducers later.

## Interpreting findings

Open `.home-cache/fuzz-findings/parse/timeout-0001.home` (or wherever
you pointed `--findings`). It's the literal byte sequence the fuzzer
fed to `home`. Reproduce with:

```sh
./zig-out/bin/home ast .home-cache/fuzz-findings/parse/timeout-0001.home
```

If it's a crash, the output of that command should panic, segfault,
or otherwise misbehave. File a bug with the reproducer attached. If
it's a timeout, double-check that it actually hangs (`Ctrl-C` after a
few seconds) and either attach to issue #16 or open a new issue if it
looks distinct.
