# TypeScript frontend performance

Home maintains a reproducible frontend benchmark for `home-tsc`, TypeScript's
JavaScript implementation (`tsc` 6.x), and stable native TypeScript 7
(`tsgo` in the tables below).
The benchmark measures parse, bind, and type-check work only; all compilers
receive the same valid projects and run with emission disabled.
Ongoing coverage and optimization work is tracked in
[GitHub issue #416](https://github.com/home-lang/home/issues/416).

## Current snapshot

Measured 2026-08-27 at commit `3c6f4e69e` on an Apple M3 Pro MacBook Pro
(11 cores, 18 GB RAM, arm64, macOS 27.0). Each value is the mean and sample
standard deviation of 30 new compiler processes after three warmup rounds.
The local raw-result identifier is `20260827T172600Z`. Home records a lower
mean than the faster competitor on 17 of 18 workloads. The new large predicate
workload is 1.57× slower than native TypeScript 7, while the original smaller
workload has a 1.24× mean lead. The round-robin compiler order and complete,
unfiltered 30-sample result are retained. Several workloads have substantial
variance; these local results do not establish universal superiority.

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 81.9 ± 15.6 ms | 49.0 ± 11.1 ms | **3.9 ± 0.6 ms** | **12.50× faster** |
| `many_files` | 247.0 ± 11.2 ms | 65.9 ± 7.2 ms | **37.1 ± 3.4 ms** | **1.77× faster** |
| `deep_types` | 152.7 ± 11.1 ms | 59.9 ± 2.3 ms | **17.2 ± 4.1 ms** | **3.48× faster** |
| `import_graph` | 150.4 ± 6.3 ms | 53.4 ± 2.8 ms | **31.9 ± 2.9 ms** | **1.67× faster** |
| `reexport_graph` | 109.8 ± 3.9 ms | 48.4 ± 6.3 ms | **31.5 ± 2.0 ms** | **1.54× faster** |
| `tsx_components` | 193.9 ± 16.5 ms | 54.8 ± 3.5 ms | **27.4 ± 2.0 ms** | **2.00× faster** |
| `generic_calls` | 235.1 ± 47.4 ms | 65.0 ± 7.6 ms | **29.2 ± 1.9 ms** | **2.23× faster** |
| `control_flow` | 207.8 ± 13.2 ms | 64.1 ± 1.9 ms | **46.7 ± 1.2 ms** | **1.37× faster** |
| `type_predicates` | 328.8 ± 184.9 ms | 91.7 ± 47.2 ms | **74.1 ± 27.2 ms** | **1.24× faster** |
| `type_predicates_large` | 1105.1 ± 100.4 ms | 377.6 ± 18.3 ms | 592.0 ± 14.6 ms | 1.57× slower |
| `null_safe_access` | 194.2 ± 7.2 ms | 58.5 ± 4.3 ms | **46.3 ± 1.9 ms** | **1.26× faster** |
| `destructuring` | 138.6 ± 2.7 ms | 46.7 ± 1.4 ms | **37.8 ± 0.6 ms** | **1.24× faster** |
| `overload_resolution` | 204.6 ± 22.1 ms | 64.0 ± 1.5 ms | **35.8 ± 0.9 ms** | **1.79× faster** |
| `class_hierarchy` | 185.5 ± 5.8 ms | 53.9 ± 6.7 ms | **34.0 ± 0.8 ms** | **1.58× faster** |
| `structural_objects` | 184.1 ± 2.5 ms | 57.4 ± 1.4 ms | **35.5 ± 0.6 ms** | **1.62× faster** |
| `interface_composition` | 200.2 ± 7.2 ms | 62.0 ± 1.0 ms | **47.7 ± 0.5 ms** | **1.30× faster** |
| `variadic_tuples` | 264.3 ± 101.9 ms | 75.1 ± 1.6 ms | **49.7 ± 0.6 ms** | **1.51× faster** |
| `checkjs_jsdoc` | 212.0 ± 21.5 ms | 55.3 ± 5.5 ms | **42.6 ± 11.1 ms** | **1.30× faster** |

The earlier snapshot `20260827T154256Z` recorded a checked-JavaScript loss:
Home 58.4 ± 33.3 ms versus native TypeScript 7 at 56.5 ± 2.7 ms, including one
234.3 ms Home sample (52.1 ms median). That unfiltered result remains part of
the record. [Issue #452](https://github.com/home-lang/home/issues/452) addressed
the narrow margin with the general function-containment index described below;
snapshot `20260827T155812Z` then recorded 16/16 mean wins. The current
18-workload snapshot additionally includes destructuring, negative
named-shape caching, function-declaration indexing, necessary member-fact
filtering, local value-declaration indexing, and the large predicate scaling
case; no samples were discarded. The first 18-workload snapshot
`20260827T165255Z` recorded Home at 855.8 ± 42.1 ms against native TypeScript 7
at 382.3 ± 25.1 ms on large predicates (2.24× slower); it remains part of the
record. The current large row is 592.0 ± 14.6 versus 377.6 ± 18.3 ms
(1.57× slower). Unrelated concurrent workstation jobs were observed around
this measurement session; the original-size predicate row is particularly
noisy, and no samples were filtered or replaced.

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
- Destructuring also has five automatic negative controls in an untimed
  temporary project copy: nested properties, tuple elements, object-rest
  fields, defaults, and omitted rest properties must produce exactly four
  `TS2322` diagnostics and one `TS2339` in every compiler.
- Both predicate sizes have four automatic controls inside the guard branch and
  after the assertion call. Invalid narrowed-property assignments and reads
  of excluded union members must produce two `TS2322` and two `TS2339`
  diagnostics in every compiler, using an untimed temporary project copy.
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
| `type_predicates` | One module with 256 independent predicate families | User-defined type predicates, assertion functions, call-driven narrowing, nested property reads, and typed consumption |
| `type_predicates_large` | The identical generator with 2,048 independent predicate families | Scaling behavior at eight times the original size, with the same feature mix, compiler options, and negative controls |
| `null_safe_access` | One module with 256 independent nullable object families | Optional property, element, and call chains, nullish coalescing, non-null assertions, and typed consumption |
| `destructuring` | One module with 128 independent object families | Nested object and tuple bindings, defaults, object rest, spread reconstruction, and typed consumption |
| `overload_resolution` | One module with 128 groups of eight typed overload calls | Literal-discriminated overload selection, generic inference, object and tuple payloads, callbacks, and typed result consumption |
| `class_hierarchy` | One module with 128 independent generic base/derived/interface families | Class heritage resolution, generic substitution, constructors, overrides, protected members, interface compatibility, and typed instance consumption |
| `structural_objects` | One module with 128 independent source/target object families | Nested structural compatibility, optional and readonly members, tuples, intersections, generic function properties, excess source members, assignments, and typed argument passing |
| `interface_composition` | One module with 128 independent generic interface and namespace families | Multi-base interface heritage, repeated declaration merging, namespace/type/value merging, nested exported interfaces, generic functions, structural values, and typed consumption |
| `variadic_tuples` | One module with 256 independent readonly tuple families | Variadic tuple concat, readonly inference, conditional head/tail extraction, generic rest and spread, indexed reads, and typed consumption |
| `checkjs_jsdoc` | One checked-JavaScript module with 128 independent JSDoc families | JSDoc typedefs, constrained templates, callbacks, classes, property reads, and typed consumption |

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
- named types maintain a validated reverse display-name index instead of
  repeatedly iterating the complete forward name table;
- visible namespaces and simple annotated declarations reuse lexical,
  virtual-section-aware indexes, including a conservative dotted-namespace
  fact that avoids impossible fallback scans;
- interface declaration merging records the real predecessor chain so generic
  and non-generic back-patching touches only declarations in the merge; and
- module augmentation, type-alias, and class/interface compatibility paths use
  syntax facts before performing root-level searches, while allocation failure
  retains the original semantic resolver; and
- program-level declaration, namespace, interface, class, and CommonJS
  collectors skip files whose source cannot contain the syntax they collect;
- generic-instantiation inference skips parameters without free type variables,
  while the full recursive inference path remains active for inferable pairs;
- visible same-name values are indexed by lexical container and virtual source
  section;
- function-expando and plain-import recovery stop before scope walks when HIR
  or source facts prove the relevant syntax is absent; and
- checked-JavaScript analysis indexes named JSDoc declarations, prior typed
  assignments, annotated values, and owning functions; reuses immutable
  typedef and callback types; and skips prototype, import, expando, and
  accessibility searches only when exact source facts prove they cannot apply;
- type aliases and parameter annotations use exact-name indexes, root variable
  recovery reuses binder declarations, and direct named object types reuse
  their reverse display-name mapping and successful structural-name matches;
- CommonJS detection matches `require` as an identifier rather than a
  substring, while import, class, enum, namespace, and type-declaration
  fallbacks stop only when conservative source facts make the search
  impossible;
- source-annotation recovery stops when the nearest lexical parameter and its
  following source token prove there is no annotation to recover, while
  explicit annotations, comments, destructuring, and ambiguous syntax retain
  the complete fallback;
- source-function ownership uses sorted nested function spans for first-time
  position queries, preserving the original full scan for malformed crossing
  ranges or allocation failure and the original NodeId tie-breaking; and
- source-parameter recovery lazily caches immutable containment ranges per
  annotation candidate instead of repeating raw source scans for each use,
  with exhaustive position-pair equivalence and source-reset tests; and
- unsuccessful named-object-shape searches are cached separately for each
  class-preference mode, with a generation guard that expires misses when
  a type name is inserted or rebound; and
- function-declaration lookup indexes the first eligible binding per statement
  container, preserving caller scope walks and binder precedence and retaining
  the original scanner on allocation failure;
- named-shape lookup indexes necessary member facts at type-name registration,
  rejecting impossible searches while retaining the original full comparison
  for possible matches, stale facts, and hash collisions;
- local value-declaration lookup indexes first bindings and exact statement
  boundaries per container and virtual section, preserving the original scan
  on allocation failure; and
- the lockless relation cache retains a 4,096-entry working set and inserts new
  relations with one hash-table probe instead of two.

## Historical workload milestones

The comparisons below retain each recorded milestone and its snapshot ID;
they are not replacements for the latest unfiltered table above.

The `control_flow` workload was deliberately added before these optimizations.
Its five-run red baseline (`20260826T203831Z`) measured Home at
2,927.8 ± 159.6 ms versus native TypeScript 7 at 81.5 ± 21.8 ms. The unchanged
workload measured 41.6 ± 0.7 ms in snapshot `20260827T151143Z`: a 70.4×
Home improvement and a 1.34× win over the fastest competitor. The improvement
came from removing repeated general-purpose source and HIR scans; the corpus,
compiler options, validity gate, and measurement schedule were not weakened.

The `overload_resolution` workload was likewise frozen before its optimization.
Its five-run red baseline (`20260826T221712Z`) measured Home at
126.9 ± 0.9 ms versus native TypeScript 7 at 70.3 ± 1.1 ms. The unchanged
workload measured 36.2 ± 0.5 ms in snapshot `20260827T151143Z`: a 3.51×
Home improvement and a 1.69× win over the fastest competitor. The optimized
path only eliminates candidates whose fixed primitive literal parameter is
provably incompatible with the corresponding literal expression.

The `class_hierarchy` workload was also frozen before optimization. Its
five-run red baseline (`20260826T232221Z`) measured Home at 79.4 ± 2.8 ms
versus native TypeScript 7 at 59.6 ± 1.5 ms. The unchanged workload measured
34.8 ± 1.6 ms in snapshot `20260827T151143Z`: a 2.28× Home improvement
and a 1.48× win over the fastest competitor. The optimization caches successful
general-purpose heritage resolutions and removes source or HIR scans only when
conservative facts prove the searched construct cannot apply; the source,
compiler options, validity gate, and schedule are unchanged.

The `structural_objects` workload was frozen before optimization. Its five-run
red baseline (`20260826T234904Z`) measured Home at 160.9 ± 4.5 ms versus
native TypeScript 7 at 62.7 ± 2.7 ms. The unchanged workload measured
35.2 ± 1.5 ms in snapshot `20260827T151143Z`: a 4.57× Home improvement and
a 1.58× win over the fastest competitor. Profiling found that DOM library
availability was rescanning the complete source for every relevant annotation;
the result now uses the checker's existing per-source fact lifecycle. The
corpus, compiler options, validity gate, and measurement schedule were not
weakened.

The `interface_composition` workload was frozen before optimization. Its
five-run red baseline (`20260827T000848Z`) measured Home at 117.3 ± 3.0 ms
versus native TypeScript 7 at 65.3 ± 0.8 ms. The unchanged workload measured
47.1 ± 1.2 ms in snapshot `20260827T151143Z`: a 2.49× Home improvement
and a 1.29× win over the fastest competitor. The implementation replaces
repeated namespace, declaration-merge, annotation, and type-name searches with
validated indexes and conservative source facts. The generated source, compiler
options, silent-success validity gate, and interleaved schedule remain
unchanged.

The `variadic_tuples` workload was frozen before optimization. Its five-run red
baseline (`20260827T072451Z`) measured Home at 209.4 ± 4.8 ms versus native
TypeScript 7 at 100.7 ± 3.3 ms. The exact same generated project measured
48.5 ± 0.8 ms in snapshot `20260827T151143Z`: a 4.32× Home improvement and a
1.50× win over the fastest competitor. The general changes prune non-inferable
generic pairs, index lexical value declarations, retain the relation working
set, and skip syntax-inapplicable scans.
The corpus, compiler options, silent-success validity gate, and interleaved
schedule were not changed after the baseline was recorded.

The `checkjs_jsdoc` workload was accepted and frozen only after Home, `tsc`,
and `tsgo` all checked the same JavaScript project successfully and all three
rejected a preserved invalid variant with `TS2322`. The first semantically
valid Home implementation was impractically slow because it repeatedly found
the owning function and JSDoc declaration for each use; at 64 generated
families it took roughly 14 seconds and its growth made a 128-family timing
run unsuitable as a benchmark baseline. A direct development comparison after
the first general indexing pass still measured Home at 150.7 ± 17.5 ms versus
native TypeScript 7 at 111.4 ± 8.7 ms and `tsc` at 555.0 ± 74.8 ms. The
unchanged accepted workload measured 49.3 ± 1.0 ms in interleaved snapshot
`20260827T151143Z`, a 3.06× Home improvement from that intermediate result
and a 1.06× win over the fastest competitor. The implementation indexes named
JSDoc declarations and their owning functions, memoizes immutable physical
typedef and callback types, reuses binder and lexical indexes, and uses exact
source facts to avoid searches that cannot apply. Virtual sections and scoped
fallback resolution retain their complete semantic paths.

The `type_predicates` workload was frozen at SHA-256
`8b04ff5b9ae889c940facb652e5c925c7ff2aa6350058292208ca29020192350`
before optimization. Home, `tsc` 6.0.3, and native TypeScript 7.0.2 all accept
the same 13,312-line project silently, and all three reject a preserved variant
that assigns a narrowed string property to `number` with `TS2322`. Its
five-run red baseline (`20260827T133314Z`) measured Home at 132.3 ± 1.8 ms
versus native TypeScript 7 at 79.8 ± 1.4 ms. The unchanged workload measured
69.0 ± 4.9 ms in snapshot `20260827T151143Z`: a 1.92× Home improvement
and a 1.01× win over the fastest competitor. The general implementation uses
exact token-aware source facts, lexical declaration indexes, parameter-name
buckets, binder-backed root lookups, and successful named-shape caches; it does
not recognize the benchmark's generated names or family count.

The `null_safe_access` workload was frozen at 8,192 lines and 245,538 bytes,
with SHA-256
`22559101b63ff7129383baa604a006d33a37cd0ba4aa499a849ffd26894ff57c`.
All three compilers accept the same project silently and reject a preserved
invalid tuple string-to-number assignment with `TS2322`. Its five-run red
baseline (`20260827T152206Z`) measured Home at 1166.8 ± 11.0 ms versus native
TypeScript 7 at 62.1 ± 1.6 ms: an 18.79× loss. In the unchanged 30-run
snapshot `20260827T154256Z`, Home measures 51.1 ± 14.1 ms versus 71.3 ± 26.9
ms for native TypeScript 7, a 22.83× Home improvement and a 1.40× mean win.
Profiling found source-annotation recovery repeatedly searching unrelated
typed signatures for contextually typed, unannotated arrow parameters. The
general lexical/source guard removes only that impossible search. A scaled
1,024-family profiling copy dropped from 71.70 seconds to 0.32 seconds; the
accepted corpus, configuration, validity gate, and timing schedule stayed
unchanged. The complete checker gate passes 4,192 tests including the new
source-recovery regression.

The checked-JavaScript margin follow-up retained the losing snapshot
`20260827T154256Z` rather than filtering its slow sample. Profiling a
2,048-family same-shape copy showed that first-time JSDoc comment ownership
queries still scanned every HIR node. Commit `332e22826` builds a sorted,
nested function-span index and resolves those positions by binary search plus
the enclosing-span chain. Its regression compares indexed and original-scan
answers at every source position in nested function, arrow, and function
expression input, and checks source-state invalidation. The scaled profile
copy fell from 4.55 seconds to 2.31 seconds; the unchanged accepted 128-family
source (SHA-256
`898573fc0f2567653fef3edb3675d768f825abd80b83e708e7d57d29049c03ec`)
measures 40.1 ± 0.9 ms versus native TypeScript 7 at 51.7 ± 1.1 ms in snapshot
`20260827T155812Z`, a 1.29× mean win. All three compilers still accept the
valid project silently and reject the preserved string-to-number JSDoc variant
with `TS2322`; the complete checker gate passes 4,193 tests.

The `destructuring` workload was frozen at 4,032 lines and 122,226 bytes,
with SHA-256
`17049403e0a09a25e1f5ca78d730a7a683e78fd375681aaf1af92c460bbde673`.
All three compilers accept the source silently and pass the five automatic
negative controls described above. Its five-run baseline (`20260827T160641Z`)
measured Home at 97.6 ± 0.4 ms versus native TypeScript 7 at 45.3 ± 2.1 ms:
a 2.15× loss. The same baseline also recorded a type-predicate loss, Home
71.4 ± 8.5 ms versus native TypeScript 7 at 68.2 ± 0.4 ms; those results
remain part of the record.

Profiling a 1,024-family same-shape copy found that source-annotation recovery
repeated raw containment scans for each identifier use, including repeated
rejection of object properties that resemble typed parameters. Commit
`06baa9965` materializes each queried name's candidate ranges once and reuses
them, without changing which candidates are accepted. The regression compares
cached and original scan results at every declaration/use position pair in
nested, default-parameter, object-literal, incomplete, and string-containing
sources, and verifies invalidation when source facts change. The scaled
diagnostic run fell from 34.44 seconds to 2.74 seconds; this single-run profile
measurement is not a suite speedup claim. The complete checker gate passes
4,194 tests and the ReleaseFast build passes. The accepted corpus, compiler
configuration, and interleaved timing schedule are unchanged. In the complete
30-run snapshot `20260827T162037Z`, the accepted destructuring project measures
47.8 ± 14.0 ms for Home versus 63.4 ± 25.2 ms for native TypeScript 7: a
1.32× mean win, with the substantial variance explicitly retained.
This milestone is tracked in
[issue #453](https://github.com/home-lang/home/issues/453).

The type-predicate margin follow-up
([issue #455](https://github.com/home-lang/home/issues/455)) retains snapshot
`20260827T162037Z`: Home 78.1 ± 2.3 ms versus native TypeScript 7 at
82.3 ± 7.4 ms, only a 1.05× mean lead. A 2,048-family same-shape profiling
copy measured 1.23 seconds before this follow-up and exposed repeated failed
named-object-shape searches during narrowing. Commit `2de4f7670` caches
negative lookup results with the type-name table generation, separately for
each class-preference mode.
Inserting or rebinding a type name invalidates those misses, while re-registering
the same binding does not. The original shape comparison and successful
lookup behavior are unchanged. Regression coverage checks registration,
same-count rebinding, no-op updates, source reset, and class/non-class
preference separation. The accepted type-predicate source hash is unchanged;
the four automatic negative controls strengthen the gate without adding work
to the timed project. The complete checker gate passes 4,196 tests, the
ReleaseFast build passes, and all three compilers pass all 17 positive projects
plus the nine automatic predicate/destructuring negative controls.

The same scaled diagnostic copy then measured 0.99 seconds, with retired
instructions falling from 16.582 billion to 13.298 billion. These single-run
profiling observations are not the suite comparison. A short, preliminary
10-sample comparison remained noisy (Home 78.9 ± 19.7 ms versus native
TypeScript 7 at 80.3 ± 9.8 ms). Follow-up sampling still identifies first-time
shape searches and function-declaration scans as remaining general costs.

The complete 30-run snapshot `20260827T163618Z` records Home at 87.7 ± 13.5 ms
versus native TypeScript 7 at 93.4 ± 17.1 ms, a 1.07× mean lead. The timing
variance does not establish a robust margin, so issue #455 remains open for
those remaining costs. All 17 workloads have lower Home means in this snapshot;
all samples, including the high-variance null-safe-access row, are retained.

The next #455 follow-up targets repeated function-declaration searches, which
appear at the top of 133 of 495 sampled stacks in the post-cache profiling
trace. A per-container index now retains the first eligible function binding
by name, including exported declarations and variable-bound function/arrow
initializers. Caller scope walks and binder precedence are unchanged; empty
and singleton lists still use the constant-size scan. Indexes are published
only after construction succeeds, and allocation failure uses the original
scanner. Regressions compare indexed and scanned results across overloads,
nested namespaces and blocks, exported bindings, and missing/non-function
names; they also verify source reset and failure at both index allocation
stages. The accepted benchmark source and compiler options remain unchanged.
The full checker suite passes 4,198 tests; the ReleaseFast build, all 17
three-compiler positive gates, and all nine automatic negative controls pass.

Commit `983c2c532` implements the function index. Alternating the preserved
pre-index and new release binaries on the accepted 256-family source gives
72.19 ± 3.12 ms before versus 70.12 ± 3.42 ms after (30 samples per binary,
three warmups). The 2,048-family copy gives 1,056.42 ± 59.81 ms before versus
850.96 ± 23.82 ms after (five samples per binary, two warmups). These are
interleaved before/after development measurements, not competitor results.

That larger input also exposes a remaining scaling loss. A preliminary
five-run, three-warmup round-robin comparison gives Home 801.0 ± 22.4 ms,
native TypeScript 7 at 369.4 ± 15.4 ms, and JavaScript TypeScript 6 at
1,063.8 ± 43.0 ms: Home is 2.17× slower than the faster competitor. All three
compilers accept it silently and reject all four guard/assertion controls.
The workload is now included separately as `type_predicates_large`, with
106,496 lines, 3,032,376 bytes, and SHA-256
`9966d3e8933894a6a67f4f28c606765df0a7650f6cef429a758797151c2f6bca`.
It uses the same generator and configuration; the original 256-family source
is unchanged. [Issue #457](https://github.com/home-lang/home/issues/457)
tracks this scaling gap alongside the smaller-workload margin in #455.
The full 30-run snapshot `20260827T165255Z` preserves the loss: Home
855.8 ± 42.1 ms versus native TypeScript 7 at 382.3 ± 25.1 ms, or 2.24× slower.
The smaller predicate workload measures 67.6 ± 2.6 ms versus 74.7 ± 6.0 ms,
a 1.11× mean lead. All 18 projects pass the shared positive gate, and all 13
automatic negative controls pass in every compiler. Issues #455 and #457
remain open for the remaining general lookup and scaling costs.

Commit `0494dc6b6` for #457 indexes necessary named-shape member facts. Each
fact includes member count, string/number/symbol index-signature types, member
name/type, and optional/readonly/method flags. A missing fact proves that no
registered named object can satisfy the original shape comparison. Present
facts never accept a shape: the full comparison still handles combinations
from different objects, obsolete bindings, and hash collisions. This preserves
the original duplicate-member behavior without adding a quadratic uniqueness
scan. Facts follow the type-name table lifetime across source resets; an
allocation failure disables the filter. Regressions cover member order,
duplicates, modifiers, index signatures, ignored display metadata, rebinding,
false positives, source reset, and allocation failure.
The full checker suite passes 4,201 tests; the release build, all 18 shared
projects, and all 13 automatic negative controls pass for every compiler.
Alternating preserved before/after release binaries gives 67.73 ± 2.85 ms
versus 66.13 ± 6.46 ms on the small workload (30 samples per binary), and
800.16 ± 62.91 ms versus 645.06 ± 13.10 ms on the large workload (10 samples
per binary), each after three warmups. These development comparisons retain
every sample and are separate from the complete competitor snapshot.

Commit `3c6f4e69e` for #457 indexes local value declarations. A fresh profile on an
8,192-family diagnostic copy of the same generator identified local declaration
scans as the largest sampled leaf (357 samples); this diagnostic copy does not
replace either frozen benchmark. The index records first eligible declarations
and exact statement ordinals per container and virtual section. Lookups retain
the nearest-container rule, export-wrapper boundaries, and declaration-order
checks rather than comparing source spans. Empty and singleton containers keep
the original constant-sized scan. Failed index construction releases partial
state and falls back to the original scanner. Differential tests compare both
paths for every syntax node across nested blocks, namespaces, exports, multiple
virtual files, declaration kinds, shadowing, and missing names; allocation
failure tests cover each construction allocation and retry.
All 4,203 checker tests, the release build, 18 shared projects, and 13 negative
controls per compiler pass. Alternating preserved member-fact-only and
local-index binaries after three warmups measured 83.09 ± 20.83 versus
84.58 ± 26.97 ms for the small workload (30 samples each), and 740.15 ± 51.21
versus 632.05 ± 22.70 ms for the large workload (10 samples each). The small
comparison is noisy and does not show an improvement; all samples, including
the 206.09 ms new-binary observation, are retained. Concurrent unrelated
workstation jobs were observed during this development comparison.

The complete post-index snapshot `20260827T172600Z` retains all 30 interleaved
samples after three warmups across all 18 workloads. Home has lower means on
17 of 18; large predicates are 592.0 ± 14.6 ms versus native TypeScript 7 at
377.6 ± 18.3 ms and JavaScript TypeScript 6 at 1105.1 ± 100.4 ms, a 1.57×
loss to native TS 7. Small predicates are 74.1 ± 27.2 versus 91.7 ± 47.2 ms,
a noisy 1.24× mean lead. The full checker suite passes 4,203 tests, all 18
shared projects pass, and all 13 automatic negative controls pass in every
compiler. All 1,620 timed samples exit successfully. Issues #455 and #457
remain open: general type-display-name scans and relation-cache pressure
remain profiling targets, and this snapshot does not establish an everywhere
win or a reliable small-predicate margin.
