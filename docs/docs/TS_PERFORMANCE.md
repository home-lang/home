# TypeScript frontend performance

Home maintains a reproducible frontend benchmark for `home-tsc`, TypeScript's
JavaScript implementation (`tsc` 6.x), and stable native TypeScript 7
(`tsgo` in the tables below).
The benchmark measures parse, bind, and type-check work only; all compilers
receive the same valid projects and run with emission disabled.
Ongoing coverage and optimization work is tracked in
[GitHub issue #416](https://github.com/home-lang/home/issues/416).

## Current snapshot

Measured 2026-08-26 at commit `617d29ead` on an Apple M3 Pro MacBook Pro
(11 cores, 18 GB RAM, arm64, macOS 27.0). Each value is the mean and sample
standard deviation of 30 new compiler processes after three warmup rounds.
The local raw-result identifier is `20260827T000322Z`.

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 95.0 ± 86.4 ms | 55.4 ± 51.1 ms | **5.0 ± 6.3 ms** | **11.11× faster** |
| `many_files` | 269.4 ± 73.2 ms | 64.7 ± 15.2 ms | **40.1 ± 12.1 ms** | **1.61× faster** |
| `deep_types` | 127.3 ± 2.1 ms | 52.0 ± 1.5 ms | **17.9 ± 0.4 ms** | **2.91× faster** |
| `import_graph` | 128.2 ± 1.8 ms | 44.9 ± 1.0 ms | **25.6 ± 1.0 ms** | **1.75× faster** |
| `reexport_graph` | 95.0 ± 5.6 ms | 40.4 ± 1.0 ms | **27.1 ± 1.4 ms** | **1.49× faster** |
| `tsx_components` | 158.1 ± 1.6 ms | 46.2 ± 0.9 ms | **27.6 ± 0.4 ms** | **1.67× faster** |
| `generic_calls` | 173.8 ± 1.8 ms | 53.0 ± 0.8 ms | **35.9 ± 5.8 ms** | **1.48× faster** |
| `control_flow` | 185.6 ± 3.2 ms | 57.4 ± 1.2 ms | **49.3 ± 0.5 ms** | **1.17× faster** |
| `overload_resolution` | 195.7 ± 0.8 ms | 63.3 ± 1.1 ms | **54.2 ± 0.6 ms** | **1.17× faster** |
| `class_hierarchy` | 199.6 ± 68.5 ms | 54.1 ± 13.5 ms | **47.6 ± 0.9 ms** | **1.14× faster** |
| `structural_objects` | 180.6 ± 2.5 ms | 57.0 ± 1.1 ms | **47.5 ± 0.8 ms** | **1.20× faster** |

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
| `control_flow` | One module with 256 exhaustive discriminated-union functions | Narrowing, branch joins, definite assignment, exhaustive switches, property reads, and typed object returns |
| `overload_resolution` | One module with 128 groups of eight typed overload calls | Literal-discriminated overload selection, generic inference, object and tuple payloads, callbacks, and typed result consumption |
| `class_hierarchy` | One module with 128 independent generic base/derived/interface families | Class heritage resolution, generic substitution, constructors, overrides, protected members, interface compatibility, and typed instance consumption |
| `structural_objects` | One module with 128 independent source/target object families | Nested structural compatibility, optional and readonly members, tuples, intersections, generic function properties, excess source members, assignments, and typed argument passing |

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
  declaration scans for function-arity checks against non-callable targets;
- checker compatibility paths use conservative source-feature facts to skip
  impossible UMD, import, CommonJS, namespace, class, enum, and expando scans;
- simple annotated bindings and their active lexical lookups reuse indexed,
  virtual-section-aware declarations and already-resolved types for ordinary
  reads while declared-type lookups retain their full semantic path;
- overload resolution rejects definite exact-literal mismatches before generic
  inference and substitution, while composite, contextual, spread, enum, and
  ambiguous candidates retain the complete resolver; and
- successful class heritage instance, static, and constructor resolutions are
  cached by extends expression while unresolved and forward-reference paths
  retain the complete resolver;
- conservative source facts skip impossible enum and JavaScript prototype
  searches, `this` and `super` member assignments avoid irrelevant function
  expando discovery, and top-level annotation lookup reuses the existing
  virtual-section-aware declaration index; and
- DOM library availability is computed once per source and reused while
  lowering annotations, preserving `@noLib`, `reference lib`, and explicit
  `@lib` semantics without repeatedly scanning the entire file; and
- program-level declaration, namespace, interface, class, and CommonJS
  collectors skip files whose source cannot contain the syntax they collect.

The `control_flow` workload was deliberately added before these optimizations.
Its five-run red baseline (`20260826T203831Z`) measured Home at
2,927.8 ± 159.6 ms versus native TypeScript 7 at 81.5 ± 21.8 ms. The unchanged
workload now measures 56.7 ± 25.4 ms in the 30-run snapshot above: a 51.6×
Home improvement and a 1.09× win over the fastest competitor. The improvement
came from removing repeated general-purpose source and HIR scans; the corpus,
compiler options, validity gate, and measurement schedule were not weakened.

The `overload_resolution` workload was likewise frozen before its optimization.
Its five-run red baseline (`20260826T221712Z`) measured Home at
126.9 ± 0.9 ms versus native TypeScript 7 at 70.3 ± 1.1 ms. The unchanged
workload now measures 58.1 ± 2.2 ms in the 30-run snapshot above: a 2.18×
Home improvement and a 1.14× win over the fastest competitor. The optimized
path only eliminates candidates whose fixed primitive literal parameter is
provably incompatible with the corresponding literal expression.

The `class_hierarchy` workload was also frozen before optimization. Its
five-run red baseline (`20260826T232221Z`) measured Home at 79.4 ± 2.8 ms
versus native TypeScript 7 at 59.6 ± 1.5 ms. The unchanged workload now
measures 50.7 ± 15.9 ms in the 30-run snapshot above: a 1.57× Home
improvement and a 1.06× win over the fastest competitor. The optimization
caches successful general-purpose heritage resolutions and removes source or
HIR scans only when conservative facts prove the searched construct cannot
apply; the source, compiler options, validity gate, and schedule are unchanged.

The `structural_objects` workload was frozen before optimization. Its five-run
red baseline (`20260826T234904Z`) measured Home at 160.9 ± 4.5 ms versus
native TypeScript 7 at 62.7 ± 2.7 ms. The unchanged workload now measures
47.5 ± 0.8 ms in the 30-run snapshot above: a 3.39× Home improvement and
a 1.20× win over the fastest competitor. Profiling found that DOM library
availability was rescanning the complete source for every relevant annotation;
the result now uses the checker's existing per-source fact lifecycle. The
corpus, compiler options, validity gate, and measurement schedule were not
weakened.
