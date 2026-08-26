# TypeScript frontend performance

Home maintains a reproducible frontend benchmark for `home-tsc`, TypeScript's
JavaScript implementation (`tsc` 6.x), and stable native TypeScript 7
(`tsgo` in the tables below).
The benchmark measures parse, bind, and type-check work only; all compilers
receive the same valid projects and run with emission disabled.
Ongoing coverage and optimization work is tracked in
[GitHub issue #416](https://github.com/home-lang/home/issues/416).

## Current snapshot

Measured 2026-08-26 at commit `b509aa125` on an Apple M3 Pro MacBook Pro
(11 cores, 18 GB RAM, arm64, macOS 27.0). Each value is the mean and sample
standard deviation of 30 new compiler processes after three warmup rounds.

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 75.2 ± 5.5 ms | 45.9 ± 8.4 ms | **4.0 ± 0.3 ms** | **11.42× faster** |
| `many_files` | 252.6 ± 20.1 ms | 64.3 ± 10.1 ms | **38.4 ± 6.7 ms** | **1.67× faster** |
| `deep_types` | 160.1 ± 11.8 ms | 61.8 ± 4.3 ms | **49.6 ± 2.1 ms** | **1.25× faster** |
| `import_graph` | 163.7 ± 23.6 ms | 55.7 ± 4.5 ms | **33.5 ± 7.1 ms** | **1.67× faster** |
| `reexport_graph` | 123.5 ± 2.6 ms | 53.4 ± 7.3 ms | **40.4 ± 1.7 ms** | **1.32× faster** |
| `tsx_components` | 211.8 ± 4.3 ms | 59.0 ± 1.3 ms | **53.6 ± 1.1 ms** | **1.10× faster** |
| `generic_calls` | 250.4 ± 19.1 ms | 71.4 ± 2.6 ms | **68.6 ± 2.3 ms** | **1.04× faster** |

The comparison column always uses the faster of `tsc` and `tsgo`, so Home must
beat both compilers to record a win. These are local synthetic measurements,
not a claim that every real project or machine has the same speedup.

## Fairness and measurement

- Compiler versions are pinned in `bench/vs_tsgo/corpus.toml`.
- JavaScript TypeScript 6 and native TypeScript 7 are installed in separate
  tool prefixes so npm cannot replace one implementation with the other.
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
| `tsx_components` | One module with 256 typed generic component declarations and JSX trees | TSX scanning, parsing, contextual props, expressions, and checking |
| `generic_calls` | One module with 256 typed generic call groups | Constrained inference, `keyof`, indexed access, mapped returns, and contextual callbacks |

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
  per-export answers;
- resolver mutation is synchronized separately from export-analysis caches so
  independent cache misses can parse and bind concurrently;
- export-star ambiguity checks enumerate and cache real projected names instead
  of rescanning modules or guessing from the number of barrel declarations;
- JSX namespace, pragma, and source-feature probes reuse immutable per-source
  facts; and
- recovered parameter annotations are indexed in one source pass instead of
  rescanning the file for every identifier use;
- identifier resolution skips evolving-`any` flow walks when the source has no
  eligible declarations, reuses its lexical annotation lookup, and avoids
  declaration scans for function-arity checks against non-callable targets.
