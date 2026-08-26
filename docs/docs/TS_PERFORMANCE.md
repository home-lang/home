# TypeScript frontend performance

Home maintains a reproducible frontend benchmark for `home-tsc`, TypeScript's
JavaScript implementation (`tsc`), and the native TypeScript preview (`tsgo`).
The benchmark measures parse, bind, and type-check work only; all compilers
receive the same valid projects and run with emission disabled.
Ongoing coverage and optimization work is tracked in
[GitHub issue #416](https://github.com/home-lang/home/issues/416).

## Current snapshot

Measured 2026-08-26 at commit `4cc8f423a` on an Apple M3 Pro MacBook Pro
(11 cores, 18 GB RAM, arm64, macOS 27.0). Each value is the mean and sample
standard deviation of 30 new compiler processes after three warmup rounds.

| Workload | tsc 7.0.2 | tsgo 7.0.0-dev.20260707.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 59.4 ± 21.9 ms | 56.9 ± 11.1 ms | **4.7 ± 0.7 ms** | **12.08× faster** |
| `many_files` | 89.3 ± 25.8 ms | 88.0 ± 26.2 ms | **52.7 ± 17.1 ms** | **1.67× faster** |
| `deep_types` | 89.0 ± 24.5 ms | 78.2 ± 14.8 ms | **57.3 ± 8.1 ms** | **1.36× faster** |
| `import_graph` | 62.6 ± 8.5 ms | 63.5 ± 8.7 ms | **38.2 ± 5.4 ms** | **1.64× faster** |
| `reexport_graph` | 56.6 ± 8.4 ms | 58.8 ± 8.1 ms | **48.1 ± 8.4 ms** | **1.18× faster** |

The comparison column always uses the faster of `tsc` and `tsgo`, so Home must
beat both compilers to record a win. These are local synthetic measurements,
not a claim that every real project or machine has the same speedup.

## Fairness and measurement

- Compiler versions are pinned in `bench/vs_tsgo/corpus.toml`.
- The corpus is generated deterministically and is shared by all compilers.
- Every command receives `--noEmit -p <same tsconfig.json>`.
- Every project enables `strict`, `noLib`, `skipLibCheck`, and `pretty: false`.
  `noLib` isolates frontend work from differences in bundled standard-library
  size and availability.
- Before timing, every compiler must exit successfully without stdout or
  stderr. A compiler cannot win by rejecting or skipping the input.
- Measurements are process-cold and filesystem-cache-warm. Each timed sample
  launches a new compiler process after explicit warmups.
- A measured round contains all three compilers. Their order rotates each round
  so changing workstation load cannot consistently favor one implementation.
- Hyperfine supplies the process timer. Reported uncertainty is the sample
  standard deviation, not a confidence interval.

## Workloads

| Workload | Generated shape | Cost represented |
|---|---:|---|
| `startup` | One small source file plus a minimal declaration file | CLI and frontend startup |
| `many_files` | 256 independent source files plus a minimal declaration file | File discovery, loading, scheduling, parsing, and checking many modules |
| `deep_types` | One source file with 240 repeated generic models | Conditional, mapped, indexed, recursive, and template-literal type work |
| `import_graph` | 128 modules in a relative-import chain | Module resolution, export lookup, import closure, and cross-file generic checking |
| `reexport_graph` | 64 leaf modules projected through eight barrels | Recursive export-star projection, module resolution, and ambiguity checking |

The suite intentionally uses dependency-free synthetic projects so its inputs
stay stable and auditable. It does not replace benchmarks of pinned real-world
applications. A real project belongs in the suite only when all three compilers
can validate the same source graph and configuration.

## Reproduce

From the repository root:

```sh
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
./bench/vs_tsgo/run.sh setup
./bench/vs_tsgo/run.sh corpus
./bench/vs_tsgo/run.sh cold --runs 30 --warmup 3
./bench/vs_tsgo/run.sh report
```

The harness records compiler versions, host metadata, timing configuration,
and raw per-round Hyperfine JSON under
`bench/vs_tsgo/results/<UTC timestamp>/`. Results are ignored by Git because
they are machine-specific; the reviewed snapshot above is the durable record.

## Improvements behind this result

The current result comes from general compiler changes rather than
workload-specific shortcuts:

- release builds use the production thread-safe allocator while Debug retains
  leak detection;
- parser and checker feature probes cache source-level facts instead of
  repeatedly scanning whole files;
- visible type declarations are indexed per lexical scope while retaining the
  original resolver as an allocation-failure fallback;
- source loading reuses one I/O runtime per compilation;
- optimized builds compile sufficiently large programs with a bounded worker
  pool, while small programs remain serial to avoid thread startup overhead;
- cross-file export queries reuse bind-only module analyses and immutable
  per-export answers; and
- resolver mutation is synchronized separately from export-analysis caches so
  independent cache misses can parse and bind concurrently; and
- export-star ambiguity checks enumerate and cache real projected names instead
  of rescanning modules or guessing from the number of barrel declarations.
