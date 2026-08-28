# TypeScript frontend performance

Home maintains a reproducible frontend benchmark for `home-tsc`, TypeScript's
JavaScript implementation (`tsc` 6.x), and stable native TypeScript 7
(`tsgo` in the tables below).
The benchmark measures parse, bind, and type-check work only; all compilers
receive the same valid projects and run with emission disabled.
Ongoing coverage and optimization work is tracked in
[GitHub issue #416](https://github.com/home-lang/home/issues/416).

## Current snapshot

**Admission correction:** the `import_graph` and `reexport_graph` speed claims
are withdrawn throughout this document, including historical snapshots.
Home accepts invalid imported-property assignments and missing-member reads
that TS 6.0.3 and native TS 7.0.2 reject. The measurements are retained, but they
do not establish equivalent semantic work; see [#487](https://github.com/home-lang/home/issues/487)
and the [untimed admission audit](#global-declaration-and-graph-admission-audit-untimed).
The previous all-18 leadership statement is therefore not a fair benchmark-win
claim. Other rows remain provisional pending broader rejection-control
coverage; the existing predicate/destructuring controls do not establish parity
for every other feature.

Measured 2026-08-27 at commit `9e45e105d` on an Apple M3 Pro MacBook Pro
(11 cores, 18 GB RAM, arm64, macOS 27.0). Each value is the mean and sample
standard deviation of 30 new compiler processes after three warmup rounds.
The local raw-result identifier is `20260827T202656Z`. Home records a lower
mean than the faster competitor on all 18 workloads. Large predicates have a
1.08× mean lead, independently confirmed at 1.08× in the additional 30-round
run `20260827T203044Z`. The original smaller workload has a 1.56× mean lead.
The round-robin compiler order and complete, unfiltered samples from both runs
are retained. Several workloads have substantial variance; these local results
do not establish universal superiority.

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 64.4 ± 1.8 ms | 42.2 ± 11.3 ms | **3.9 ± 2.7 ms** | **10.82× faster** |
| `many_files` | 213.2 ± 14.8 ms | 53.5 ± 3.1 ms | **30.0 ± 1.5 ms** | **1.78× faster** |
| `deep_types` | 127.9 ± 2.2 ms | 52.6 ± 1.5 ms | **12.9 ± 0.3 ms** | **4.09× faster** |
| `import_graph` | 129.2 ± 1.9 ms | 45.0 ± 0.9 ms | 25.8 ± 1.1 ms | Ineligible: #487 |
| `reexport_graph` | 94.7 ± 3.0 ms | 40.7 ± 0.9 ms | 26.8 ± 0.6 ms | Ineligible: #487 |
| `tsx_components` | 159.1 ± 1.2 ms | 46.3 ± 0.9 ms | **21.3 ± 0.3 ms** | **2.17× faster** |
| `generic_calls` | 177.5 ± 4.4 ms | 55.4 ± 11.2 ms | **22.0 ± 1.8 ms** | **2.52× faster** |
| `control_flow` | 212.2 ± 127.9 ms | 63.1 ± 22.3 ms | **32.9 ± 3.8 ms** | **1.92× faster** |
| `type_predicates` | 237.3 ± 14.0 ms | 72.4 ± 10.8 ms | **46.5 ± 19.5 ms** | **1.56× faster** |
| `type_predicates_large` | 1027.8 ± 117.6 ms | 348.8 ± 15.7 ms | **322.1 ± 13.3 ms** | **1.08× faster** |
| `null_safe_access` | 206.3 ± 12.4 ms | 60.3 ± 2.4 ms | **40.6 ± 1.8 ms** | **1.49× faster** |
| `destructuring` | 144.3 ± 11.1 ms | 48.5 ± 1.1 ms | **35.3 ± 0.8 ms** | **1.38× faster** |
| `overload_resolution` | 222.7 ± 20.6 ms | 71.6 ± 10.7 ms | **30.9 ± 2.9 ms** | **2.32× faster** |
| `class_hierarchy` | 200.0 ± 17.6 ms | 55.8 ± 4.5 ms | **29.8 ± 1.1 ms** | **1.87× faster** |
| `structural_objects` | 197.7 ± 9.7 ms | 60.7 ± 2.8 ms | **31.5 ± 1.1 ms** | **1.93× faster** |
| `interface_composition` | 233.3 ± 43.6 ms | 76.2 ± 30.3 ms | **46.5 ± 3.4 ms** | **1.64× faster** |
| `variadic_tuples` | 268.4 ± 33.0 ms | 81.0 ± 8.5 ms | 46.2 ± 8.3 ms | Provisional: older admission schema |
| `checkjs_jsdoc` | 246.4 ± 48.7 ms | 63.0 ± 16.6 ms | **41.2 ± 6.8 ms** | **1.53× faster** |

The earlier snapshot `20260827T154256Z` recorded a checked-JavaScript loss:
Home 58.4 ± 33.3 ms versus native TypeScript 7 at 56.5 ± 2.7 ms, including one
234.3 ms Home sample (52.1 ms median). That unfiltered result remains part of
the record. [Issue #452](https://github.com/home-lang/home/issues/452) addressed
the narrow margin with the general function-containment index described below;
snapshot `20260827T155812Z` then recorded 16/16 mean wins. The current
18-workload snapshot additionally includes destructuring, negative
named-shape caching, function-declaration indexing, necessary member-fact
filtering, local value-declaration indexing, registered-TypeId filtering,
relation-cache tombstone maintenance, named-shape candidate indexing, static
builtin-name lookup, shared exact source-marker searches, candidate directive-line
iteration, shared builtin Function member construction, exact conditional-assignment
absence filters, shared program collection markers, stronger primitive-return
validation, and the large predicate scaling case; no samples were discarded.
The first 18-workload snapshot
`20260827T165255Z` recorded Home at 855.8 ± 42.1 ms against native TypeScript 7
at 382.3 ± 25.1 ms on large predicates (2.24× slower); it remains part of the
record. Snapshot `20260827T172600Z` recorded 592.0 ± 14.6 versus
377.6 ± 18.3 ms (1.57× slower). Snapshot `20260827T174752Z` recorded
557.5 ± 157.8 versus 380.1 ± 23.4 ms (1.47× slower). Snapshot
`20260827T181303Z` recorded 549.4 ± 87.3 versus 460.4 ± 126.6 ms
(1.19× slower). Snapshot `20260827T183613Z` recorded 491.0 ± 54.1 versus
430.2 ± 40.9 ms (1.14× slower). Snapshot `20260827T185149Z` recorded
399.7 ± 25.6 versus 338.0 ± 16.1 ms (1.18× slower). Snapshot `20260827T191750Z`
recorded 379.3 ± 15.8 versus 356.0 ± 20.1 ms (1.07× slower). Snapshot
`20260827T193257Z` recorded 326.0 ± 10.0 versus 326.6 ± 8.3 ms (near tie).
Snapshot `20260827T195539Z` recorded 323.8 ± 10.2 versus 351.4 ± 15.2 ms
(1.09× faster), independently confirmed at 1.10×. The current large row is
322.1 ± 13.3 versus 348.8 ± 15.7 ms (1.08× faster).
Unrelated concurrent workstation jobs were observed during earlier measurement
sessions; several current rows are also noisy, and no samples were filtered
or replaced. The different sessions
do not by themselves isolate the effect of each optimization.

The comparison column always uses the faster of `tsc` and `tsgo`. Ratios
rounding to `1.00×` are labeled near ties in either direction, not directional
wins. This is a display-resolution rule, not a statistical significance test;
other directional labels also compare means, not certainty. These are local
synthetic measurements, not a claim that every real project or machine has
the same speedup.

## Fairness and measurement

- Compiler versions are pinned in `bench/vs_tsgo/corpus.toml`. The runner rejects
  an installed TS 6 or TS 7 version that differs from its exact pin before
  recording results; rerun `setup` after changing a pin. Native TS 7 is the
  single `tsgo` entry, not an additional competitor.
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

These snapshots use the direct macOS runner, not the legacy benchmark
Dockerfile. That container recipe still has stale tool installation and build
assumptions; aligning and validating it is tracked in
[issue #464](https://github.com/home-lang/home/issues/464). No Linux/container
performance result is claimed here.

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

An independent confirmation of a selected workload uses the same validation
and interleaved timing rules:

```sh
./bench/vs_tsgo/run.sh cold --runs 30 --warmup 3 --workload type_predicates_large
```

The selection is recorded in metadata. Repeat `--workload` to select several
cases; omitting it runs the full suite. Targeted runs supplement the full
report, never replace it or justify discarding an earlier result.

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
- member facts also identify candidate names, using the smallest queried
  bucket; unique full matches return directly, while ambiguous matching names
  retain the original table scan and diagnostic-name order;
- local value-declaration lookup indexes first bindings and exact statement
  boundaries per container and virtual section, preserving the original scan
  on allocation failure;
- exact type-name fallback skips never-registered TypeIds using monotonic
  membership, preserving scan order for possible matches and disabling the
  filter if an allocation fails;
- builtin-name membership uses a compile-time static lookup over the unchanged
  spelling list, retaining source-dependent exceptions; and
- the lockless relation cache retains a 4,096-entry working set and inserts new
  relations with one hash-table probe instead of two; both relation-cache
  levels reclaim deletion tombstones at existing FIFO eviction boundaries.

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

Commit `403482530` for #457 avoids exact type-name scans for never-registered type
IDs. A fresh profile of the frozen large workload recorded 36 sampled leaves
in `knownTypeDisplayName`; the 8,192-family diagnostic recorded 406. A
monotonic set is populated at the single type-name registration path. Missing
membership proves no exact-ID match exists; obsolete membership only permits
the original scan. This deliberately does not infer absence from the reverse
display-name map: rebinding its selected name can remove that reverse entry
while another alias still refers to the original type. The set follows the
type-name table across source resets, and allocation failure disables the
filter. Regressions cover registration after a miss, alternate aliases after
rebinding, obsolete IDs, source lifetime, structural/class/alias precedence,
and allocation failure during registration.
All 4,206 checker tests, the release build, all 18 shared projects, and all 13
automatic negative controls per compiler pass. Alternating preserved binaries
after three warmups measured small predicates at 73.89 ± 15.23 versus
74.79 ± 20.16 ms (30 samples each), and large predicates at 679.77 ± 165.58
versus 556.70 ± 27.55 ms (10 samples each). These noisy development results
retain every observation, including a 1,128.47 ms old-binary large sample and
a 155.18 ms new-binary small sample; the small comparison shows no improvement.

Commit `8187216d7` addresses FIFO relation-cache tombstone accumulation.
A deterministic diagnostic used the production capacities, packed relation
keys, 16×capacity unique insertions, and the existing half-cache FIFO eviction.
Without maintenance, the 4,096-entry cache had 8,192 backing slots containing
4,096 live entries and 4,096 tombstones: no free slots to terminate misses.
The 16,384-entry cache had only one free slot among 32,768. Rehashing in place
at each existing eviction boundary retained the same live entries and restored
4,096 and 16,384 free slots respectively. Both cache levels now perform this
allocation-free maintenance without changing capacity, FIFO order, pending
markers, or promotion behavior. A regression first failed on retained
tombstones, then passed with rehashing; it checks 512 insertions per level,
all retained/evicted results, pending-to-final overwrites, unchanged overwrite
order, and zero allocation attempts after reserving capacity.
All 4,207 checker tests, the release build, the 18 shared projects, and all 13
negative controls per compiler pass. The isolated cache-maintenance comparison
ran under substantial concurrent workstation activity: small
predicates were 112.81 ± 19.02 versus 114.80 ± 29.86 ms (30 samples each), and
large predicates were 940.16 ± 112.91 versus 1009.84 ± 243.44 ms (10 samples
each), after three warmups. Both new-binary means are higher in this comparison;
it does not demonstrate a timing improvement. All observations are retained,
including the 225.53 ms small and 1,537.53 ms large new-binary samples. The
deterministic tombstone regression establishes the corrected cache behavior,
not an end-to-end speedup by itself.
A fresh 8,192-family diagnostic profile after both changes no longer lists
exact type-name scanning or relation-cache lookup/insert among its leading
sampled leaves. Named-object shape comparisons lead with 390 samples, followed
by string comparisons at 338. This identifies the next profiling target; the
different profiles are not interchangeable timing measurements.

The full post-maintenance snapshot `20260827T174752Z` records 17/18 lower
Home means. Large predicates remain a loss: Home 557.5 ± 157.8 ms versus
native TypeScript 7 at 380.1 ± 23.4 ms and JavaScript TypeScript 6 at
1152.4 ± 255.2 ms, or 1.47× slower than the faster competitor. Small
predicates are 66.6 ± 3.8 versus 82.4 ± 26.5 ms, a 1.24× mean lead.
All 1,620 timed samples exit successfully, after all 18 positive projects
and all 13 negative controls pass in each compiler. Both published tables
match the raw data, and the frozen predicate hashes are unchanged.
[Issue #455](https://github.com/home-lang/home/issues/455) and
[issue #457](https://github.com/home-lang/home/issues/457) stay open for the uncertain small margin and remaining scaling
loss. Named-object shape comparisons are the next profiled target; any further
index must preserve member-order/duplicate behavior, binding lifetime, class
preference, and diagnostic-name selection rather than changing checked work.

Commit `4fccb476d` for #457 upgrades necessary member facts into candidate
buckets backed by a contiguous list. A valid named shape must occur in every
queried member's bucket, so the smallest bucket is a complete candidate set.
The query still checks each current name-to-TypeId binding, class preference,
and the original complete shape comparison. Duplicate member facts, repeated
registrations, stale bindings, and hash collisions cannot accept an invalid
shape. A unique matching name can return directly; multiple distinct matching
names fall back to the original table scan, preserving its diagnostic-name
selection order. This avoids depending on hash-table layout or imposing a new
name preference. Candidate storage follows the type-name table lifetime across
source resets. Failed bucket or list allocation disables the index and keeps
the original scanner. Differential regressions cover ambiguity across table
growth, class preference, member permutations and duplicates, exact-self
exclusion, rebinding, source lifetime, forced collisions, and both allocation
failure points.
All 4,209 checker tests, the release build, all 18 shared projects, and all 13
negative controls per compiler pass. Alternating preserved binaries after
three warmups measured small predicates at 78.63 ± 16.01 versus 80.22 ± 21.36
ms (30 samples each), and large predicates at 547.59 ± 51.70 versus
535.67 ± 38.06 ms (10 samples each). All samples are retained, including the
156.78 ms new-binary small sample. The large mean difference is modest relative
to the variability; this development comparison does not establish a robust
end-to-end improvement, and the small mean is higher.

The follow-up 8,192-family diagnostic profile no longer lists named-shape
comparison among its leading sampled leaves. String comparison leads with
420 samples; `isBuiltinName` is a recurring caller and has 49 direct leaf
samples. Its fixed spelling list (308 entries, 266 distinct spellings) is now
represented by a compile-time static string set in commit `5a537e057`, preserving the exact list,
duplicates, and case-sensitive lookup
without runtime allocation. `ITextWriter` still checks the attached source's
first `@lib` line, and the existing `Iterator`, `fetch`, and `Image` exceptions
remain unchanged. Focused regressions exercise every original list entry,
prefixed/suffixed misses, case variants, empty and non-ASCII names, no-source
behavior, and library-directive changes across source resets.
All 4,211 checker tests, the release build, the 18 shared projects, and all 13
negative controls per compiler pass. Alternating preserved candidate-index
and static-builtin binaries after three warmups measured small predicates at
74.68 ± 5.84 versus 69.55 ± 5.19 ms (30 samples each), and large predicates at
550.26 ± 33.58 versus 501.64 ± 11.87 ms (10 samples each). Every observation
is retained; the full competitor snapshot remains the basis for suite claims.
The post-change diagnostic profile records only two string-equality samples
directly under `isBuiltinName`. Most remaining string-equality samples are
under substring searches (294), including source setup, driver setup, program
collection passes, and directive queries. The next investigation should
attribute these repeated whole-source searches and preserve their exact
matching semantics; these profile counts are not timing speedups.

The full snapshot `20260827T181303Z` retains all 30 interleaved samples after
three warmups across 18 workloads, with 17/18 lower Home means. Large predicates
remain slower: Home 549.4 ± 87.3 ms, native TypeScript 7.0.2 460.4 ± 126.6 ms,
and JavaScript TypeScript 6.0.3 1369.6 ± 302.2 ms, a 1.19× loss to the faster
competitor. Small predicates are 64.8 ± 3.7 versus 83.2 ± 5.9 ms, a 1.28×
mean lead. Several later workloads have substantial variance during unrelated
workstation activity; neither the narrower ratio nor cross-session absolute
times isolate an optimization's effect. All 1,620 timed samples succeeded,
both tables match the raw data, and all 18 positive projects plus 13 negative
controls passed in every compiler. The full checker suite passes 4,211 tests.
Issues #455 and #457 remain open. Next work will investigate repeated
whole-source searches in setup, program collection, and directive handling
without weakening their matching semantics or benchmark inputs.

Commit `b1fe7c9f4` for #457 shares exact source-marker searches. A compile-time
byte automaton records the first position of each fixed substring in one
allocation-free pass, replacing independent setup searches and supplying
positions to existing directive parsers. Comments, strings, identifier
substrings, overlapping matches, and non-ASCII bytes retain the behavior of
independent `std.mem.indexOf` calls. The `require` prefilter retains its
identifier-boundary check. Directive parsing is unchanged, including uppercase
`@noLib` precedence over lowercase `@nolib`, first valid `@checkJs`/`@allowJs`
selection, and their existing case rules. Source replacement rebuilds the
index and clears the original caches. Virtual-filename queries return early
only when the source has neither recognized filename marker.
Differential regressions cover arbitrary generated bytes, overlaps and suffixes,
every setup feature flag, source resets, no-source/index fallback, and directive
precedence and casing. All 4,216 checker tests, the release build, all 18 shared
projects, and all 13 negative controls per compiler pass. Both predicate source
hashes remain unchanged.

The alternating preserved-binary development comparison uses three warmups,
30 small-predicate samples and 10 large-predicate samples per binary. Small
predicates measure 76.87 ± 8.88 ms before and 72.92 ± 9.33 ms after; large
predicates measure 522.19 ± 26.59 and 511.00 ± 59.31 ms. Every observation is
retained, including the new-binary 667.54 ms large sample. These differences are
modest relative to the variability and do not establish a robust end-to-end
speedup. The full interleaved competitor snapshot is the basis for suite claims.

Commit `59b4ad1c8` also adds an exact compiler-version preflight. Its five
regressions cover matching pins, stale TS 6 installs, the old
`7.0.0-dev.20260707.2` native build, prerelease suffixes, and rejection before
any result directory or workload timing is created. Both installed compilers
verify as `Version 6.0.3` and `Version 7.0.2`; the benchmark corpus and measured
commands are unchanged.

The full snapshot `20260827T183613Z` retains all 30 interleaved samples after
three warmups across 18 workloads. Home has 17/18 lower means. Large predicates
remain slower: Home 491.0 ± 54.1 ms, native TypeScript 7.0.2 430.2 ± 40.9 ms,
and JavaScript TypeScript 6.0.3 1278.3 ± 203.3 ms, a 1.14× loss to the faster
competitor. Small predicates measure 76.1 ± 8.6 versus 127.7 ± 15.2 ms,
a 1.68× mean lead. The different workstation conditions and substantial
variance prevent attributing the cross-session ratio change to this commit
alone. All 1,620 timed samples succeeded; balanced compiler ordering, exact
versions, both complete published tables, and frozen predicate hashes were
verified against the raw data. All positive projects and negative controls
passed in each compiler, alongside 4,216 checker tests and five harness tests.
Issues #455 and #457 remain open.

A separate post-run 8,192-family diagnostic profile still attributes 151 of
188 string-equality samples to substring searches. Recurring non-memory
callers include checker and driver setup, program namespace/interface/class
collection, and source-based self-assignment checks. These sample counts guide
the next investigation; they are not speedup measurements or an additional
accepted benchmark. Next work should reuse immutable source facts across
driver/program collection and inspect the remaining prefix searches while
preserving directive parsing, source-update lifetimes, and full type checking.

Commit `f18dd5662` targets repeated driver directive-line scans. The diagnostic
profile attributed 32 scalar-search samples to compiler-option values, 14 to
boolean directives, six to simple directive values, and three to JSX directive
detection. Each parser previously split every source line, although any
accepted directive must contain `@`. An allocation-free candidate-line iterator
now jumps to the next `@` using byte search and returns its complete original
line exactly once. Parsing rules remain unchanged: the first `@` on a line,
case and identifier-boundary rules, malformed or empty values, duplicate-line
order, and parser-specific first-match behavior all retain their prior meaning.
This changes neither tokenization nor type checking and adds no source cache.

Differential tests compare candidate contents and source offsets with
`splitScalar` filtered for `@`, covering arbitrary generated bytes, repeated
lines, embedded markers, CRLF, lone CR, empty input, and EOF. Driver regressions
exercise differing value/boolean parser behavior and JSX directive precedence.
All 173 driver tests, five harness tests, the release build, all 18 shared
projects, and all 13 negative controls per compiler pass. Both predicate hashes
are unchanged.

Alternating preserved binaries after three warmups measured small predicates
at 57.39 ± 3.51 ms before and 54.55 ± 3.26 ms after (30 samples per binary),
and large predicates at 461.76 ± 56.34 versus 426.87 ± 25.74 ms (10 each).
All observations are retained, including the 613.49 ms baseline large sample.
The lower means favor the change, but the large-case variability and outlier
limit the strength of that end-to-end inference; the full interleaved competitor
snapshot remains the basis for suite claims.

The full snapshot `20260827T185149Z` retains all 30 interleaved samples after
three warmups across 18 workloads, with 17/18 lower Home means. Large predicates
remain slower: Home 399.7 ± 25.6 ms, native TypeScript 7.0.2 338.0 ± 16.1 ms,
and JavaScript TypeScript 6.0.3 969.2 ± 31.0 ms, a 1.18× loss to the faster
competitor. Small predicates measure 53.3 ± 0.8 versus 74.6 ± 2.8 ms,
a 1.40× mean lead. All 1,620 timed samples succeeded, and balanced ordering,
exact versions, both complete tables, and frozen predicate hashes were
verified. All 18 positive projects and 13 negative controls pass per compiler;
173 driver tests and five harness tests pass. The unchanged 4,216-test checker
gate also passes from cache. No samples were removed. Some rows remain noisy,
and lower absolute times across sessions do not isolate this commit's effect.

The original small-predicate margin tracked in
[issue #455](https://github.com/home-lang/home/issues/455) is now materially
stronger than its initial 1.05× lead, with the accepted input and configuration
unchanged. This addresses that narrow issue, not universal performance:
[issue #457](https://github.com/home-lang/home/issues/457) remains open for the
large-case loss, and #416 continues to track broader coverage and optimization.

The separate post-run 8,192-family diagnostic profile records only five scalar
search samples under the three changed value/boolean directive parsers, while
program collection and other substring searches remain recurring callers.
Raw builtin lowering has 109 inclusive samples, with leading stacks in the
fixed `Function` signature construction invoked by predicate matching.
Source-based self-conditional-assignment checks also remain prominent.
These are profiling observations, not speedup measurements. The next step is
to check which repeated builtin constructions can be safely reused while
preserving rest-signature metadata and allocation-failure behavior, alongside
the remaining program/source-prefix work.

Commit `b5b5bd938` reuses the fixed internal member recipe for builtin
`Function`: its private `any[]` parameter type and two rest signatures. The
outer object still receives a fresh TypeId on every request, preserving the
existing declaration-identity behavior. The cache is published only after
complete successful construction and shares the checker/interner lifetime;
source replacement does not invalidate these immutable components or their
rest-signature metadata. A cached construction now adds one type instead of
rebuilding all four constituent types.

Three regressions cover structural equivalence with the original constructor,
fresh outer identities, member/parameter/return types, diagnostic names,
rest metadata, source replacement, and cold/cached allocation-failure sweeps
with recovery and leak checks. All 4,219 checker tests, 173 driver tests,
five harness tests, and the release build pass. All 18 positive projects and
13 negative controls pass per compiler; both predicate hashes remain unchanged.

Alternating preserved binaries after three warmups measured large predicates
at 387.24 ± 4.63 ms before and 361.42 ± 7.86 ms after (10 samples each),
about 6.7% lower mean time. Small predicates measured 59.61 ± 25.74 versus
58.96 ± 33.74 ms (30 each), with medians of 52.20 and 48.58 ms. All samples
are retained, including baseline/candidate maxima of 168.10/222.29 ms.
The noisy small-case means do not establish a clear improvement. Unrelated
workstation activity was present, and a source-format check overlapped part
of the paired comparison; these observations are not a controlled estimate
of compiler-only execution time.

The identity audit also found a pre-existing semantic discrepancy tracked in
[issue #467](https://github.com/home-lang/home/issues/467): with a declared
global `Function` containing a `call` method, direct and aliased predicates
fail to narrow a number/function union in Home, although both pinned
competitors accept the typed calls. An empty global `Function` is a distinct
control that correctly retains the union in TS 6 and TS 7. Ordinary assignment
of a function to the nonempty global `Function` already succeeds in Home.
The optimization preserves the baseline's three diagnostics exactly; it does
not fix or conceal that discrepancy, and this diagnostic probe is not an
accepted or timed benchmark. A separate shape-aware semantic correction is
required before #467 can close.

The full snapshot `20260827T191750Z` retains all 30 interleaved samples after
three warmups across 18 workloads, with 17/18 lower Home means. Large predicates
measure Home 379.3 ± 15.8 ms, native TypeScript 7.0.2 356.0 ± 20.1 ms,
and JavaScript TypeScript 6.0.3 1012.4 ± 56.3 ms: Home remains 1.07× slower
than the faster competitor. Small predicates measure 47.4 ± 0.9 versus
69.5 ± 2.3 ms, a 1.47× mean lead. All 1,620 timed samples succeeded;
540 complete rounds, balanced compiler order, exact versions, both tables,
and frozen predicate hashes were verified. All positive projects and negative
controls passed before timing. No samples were discarded or replaced.
The large-case performance issue #457 and broader tracker #416 remain open.

A separate post-run 8,192-family diagnostic profile records 28 inclusive
samples in raw builtin lowering. Substring searches remain prominent, including
program collection and checker/driver setup, while source-based direct
self-conditional-assignment checks account for 34 top-of-stack samples.
These counts identify further investigation targets, not speedup estimates or
an additional accepted benchmark. Next work should inspect repeated program
collection and source-prefix scans while preserving declaration visibility,
source-update lifetimes, and semantic checks.

Commit `dad87a665` removes impossible direct self-conditional-assignment scans.
The existing helper can only return true if the preceding semicolon-delimited
segment contains `?` in the selected assignment's RHS. An exact source-level
absence check now reuses the shared byte-marker index, and a segment-level
absence check rejects other segments before searching for identifier text.
The original assignment, identifier-boundary, and RHS checks still run for
candidates. No tokenization or type-checking rule changes; question marks in
comments and strings retain their original byte-scanning behavior.

Two regressions compare against the original implementation at every source
offset, including beyond EOF, with multiple names, generated bytes, CRLF,
comments/strings, semicolons inside strings, assignment lookalikes, and repeated
assignment candidates. They cover both cached and uncached marker lookup,
positive matches, null source, and repeated source replacement. All 4,221
checker tests, 173 driver tests, five harness tests, and the release build
pass. All 18 shared projects and 13 negative controls pass per compiler;
both predicate hashes remain unchanged. The release toolchain is
Zig `0.17.0-dev.1441+d5181a9c9`, using `ReleaseFast`.

Alternating preserved binaries after three warmups measured small predicates
at 49.30 ± 0.32 ms before and 45.39 ± 0.37 ms after (30 samples each).
Large predicates measured 415.61 ± 44.11 versus 375.56 ± 46.66 ms (10 each),
with medians of 393.78 and 361.44 ms. All observations are retained, including
the 500.35 ms candidate sample. Control flow measured 36.30 ± 2.84 versus
35.45 ± 0.83 ms (30 each), with medians of 35.49 and 35.23 ms and a 50.46 ms
baseline maximum; this does not establish a robust control-flow improvement.
The small-predicate result is consistent, but the large-case variability and
concurrent workstation activity limit the strength of that mean comparison.

The full snapshot `20260827T193257Z` retains all 30 interleaved samples after
three warmups across 18 workloads. Home has a lower mean on all 18, but large
predicates are a near tie: Home 326.0 ± 10.0 ms versus native TypeScript 7.0.2
326.6 ± 8.3 ms, with JavaScript TypeScript 6.0.3 at 956.6 ± 37.9 ms. Home's
0.2% mean advantage is small relative to the observed variability; medians are
323.18 and 324.02 ms. This does not establish a convincing lead, so
[issue #457](https://github.com/home-lang/home/issues/457) remains open for a
robust large-case margin. Small predicates measure 42.8 ± 1.7 versus
68.4 ± 2.0 ms, a 1.60× mean lead. All 1,620 timed samples succeeded;
540 complete rounds, balanced compiler order, exact versions, both tables,
and frozen predicate hashes were verified. No samples were discarded.

Commit `999258e16` makes the report's rounded-equal ratios explicitly say
`1.00× (near tie)` instead of displaying a misleading directional win. Five
regressions cover equality, either direction, and the symmetric two-decimal
boundary; all ten harness/report tests pass. This only changes presentation,
not measurements or their aggregation, and does not claim statistical
significance for larger displayed ratios.

A separate post-run 8,192-family diagnostic profile records only two
inclusive samples in the filtered self-conditional-assignment helper.
Repeated substring searches remain in program ambient-interface, namespace,
class, and CommonJS collection, alongside checker/driver setup. These counts
guide the next investigation, not a speedup claim or a new accepted benchmark.
Next work should share exact program source facts while auditing source
replacement, redirects, and declaration visibility. The broader #416 goal,
the #457 narrow margin, #467 semantic discrepancy, and #464 unvalidated
container harness all remain open.

Commit `d33019821` shares exact program-source marker searches across 19
existing collection prechecks. Nine byte markers cover namespace/global,
ambient interface, class, augmentation, and CommonJS collection. The existing
matcher implementation is reused; collection parsers, identifier rules, and
declaration visibility are unchanged. Matches inside comments, strings, and
larger identifiers retain the original byte-search meaning.

Each serial, streaming, or parallel compilation entry builds a transient
snapshot for non-redirected files and clears it on every exit. Redirect sources
are excluded before reading their bytes. Source replacement invalidates the
snapshot, and calls outside a collection pass retain the original searches.
Snapshot construction adds no allocation path or retained source ownership.

Four new regressions compare exact first positions on generated bytes,
nonempty metadata from all six affected collection categories with and without
snapshots, source replacement and redirect exclusion, and successful/error
cleanup in all three compilation entry points. All 99 program tests,
4,221 checker tests, 173 driver tests, ten harness/report tests, and the final
release build pass. All 18 shared projects and 13 negative controls pass per
compiler, with frozen predicate hashes unchanged.

Alternating preserved binaries after three warmups measured small predicates
at 46.73 ± 6.07 ms before and 43.23 ± 0.75 ms after (30 samples each),
with medians of 45.18 and 43.27 ms. Large predicates measured
355.52 ± 21.14 versus 332.16 ± 7.11 ms (10 each), with medians of
348.05 and 330.08 ms. Many files measured 32.21 ± 1.53 versus
30.88 ± 1.35 ms (30 each). Every observation is retained, including baseline
maxima of 77.06 ms on small predicates and 413.82 ms on large predicates.
The lower means and medians favor the change, but concurrent workstation
activity and baseline outliers limit the inference from these paired samples.

The lifetime audit separately identified pre-existing source-update risks,
tracked in [issue #472](https://github.com/home-lang/home/issues/472): failure
after removing the old source-map entry can leave inconsistent state, and
canonical source replacement does not refresh borrowed redirect slices.
This is a source-level finding awaiting dedicated failure/recovery tests;
the transient snapshot optimization does not claim to fix those semantics.

The full snapshot `20260827T195539Z` records 18/18 lower Home means across
30 interleaved rounds after three warmups. Large predicates measure
323.8 ± 10.2 ms for Home, 351.4 ± 15.2 ms for native TypeScript 7.0.2,
and 1010.4 ± 25.3 ms for JavaScript TypeScript 6.0.3: a 1.09× Home mean lead.
Small predicates measure 41.9 ± 0.8 versus 70.9 ± 2.0 ms, a 1.69× lead.

The independent large-predicate confirmation was declared before inspecting
the full-run results. Snapshot `20260827T200026Z` retains another 30 rounds
after three warmups: Home 327.1 ± 10.4 ms, native TS 7 359.7 ± 14.2 ms,
and TS 6 1026.1 ± 37.1 ms, a 1.10× Home mean lead. Home was faster than
native TS 7 in 29/30 paired large-case rounds of the full run and 30/30 in
the confirmation. The full-run table above is not replaced or averaged with
the confirmation. Both runs retain every observation, including their
outliers and variability.

Commit `d8e32bd9d` adds reproducible workload selection for these confirmations.
Six regressions cover the unchanged full-suite default, requested order,
empty/unknown/duplicate rejection, and failure before creating result files.
All 16 harness/report tests pass. Selection does not alter project inputs,
negative controls, compiler flags, timing, or sample aggregation.

All 1,710 timed samples succeeded. The 540 full-suite and 30 confirmation
rounds, exact versions, balanced ordering, selected-workload metadata,
published tables, frozen predicate hashes, and preserved release binary were
verified. The repeated local lead addresses the frozen scaling case tracked
in [issue #457](https://github.com/home-lang/home/issues/457); it does not prove
performance on other projects or machines. The earlier losses and near tie
remain in this history.

A separate post-run 8,192-family diagnostic profile still shows repeated
checker/driver setup and remaining ambient-interface collection searches.
These counts guide further work and are not timing claims. The broader #416
goal remains open: next coverage is dedicated async/await type propagation
under [issue #473](https://github.com/home-lang/home/issues/473), followed by
validated real-world projects and cross-platform measurements. Semantic
issues #467 and #472 and the unvalidated container path #464 remain open.

<details>
<summary>Previous full snapshot: 20260827T195539Z, commit d33019821</summary>

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 66.7 ± 2.5 ms | 42.0 ± 9.6 ms | **3.6 ± 0.4 ms** | **11.73× faster** |
| `many_files` | 215.4 ± 3.3 ms | 56.7 ± 7.5 ms | **32.4 ± 6.3 ms** | **1.75× faster** |
| `deep_types` | 146.0 ± 8.6 ms | 58.3 ± 3.7 ms | **14.1 ± 0.8 ms** | **4.12× faster** |
| `import_graph` | 139.0 ± 4.4 ms | 49.8 ± 4.1 ms | **29.3 ± 2.0 ms** | **1.70× faster** |
| `reexport_graph` | 111.0 ± 46.4 ms | 47.0 ± 19.2 ms | **31.1 ± 6.1 ms** | **1.51× faster** |
| `tsx_components` | 178.0 ± 25.2 ms | 50.2 ± 1.6 ms | **23.3 ± 4.1 ms** | **2.16× faster** |
| `generic_calls` | 188.4 ± 12.9 ms | 57.3 ± 3.9 ms | **23.2 ± 2.0 ms** | **2.47× faster** |
| `control_flow` | 190.2 ± 4.8 ms | 59.5 ± 2.2 ms | **33.6 ± 5.4 ms** | **1.77× faster** |
| `type_predicates` | 237.8 ± 12.7 ms | 70.9 ± 2.0 ms | **41.9 ± 0.8 ms** | **1.69× faster** |
| `type_predicates_large` | 1010.4 ± 25.3 ms | 351.4 ± 15.2 ms | **323.8 ± 10.2 ms** | **1.09× faster** |
| `null_safe_access` | 191.9 ± 4.1 ms | 57.2 ± 1.1 ms | **38.7 ± 0.5 ms** | **1.48× faster** |
| `destructuring` | 138.4 ± 1.6 ms | 47.3 ± 1.0 ms | **34.4 ± 0.5 ms** | **1.37× faster** |
| `overload_resolution` | 203.1 ± 3.4 ms | 64.6 ± 1.4 ms | **29.1 ± 0.6 ms** | **2.22× faster** |
| `class_hierarchy` | 186.1 ± 7.9 ms | 53.4 ± 7.8 ms | **28.1 ± 0.4 ms** | **1.90× faster** |
| `structural_objects` | 185.8 ± 2.9 ms | 58.1 ± 1.6 ms | **30.3 ± 0.6 ms** | **1.92× faster** |
| `interface_composition` | 214.9 ± 41.7 ms | 64.7 ± 4.3 ms | **45.6 ± 6.0 ms** | **1.42× faster** |
| `variadic_tuples` | 252.9 ± 6.3 ms | 77.7 ± 2.5 ms | 42.4 ± 1.0 ms | Provisional: older admission schema |
| `checkjs_jsdoc` | 211.5 ± 27.6 ms | 54.3 ± 1.2 ms | **36.9 ± 0.9 ms** | **1.47× faster** |

</details>

### Async admission audit and primitive return contracts

Before adding async/await to the measured suite,
[issue #473](https://github.com/home-lang/home/issues/473) checks a candidate
project with identical strict, ES2022, `noLib`, `skipLibCheck`, and `noEmit`
options for all three compilers. Promise, PromiseLike, Awaited, and
PromiseConstructor declarations are extracted unchanged from TypeScript
6.0.3's `lib.es5.d.ts` and `lib.es2015.promise.d.ts`; the shared minimal
global declarations remain unchanged. The candidate exercises generic async
projections, thenable assimilation, optional/discriminated result consumption,
typed async returns, Promise chains, and readonly tuple inputs to Promise.all.
It is **not an accepted benchmark and has no published timing**.

The initial audit found both false rejection of a valid generic async
projection and false acceptance of wrong Promise-chain/tuple result types.
Those remain open in [#476](https://github.com/home-lang/home/issues/476) and
[#475](https://github.com/home-lang/home/issues/475). The workload will not be
weakened or timed while those correctness controls fail.

It also exposed a broader return-checking gap: ordinary primitive return
contracts were checked only in special cases, affecting synchronous functions
as well as async functions. Commit `9e45e105d`, tracked in
[#474](https://github.com/home-lang/home/issues/474), applies the existing
assignability check to canonical primitive returns generally, including
`unknown` sources and strict-null unions. Async bodies check the awaited
value against the awaited declared result. Block callbacks retain their
actual inferred returns so the enclosing call can reject an incompatible
signature instead of replacing its result with the expected type. Obsolete
paired-setter-specific gating was removed.

Five regression groups and independent release-CLI checks use the same source
for Home, TS 6.0.3, and native TS 7.0.2. Each TypeScript baseline produces the
expected diagnostics below; Home's pre-change counts use the preserved
`d33019821` compiler. The non-strict group explicitly disables strict null
checks for every compiler.

| Shared correctness probe | Expected from each TS baseline | Home before | Home after |
|---|---|---:|---:|
| Wrong synchronous primitive returns | 5 × TS2322 | 0 | 5 |
| Wrong direct, promised, awaited, branch, and arrow async returns | 5 × TS2322 | 1 | 5 |
| Unknown and strict nullish return values | 5 × TS2322 | 2 | 5 |
| Non-strict nullish and any return values | No errors | 0 | 0 |
| Valid constrained/narrowed returns plus one invalid block callback | 1 × TS2345 | 0 | 1 |

These are rejection and diagnostic-code checks, not byte-for-byte parity:
[#478](https://github.com/home-lang/home/issues/478) tracks async error text
that still names the syntactic Promise annotation instead of its awaited
target, including an expression-arrow discrepancy present before this fix.
All 4,226 checker tests, 99 program tests, 173 driver tests, and 16 benchmark
harness/report tests pass. All existing 18 positive projects and 13 negative
controls per compiler pass; the small and large predicate hashes remain
unchanged. No compiler options or timed project inputs were weakened.

The post-fix full snapshot `20260827T202656Z` retains 30 interleaved rounds
after three warmups for all 18 existing workloads. Home has a lower mean in
every row. Large predicates measure Home 322.1 ± 13.3 ms, native TS 7
348.8 ± 15.7 ms, and TS 6 1027.8 ± 117.6 ms: a 1.08× mean lead over the
faster competitor. Small predicates measure 46.5 ± 19.5 versus
72.4 ± 10.8 ms, a 1.56× lead. These are measurements with stronger return
validation, not a claim that the correctness fix itself made checking faster.

The separately predeclared confirmation `20260827T203044Z` retains another
30 large-predicate rounds after three warmups: Home 342.5 ± 29.3 ms,
native TS 7 370.2 ± 22.0 ms, and TS 6 1086.3 ± 96.2 ms, again a 1.08×
Home mean lead. Home was faster than native TS 7 in 29/30 paired large-case
rounds in the full suite and 26/30 in the confirmation. The confirmation
is neither substituted for nor averaged into the main table.

Every one of the 1,710 timed samples succeeded. All 540 full-suite rounds
and 30 confirmation rounds were checked for complete results, exact compiler
versions, balanced order, one retained sample per compiler, and successful
exit codes. The release binary and frozen predicate hashes were verified.
Variance remains material: the full-run TS 6 control-flow standard deviation
is 127.9 ms, and Home's small-predicate standard deviation is 19.5 ms.
Both runs, including every outlier, remain in the record. These local synthetic
results do not establish leadership on real projects or other platforms.
Issues #473, #475, #476, and #478 remain open before async coverage can be accepted.

### Generic receiver callback validation (untimed)

Commit [`0612a9071`](https://github.com/home-lang/home/commit/0612a9071fd4231f0fce1f3e15c948ec2a3d503d)
fixes [#479](https://github.com/home-lang/home/issues/479), an underlying
generic-call failure found during the async admission audit. A callback such
as `mapper.project(value => value.label)` now retains the instantiated receiver
parameter and infers its actual return type. Previously, an unresolved method
return parameter prevented contextual parameter typing, and later re-lowering
of the declaration discarded the receiver's substitutions.

The fix operates on instantiated types, carries context into nested arrows and
explicit generic calls, and retains key-dependent indexed accesses until their
keys are inferred. Uniform string dictionaries still reduce to their
key-independent value type. Already-checked callbacks with identical contextual
types are reused; repeated checks do not duplicate an identical return error.

The six [regression sources](https://github.com/home-lang/home/blob/0612a9071fd4231f0fce1f3e15c948ec2a3d503d/packages/ts_checker/src/check.zig#L232408)
were checked with TS 6.0.3, native TS 7.0.2, and Home, each as both a global
script and an export-marked module. Every compiler receives identical
strict/noEmit/noLib/skipLibCheck/ES2022 inputs, the shared minimal library, and
unchanged Promise declarations from TS 6.0.3's `lib.es5.d.ts` and
`lib.es2015.promise.d.ts`. These declarations also prevent missing-global-type
errors during callback compatibility checks; they are not simplified facades.

| Untimed regression family | Expected diagnostics per invalid project | TS 6 / TS 7 / Home |
|---|---|---|
| Inferred receiver callback result | 1 × TS2322 | All match |
| Block, function-expression, and explicit callbacks | 3 × TS2322 | All match |
| Nested callbacks and distinct receiver types | 3 × TS2322 | All match |
| Constraints, defaults, and shadowed type parameters | 4 × TS2322 | All match |
| Incompatible callback arguments and missing properties | TS2322, TS2345, TS2339 | All match |
| Inferred indexed rest payloads | 3 × TS2322 | All match |

Removing only the deliberately invalid statements produces twelve valid
projects per compiler; all are accepted. Each compiler also reports the
expected diagnostic-code multisets for all twelve invalid projects, totaling
72 CLI checks across the three compilers. This verifies acceptance and
diagnostic codes, not byte-for-byte diagnostic parity. The local audit directory
is `bench/vs_tsgo/results/receiver-audit.eg3jPC`.

All 4,232 checker tests, 99 program tests, 173 driver tests, and 16 benchmark
harness/report tests pass. The final ReleaseFast binary also passes validation
of all 18 existing workloads and all 13 existing negative controls per compiler.
Both frozen predicate source hashes are unchanged. The focused checker cases
can be reproduced with:

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='generic interface callbacks'
```

No new timings were collected during the concurrent workstation build/test
activity. The main table and README therefore remain the measured
`9e45e105d` snapshot, not measurements of `0612a9071`. Removing redundant
callback checks is not, by itself, evidence of an end-to-end speedup.

The post-fix async audit still finds that Home accepts the invalid Promise
chain and `Promise.all` result controls rejected by both baselines
([#475](https://github.com/home-lang/home/issues/475)), and rejects the valid
generic async projection accepted by both
([#476](https://github.com/home-lang/home/issues/476)). A separate ordinary
interface/static-method probe confirms that global-script declarations are
erased to `any` while module declarations retain their types; this is tracked in
[#480](https://github.com/home-lang/home/issues/480), without Promise-specific
exceptions. Those issues and the async diagnostic-text issue
[#478](https://github.com/home-lang/home/issues/478) remain open under
[#473](https://github.com/home-lang/home/issues/473). Async remains untimed, and
the accepted workload count remains 18.

### Global declaration and graph admission audit (untimed)

The cross-file audit exposed a flaw in the earlier admission evidence: positive
projects can pass when imported types have been erased to `any`. Two existing
workloads fail direct negative controls, tracked in
[#487](https://github.com/home-lang/home/issues/487):

| Existing workload, invalid statements appended to a temporary copy | TS 6.0.3 / native TS 7.0.2 | Home |
|---|---|---|
| `import_graph`: assign `result.current` to `number`; read `result.missing` | TS2322 and TS2339 | Incorrectly accepts |
| `reexport_graph`: assign `value0.value` to `string`; read `value0.missing` | TS2322 and TS2339 | Incorrectly accepts |

The original projects are unchanged. These controls exercise the imported
generic types, not locally redeclared substitutes. Both controls are now part
of workload validation. The full selection must pass before any timing,
warmup, result directory, or metadata is created. The actual default run was
checked to stop at `import_graph` without creating results. The graph workloads
remain in the default suite; they are not silently removed to produce a pass.

New runs record admission schema 2 after validation. The report generator
retains all old graph measurements but labels pre-schema-2 graph comparisons
ineligible. The main table and README withdraw those two speed claims, and the
same correction applies to historical tables above. Other workloads need
broader rejection coverage; the remaining sixteen rows are not a claim of
sixteen proven-equivalent semantic workloads. The predicate and destructuring
controls remain useful evidence for their specific checks.

No new timing results were collected under the concurrent workstation load.
The old `9e45e105d` times and raw observations are retained unchanged. Fixing
cross-file types and re-running admission are prerequisites to graph retiming,
not evidence of a speedup themselves. The local evidence directory is
`bench/vs_tsgo/results/global-audit.TExK7j`.

The implementation checkpoint consists of
[`98176963c`](https://github.com/home-lang/home/commit/98176963c5ab6422c86e12139cc459f202aa1c05)
(resolve actual/forward declarations before global-name fallback),
[`6cba2f248`](https://github.com/home-lang/home/commit/6cba2f248445646302d1df6a02e07a299c4a2c1a)
(keep narrowed runtime values separate from type lookup), and
[`8a737cdb2`](https://github.com/home-lang/home/commit/8a737cdb208c0bab3ca518880eaf8c486705ba13)
(resolve explicit project files relative to the config directory, fixing
[#483](https://github.com/home-lang/home/issues/483)). The graph gate and
historical-report correction are in
[`16f84e743`](https://github.com/home-lang/home/commit/16f84e74365d42296bee71195dc645f5e0def376).

The [reproducible global audit](https://github.com/home-lang/home/blob/50abd827a75cbd94bdb29acb37f79ca39b88f369/bench/vs_tsgo/audit_globals.py)
uses identical strict/noEmit/noLib/skipLibCheck projects and the shared minimal
library. Same-file cases cover ordinary/generic methods, aliases, forward
declarations, merging, type/value-name coexistence, and module-local isolation.
Cross-file cases cover interfaces, same-named local values, generic static
methods, declared variables, and merging, each with declarations explicitly
listed before and after the app. Positive controls retain the declarations and
remove only the invalid statements. Passes below mean acceptance or the expected
diagnostic-code multiset, not byte-for-byte diagnostic parity.

| Untimed audit | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Same-file declarations: 12 valid + 12 invalid projects | 24/24 | 24/24 | 24/24 |
| Cross-file globals: 10 valid + 10 invalid projects | 20/20 | 20/20 | 6/20 |
| Project/build/positional path controls | 6/6 | 6/6 | 6/6 |
| Existing generic receiver callback controls | 24/24 | 24/24 | 24/24 |

The default global audit performs 132 checks and intentionally exits nonzero:
all fourteen failures are Home cross-file cases. It does not waive or hide
known failures. Both root orders expose the same gaps. The path checks run from
outside the project, include relative, parent-relative, and absolute file
entries, and preserve positional-file behavior with explicit `--ignoreConfig`.
The missing TS5112 diagnostic when that flag is absent is separately tracked in
[#486](https://github.com/home-lang/home/issues/486).

```sh
python3 bench/vs_tsgo/audit_globals.py
python3 bench/vs_tsgo/audit_globals.py --family same-file
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

The final source passes 4,232 checker tests, 101 program tests, 173 driver tests,
69 CLI tests, and 25 harness/report tests. The ReleaseFast binary's SHA-256 is
`7fd2c7e10e2471de753e474fca44abba8f00cfe4bf851284fe1b114653c756ce`.
All eighteen positive workloads still validate. With the stronger gates, Home
passes sixteen workload admissions and fails both graphs; both TypeScript
baselines pass all eighteen. The frozen predicate source hashes are unchanged.

[#480](https://github.com/home-lang/home/issues/480) remains open for real
cross-file declaration/type ownership; a same-file fix does not solve it.
[#487](https://github.com/home-lang/home/issues/487) tracks graph readmission
and broader coverage. Promise result erasure and the valid generic async
projection failure remain reproducible under
[#475](https://github.com/home-lang/home/issues/475) and
[#476](https://github.com/home-lang/home/issues/476), with the diagnostic-text
gap in [#478](https://github.com/home-lang/home/issues/478). Async remains untimed
under [#473](https://github.com/home-lang/home/issues/473).

### Checked-type ownership and assertion returns (untimed)

Commit [`091f15129`](https://github.com/home-lang/home/commit/091f1512954bf216b86556d9f892b6e59134e752)
moves core declaration/signature metadata into the stable `Compilation` result
before destroying its temporary checker. This fixes the retained relation
engine borrowing a destroyed rest-signature table. The transfer moves existing
maps, rather than cloning type graphs, and rebinds the engine as part of the
same operation. Type IDs, string IDs, and declaration nodes still belong to the
source compilation; equal numeric IDs from separate files are not interchangeable.

Post-compilation tests exercise rest-tuple assignability in both directions,
incompatible parameters, generic constraints/defaults and return members,
optional arguments, explicit `this`, predicate metadata, overloads, source
nodes, and independent compilation lifetimes. These tests also exposed
[#489](https://github.com/home-lang/home/issues/489): assertion signatures were
incorrectly lowered as boolean guards. Commit
[`134a9102d`](https://github.com/home-lang/home/commit/134a9102d4e9f022035033bbec058e385405a0d6)
preserves `void` for assertions and `boolean` for ordinary guards in declaration,
function-type, and low-level type lowering. Identical parameter lists remain in
the tests, so the guard/assertion collision is exercised rather than avoided.

| Untimed assertion family, valid and invalid scripts/modules | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Function declarations | 4/4 | 4/4 | 4/4 |
| Function-type aliases | 4/4 | 4/4 | 4/4 |
| Interface methods | 4/4 | 4/4 | 4/4 |

These 36 shared CLI checks use identical strict/noEmit/noLib/skipLibCheck
projects and the minimal library. Invalid inputs must report two TS2322 errors:
using an assertion's result as boolean and assigning its signature to a
boolean-returning function. Removing only those two statements yields valid
controls. Before the fix, Home instead rejected the valid `void` result and
accepted the invalid boolean uses. The low-level tests additionally cover
`asserts value` without an `is` target.

The final functional source passes 4,236 checker tests, 175 driver tests,
101 program tests, 69 CLI tests, and 25 harness/report tests. All 72 earlier
generic-callback checks still pass. The local evidence directory is
`bench/vs_tsgo/results/type-ownership.DvClDP`; the ReleaseFast binary SHA-256 is
`2d1bd9e91307373ffe28b5f0af3f9efb11ea96039df3b2ad77c9540e60fee942`.

This was an ownership prerequisite, not completed cross-file type linkage.
At this checkpoint, [#488](https://github.com/home-lang/home/issues/488) remained
open for interpretation tables such as `NoInfer`, `this` markers,
readonly/pattern index metadata, and tuple/array origins. The following
checkpoint extends that ownership coverage. The global audit still has 14 Home failures out of 132
checks; Home still fails both imported-graph rejection gates. Sixteen workload
gates pass, but neither graph is readmitted and the other rows remain provisional.
No timing run or new speed claim was made under concurrent workstation load.
The published timings and frozen predicate sources are unchanged.

### Semantic metadata ownership and tuple admission (untimed)

Commit [`304fd5d06`](https://github.com/home-lang/home/commit/304fd5d0697ed8b2ee691bc80e4199413b0abb29),
the follow-up to [#488](https://github.com/home-lang/home/issues/488), retains
113 checked-metadata tables with the owning compilation. Structural type
payloads alone do not encode the following information:

| Retained category | Representative post-compilation coverage |
|---|---|
| Inference/context markers | `NoInfer<T>` targets and `ThisType<T>` receivers |
| Index signatures | Readonly flags, parameter/declaration names, template-pattern keys and values |
| Tuple/array interpretation | Origin flags, trailing rest elements, ordered symbolic spreads |
| Generator protocols | Yield, return, and next types |
| Nominal declarations | Class/enum origins, base links, visibility, abstract members, accessor writes, constructor overloads |
| Alias/signature provenance | Generic arguments, display names, predicates, overloads, and source-node IDs |

Allocator-owned maps and nested containers move intact. Six maps contain
borrowed leaf slices (display strings or concrete type arguments); capture
copies those leaves before any ownership changes, without copying type graphs
or retaining the diagnostic arena. Exhaustive allocation-failure injection
checks that a failed capture leaves the checker, empty destination, and relation
engine binding unchanged. Further tests read metadata after checker destruction
and after freeing the caller's source text. All IDs remain relative to the
owning HIR/interner: this does not implement foreign-ID remapping, module
resolution, declaration merging across files, or cycle/file-order handling.
Those remain under [#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487).

Commit [`cbc757dcc`](https://github.com/home-lang/home/commit/cbc757dcc)
([#492](https://github.com/home-lang/home/issues/492)) adds a permanent
rejection gate for the existing variadic-tuple workload. The independent audit
uses seven valid/invalid pairs, retaining the full workload and changing only
one appended statement at a time:

| Untimed tuple control, positive + negative | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Inferred concatenation result | 2/2 | 2/2 | 2/2 |
| Conditional head | 2/2 | 2/2 | 2/2 |
| Conditional tail | 2/2 | 2/2 | 2/2 |
| Captured spread | 2/2 | 2/2 | 2/2 |
| Consumed tuple result | 2/2 | 2/2 | 2/2 |
| Readonly element write | 2/2 | 2/2 | 2/2 |
| Out-of-bounds element | 2/2 | 2/2 | 2/2 |

All 42 controls pass both before and after the ownership change. The permanent
gate appends all seven invalid statements to a temporary copy and requires
exactly five TS2322 errors, one TS2493, and one TS2540, with compiler exit 1 or 2.
The original positive project must pass first. Schema 3 records this gate and
preserves the schema-2 graph gates; validation still precedes result-directory
creation, warmups, and all timing. Legacy tuple observations remain provisional,
not retroactively validated by this newer binary. The timed corpus is unchanged.

The final source passes 4,237 checker tests, 178 driver tests, 101 program tests,
69 CLI tests, and 29 benchmark-harness/report tests. The 36 assertion controls
still pass. All eighteen positive workloads pass; sixteen complete workload
gates pass and both graph gates fail. The global audit remains 44/44 for each
TypeScript baseline and 30/44 for Home (14 failures across 132 total checks).
Neither graph is readmitted. No new timings were collected under concurrent
workstation load.

Local evidence is retained in `bench/vs_tsgo/results/semantic-ownership.JD0NXP`.
The ReleaseFast binary SHA-256 is
`9e4957a5a17dab0ea15a7334ba09ac8044c6f2894101f180718ed190e314e99d`.
The unchanged tuple source SHA-256 is
`78105a6b28024f5ac1dd32cc81d3aa065a3a99a1972927e1880f0a28eec5324f`;
both frozen predicate source hashes also match the preceding checkpoint.

### Canonical type-graph transfer (untimed)

Commit [`e4c0a4caa`](https://github.com/home-lang/home/commit/e4c0a4caaf65c3a2177a66f7af65492e3ca0bbf3)
implements the payload-transfer primitive tracked in
[#494](https://github.com/home-lang/home/issues/494). It returns an owned
source-to-destination TypeId map, resolving structural dependencies iteratively
through the destination's canonical interner. A raw-copy prototype failed an
actual literal-assignability test because equal literals had different IDs;
the implementation now reuses canonical structural keys without changing the
relation engine. Declaration-scoped objects, type parameters, and enum literals
retain distinct identities across owners.

The caller supplies consistent string-content and declaration-owner mappings.
The transfer preserves all stored payload kinds, including shared/recursive
object and parameter edges, generic signature arguments, tuple flags,
conditional distribution, mapped modifiers, and enum identities. It validates
references and rejects unsupported unanchored cycles among immutable structural
keys instead of substituting `any`. Failure removes newly published intern keys
and enum entries before restoring payload-column lengths. Retained allocation
capacity and caller-owned string/provenance allocations are not rolled back.

Seven focused tests cover payloads after source destruction, overlapping IDs
from independent owners, real string/literal/signature relations, reuse of
fourteen existing structural keys, an 8,192-node forward dependency chain,
invalid mappings/references, and exhaustive allocation-failure rollback. The
focused runner passes 8/8 including its module test root.

Fault injection also exposed two initialization leaks, fixed in
[`99a8b7866`](https://github.com/home-lang/home/commit/99a8b7866b67a39c0c3c83b99cacda7ec5f237dc)
([#498](https://github.com/home-lang/home/issues/498)). `Pool.init` now cleans up
partially initialized columns; `Interner.init` releases its pool if initial
header reservation fails. Before-fix probes leaked 144 bytes on the first
failing column append and, with pool cleanup alone, 3,072 bytes in 21 allocations
on header-reservation failure. Both exhaustive initialization tests now pass.
These are ownership fixes, not measured speedups.

The full suites pass 4,246 checker tests, 178 driver tests, 101 program tests,
69 CLI tests, and 29 benchmark-harness/report tests. A fresh ReleaseFast binary
was checked against version-verified TS 6.0.3 and native TS 7.0.2:

| Untimed CLI audit | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Existing positive workloads | 18/18 | 18/18 | 18/18 |
| Variadic tuple controls | 14/14 | 14/14 | 14/14 |
| Assertion-return controls | 12/12 | 12/12 | 12/12 |
| Same-file global declarations | 24/24 | 24/24 | 24/24 |
| Cross-file global declarations | 20/20 | 20/20 | 6/20 |

Home still passes sixteen workload gates and fails both imported-graph gates;
the global audit still reports fourteen failures across 132 checks. The transfer
primitive is **not yet called by program checking**. It does not transfer the
113 checked-metadata tables, construct real HIR/source provenance, resolve
imports or global merges, handle module cycles, or invalidate owner-specific
caches. These are prerequisites to integration under
[#480](https://github.com/home-lang/home/issues/480) and graph readmission under
[#487](https://github.com/home-lang/home/issues/487). Neither graph is readmitted,
and the other timing rows remain provisional.

Local evidence is retained in `bench/vs_tsgo/results/type-transfer.FHPXSf`.
The final ReleaseFast binary SHA-256 is
`860760ccee9bd0935b3371da534756bf148c733bce540d51c86714e96dce962c`.
The tuple and both predicate source hashes match the previous checkpoint.
No timings were collected during concurrent workstation activity; the published
timing snapshot is unchanged. Reproduce the focused checks and permanent
admission audit with:

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='type transfer'
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='initialization'
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
```

The last command intentionally exits nonzero while the fourteen known Home
failures remain; they are not skipped or waived.

### Owner-scoped semantic transfer and imported-owner audit (untimed)

Commit [`778597026`](https://github.com/home-lang/home/commit/7785970261d70ff50b2be710d09d78015a44a3c7)
adds a deep, owner-scoped clone of all 113 retained checked-metadata tables
([#500](https://github.com/home-lang/home/issues/500)). An exhaustive schema
distinguishes type, string, and declaration IDs from parameter positions,
argument counts, flags, and source-relative virtual-section offsets. Adding an
unclassified table or nested record field fails compilation. Slices, display
text, and nested containers are independently owned. Invalid references,
unmapped names/nodes, and many-to-one keys within a table fail explicitly;
the source stays unchanged and no partial result is returned. Callback
allocations and the previously transferred type pool remain caller-owned.

Each result must stay associated with its source owner. Canonical structural
signatures do not uniquely identify declaration-specific predicates or source
locations. Commit
[`84dc71ca5`](https://github.com/home-lang/home/commit/84dc71ca522ed33d0262aa5c3dbba25956eae960)
tests two independently compiled modules with same-named declarations against
one destination type interner. Both guards reuse an existing canonical
`(unknown) => boolean` signature, while their string/number predicates and real
source-owner/node references remain separate. It also checks constrained
generics, private class and enum origins, `NoInfer`, readonly pattern indexes,
symbolic tuple layouts, and positive/negative rest-signature assignability
after destroying the source semantic tables. Source HIR and text stay alive
for provenance lookup; registry handles are not fabricated local HIR nodes.

The focused checker runner passes 4/4 (three tests plus its module root),
including every table populated, exhaustive allocation-failure injection,
source destruction, mixed key fields, sentinel preservation, invalid mappings,
collisions, and successful retry. The full checker suite passes 4,249/4,249,
driver 179/179, program 101/101, CLI 69/69, and benchmark-harness/report 33/33
tests.

Commit [`50ff4add4`](https://github.com/home-lang/home/commit/50ff4add4552ef64e01826f00a59e9bd1c5f78ca)
adds the permanent [imported-owner audit](https://github.com/home-lang/home/blob/50ff4add4552ef64e01826f00a59e9bd1c5f78ca/bench/vs_tsgo/audit_owners.py).
Each family imports same-named declarations from two real modules. Valid and
invalid projects share every declaration and compiler option; only invalid
statements are appended to the negative app. Each pair runs with the app
explicitly listed before and after both declaration files. All three compilers
receive identical strict/noEmit/noLib/skipLibCheck inputs and the same minimal
library. Success requires acceptance of valid inputs or the exact expected
diagnostic-code multiset and failure exit status, not merely any rejection.

| Imported-owner audit: valid + invalid, both root orders | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Constrained generic results and arguments | 4/4 | 4/4 | 2/4 |
| Distinct predicates on same-shaped signatures | 4/4 | 4/4 | 0/4 |
| Private class declaration origins | 4/4 | 4/4 | 2/4 |
| Ordered rest-tuple arguments | 4/4 | 4/4 | 2/4 |
| Readonly and mutable imported members | 4/4 | 4/4 | 2/4 |

Both the preceding `e4c0a4caa` binary and the fresh ReleaseFast audit find twelve
Home failures across sixty checks. Generic, rest, and readonly invalid programs
are incorrectly accepted. Valid predicate narrowing is rejected; invalid
predicate cases have extra/wrong diagnostics because values remain `unknown`.
Private-class assignments are rejected with TS2741 rather than the required
TS2322, so those failures are diagnostic mismatches, not false acceptance.
Both root orders produce the same outcomes. These are untimed correctness
controls, not additional speed rows or evidence that program integration works.

Neither transfer operation is called by program checking yet. The next step
must connect real source-aware declaration lookup and owner-scoped semantic
records to typed resolution, including merging, cycles, and invalidation under
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487). Blindly merging these
records or treating their provenance handles as local HIR nodes would be
incorrect. Publication must also coordinate the separately transactional type
payload transfer and metadata clone; a failed metadata clone does not roll back
the caller's previously transferred type pool. The broader owner audit remains
part of readmission evidence; known failures are not waived. Historical timings
remain unchanged.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='checked transfer'
./pantry/.bin/zig build test -Dfilter=ts_driver
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

## Program-wide name identity and bound global ownership (untimed)

Every prepared `Program` source now retains a reference-counted handle to one
sharded name store. Per-file HIR, binder symbols, declarations, NodeIds, and
TypeIds remain separate: equal StringIds are meaningful across the program,
but foreign local IDs are never interpreted through another source. Serial,
parallel, streaming, bind-only, incremental, and cached-emission paths retain
the store explicitly, and recompilation preserves existing name IDs.

Program-level global discovery now indexes actual root binder maps by name and
value/type/namespace meaning. Each entry retains its source owner and symbol,
including merged declaration NodeIds. Presence-only checker inputs are
projections of that index, replacing raw scans which only recognized the first
plain `var` declarator and mistook comment text for module syntax. The binder
hoists block and loop `var` declarations to the nearest variable environment
while keeping `let` and `const` lexical. CommonJS export discovery also reuses
the prepared syntax owner instead of compiling every source a second time.

The permanent untimed audit uses six visible declaration shapes (plain,
comma-separated, destructured, block-hoisted, comment-adjacent, and escaped)
and five isolation shapes (inline external module, function, namespace,
lexical block, and lexical loop). Every case runs with its declaration root
both before and after the consumer. Visible declarations have positive,
missing-name, and wrong-type controls; isolated declarations have positive and
negative controls. Negative projects only append an invalid use, exact
diagnostic-code multisets are required, and all compilers receive identical
projects and configurations.

| Bound-global ownership audit | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Visible declaration and rejection controls | 36/36 | 36/36 | 4/36 | 24/36 |
| Module and lexical isolation controls | 20/20 | 20/20 | 18/20 | 20/20 |
| Total | 56/56 | 56/56 | 22/56 | 44/56 |

All twelve remaining Home failures are deliberately retained wrong-type
controls: the declaration name is visible, but its foreign TypeId is not yet
linked. This result therefore does not readmit either graph workload or change
any timing claim. Typed global/import resolution remains tracked in
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487); shared identity and bound
ownership are tracked in
[#515](https://github.com/home-lang/home/issues/515).

Implementation commits
[`ac52b6203`](https://github.com/home-lang/home/commit/ac52b6203),
[`0a296c1de`](https://github.com/home-lang/home/commit/0a296c1de), and
[`347693b72`](https://github.com/home-lang/home/commit/347693b72) establish the
shared store, correct variable-environment binding, and add the source-owned
declaration index respectively. The audit itself landed in
[`3f1c34ee9`](https://github.com/home-lang/home/commit/3f1c34ee9).

The interner suite passes 16/16, binder 21/21, driver 187/187, and program
109/109, including allocation-failure cleanup, concurrent retention,
independent lifetimes, every execution mode, incremental recompilation, and
module isolation. The benchmark harness has 38 structural tests. Raw evidence
is retained in `bench/vs_tsgo/results/program-identities.4udJSv`. The
pre-change ReleaseFast binary is `callable-unions.2pCgVc/home-v5`, SHA-256
`462eaf0f83137f05205ac50705c5b4878c0e24f18a7b69fcb1804dc1a03a30dc`.
The final ReleaseFast binary is `program-identities.4udJSv/home-final`,
SHA-256
`0b7289905e110f79611a967097cab671ef1726e5ae06a60cfaf7bb8a26b604ea`.

```sh
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_bound_globals.py
```

Local evidence is retained in `bench/vs_tsgo/results/checked-transfer.IO4A4Q`.
The final ReleaseFast binary SHA-256 is
`4ad8003e751e1471db6f7ea855c3bf8a3822063e89ddb793b85d3714efe93393`.
The fresh release also passes all 42 tuple controls and 36 assertion controls;
the global audit remains 30/44 for Home versus 44/44 for each TypeScript baseline
(fourteen failures across 132 total checks). All eighteen existing positive
workloads pass; Home passes sixteen workload gates and still fails both graph
gates. Neither graph is readmitted, and passing sixteen gates does not establish
sixteen equivalent semantic workloads. The tuple and both predicate source
hashes are unchanged. No timing run was made during concurrent workstation
activity.

### Atomic owner publication and source provenance (untimed)

Commit [`9d8be00d7`](https://github.com/home-lang/home/commit/9d8be00d7b1f61f487f559c863ce7cbc826e0d09)
adds a prepare/commit boundary to payload transfer. A pending transfer is
exclusively owned and cancelled on destruction unless committed. The combined
checked-transfer operation clones the complete semantic record before committing
payloads. Failure therefore restores the destination's original payload-column
lengths, intern keys, and enum entries, including when failure occurs only after
the entire payload graph has been prepared. Previously existing keys remain
valid. Retained allocation capacity is still owned by the destination.

Commit [`202f24b9a`](https://github.com/home-lang/home/commit/202f24b9ae2a56cabdae311533fd603bcb596ce5)
adds the production source-owner registry and replaces the earlier test-only
provenance mapper in the independently compiled owner regression. An owner
borrows immutable HIR, source text, strings, types, and checked metadata. Every
registration denotes a distinct owner/revision even when its path or memory
address is reused. Declaration handles resolve to the actual source owner,
node, span, path, and text. Unregistering the owner before destroying its
storage invalidates old handles; replacement sources cannot inherit those IDs.

Registry import coordinates declaration mappings with the combined
payload/semantic transaction. Failed imports remove newly created declaration
mappings while preserving earlier owners and handles. The caller's string
interner may retain unused strings and allocation capacity, but no failed type
or declaration mapping is published. A checked-owner view is available only
after semantic checking and metadata capture complete: bind-only results are
rejected. Completed checking with diagnostics remains distinct from an
unchecked source; valid empty programs also produce checked-owner views.
Readiness records phase completion, not imported-type parity or benchmark
eligibility.

| Untimed regression | Verified coverage |
|---|---|
| Pending transfer lifecycle | Explicit cancellation, repeated cleanup, commit, prior canonical keys and enum entries |
| Combined publication | Exhaustive allocation failures across payload and semantic preparation; late invalid mappings/collisions; successful retry |
| Source provenance | Real HIR/text lookup, same-path replacement, invalid spans/nodes, and stale-owner rejection |
| Coordinated registry rollback | Existing mappings survive; newly prepared mappings and types disappear together on failure |
| Compiled owners | Distinct predicates on a shared canonical signature, generic constraints, nominal origins, readonly/index metadata, tuples, and rest relations |
| Readiness | Bind-only compilation cannot be published as checked; empty and diagnostic-bearing checked results are distinguished |

The focused transfer runner passes 14/14, including its module test root.
The full checker suite passes 4,252/4,252, driver 183/183, program 101/101,
CLI 69/69, and benchmark harness/report 33/33 tests. The source registry's
failure tests include errors after the object header has already created its
real declaration mapping.

This completes the publication/provenance prerequisite in
[#504](https://github.com/home-lang/home/issues/504), not source-aware program
resolution. The shared transfer pool must use one registry's declaration
handles for **all** declaration-bearing types, including the local owner;
owner-local HIR IDs and another registry's handles must not be mixed into it.
Handles are not local HIR indices. Program lookup still needs owner-aware
interpretation, declaration merging, module-cycle handling, and dependency
invalidation under [#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487). Unregistering a source
invalidates provenance; callers must also stop using its dependent semantic
records. The registry does not yet implement that program-wide invalidation.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='transfer:'
./pantry/.bin/zig build test -Dfilter=ts_driver
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

Local evidence is retained in `bench/vs_tsgo/results/owner-publication.xWNTr8`.
The final ReleaseFast binary SHA-256 is
`6d6b278c9df4db5a67171436def69c720fbe4d91e3171e8221c6d9cb161f4134`.
Fresh CLI audits against version-verified TS 6.0.3 and native TS 7.0.2 retain
the preceding checkpoint's results: all 42 tuple and 36 assertion controls
pass; the global audit has fourteen Home failures (30/44 versus 44/44 for each
baseline), and the imported-owner audit has twelve (8/20 versus 20/20).
All eighteen positive workloads pass; Home passes sixteen workload gates and
fails both graph rejection gates. Passing those sixteen gates is not proof of
sixteen semantically equivalent workloads.
The tuple and both frozen predicate source hashes are unchanged.
No timing claim follows from these ownership tests; historical timings remain
unchanged, and neither graph is readmitted.

### Prepared program discovery and expanded global audit (untimed)

Commit [`4693c6277`](https://github.com/home-lang/home/commit/4693c6277)
separates source preparation (parse/bind) from one-shot checking and emit.
Preparation retains the original HIR, tokens, binder symbols, declaration-file
flag, syntactic-error flag, and JSX comma-recovery spans. The parser can be
destroyed before checking begins. Checked-owner publication still occurs only
after semantic checking and metadata capture; preparation alone is not a typed
source owner. Failed checking is deinitializable and must not be retried on the
partially checked object.

Commit [`83d145926`](https://github.com/home-lang/home/commit/83d145926)
uses that boundary in the program pipeline. Import/reference discovery performs
parse/bind only and skips semantic fact collection during discovery rounds.
After the graph stops expanding, checking reuses its bound sources against the
final program facts. Conformance no longer reparses/rebinds/checks the complete
graph a second time. Serial, parallel, and streaming paths share the per-file
lifecycle. Streaming reference checks also receive the final known-path list.
If a caller explicitly checked an incomplete graph before expanding it, those
semantic results are invalidated and rebuilt; unchanged repeated discovery
retains the checked owners. This is not dependency-aware incremental checking.

The driver suite passes 186/186, program 105/105, and CLI 69/69. Regressions
cover retained binder/token identity, emit/check idempotence, declaration-file
and parser-recovery state, multi-hop discovery, serial/parallel/streaming
results, zero-worker fallback, expansion invalidation, and allocation-failure
cleanup/retry. The conformance suite passes 1,417/1,417. The unchanged checker
test target was a cache hit; no fresh checker execution is claimed here.

A separate CLI probe lists only the minimal library and `app.ts` as roots:

```ts
// app.ts
/// <reference path="./bridge.d.ts" />
globalThis.lateValue;
// bridge.d.ts
/// <reference path="./definitions.d.ts" />
// definitions.d.ts
declare var lateValue: number;
```

These are three separate source files, not concatenated input. Every compiler
uses the same strict/noEmit/noLib project and minimal library. Two invalid
variants append statements to the unchanged app: one adds `missingValue; const
bad: string = 1;`, and the other adds `const wrong: string =
globalThis.lateValue;`. Diagnostic multisets and exit status must match.

| Untimed transitive-reference probe | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---|---|---|---|
| Valid project | Pass | Pass | False TS6053 × 2 and TS7017 | Pass |
| Invalid local code | TS2304 + TS2322 | TS2304 + TS2322 | Expected errors plus false reference/global errors | TS2304 + TS2322 |
| Invalid global property assignment | TS2322 | TS2322 | Incorrect reference/global diagnostics | Incorrectly accepted |

This proves the scheduling correction, **not** typed-global parity. The earlier
binary is the preceding checkpoint's `home-final` (SHA-256 `6d6b278c9df4db5a67171436def69c720fbe4d91e3171e8221c6d9cb161f4134`).
The before/after probe has twelve checks including that older Home binary:
four fail, three in the older Home and one in the new Home.

Commits [`bebe678de`](https://github.com/home-lang/home/commit/bebe678de) and
[`445422c60`](https://github.com/home-lang/home/commit/445422c60) extend the
permanent global audit with sibling ambient `let` and `const` bindings and
typed `globalThis` reads, each positive/negative and with both
declaration-before/after-app orders. The lexical cases report false TS2304;
the invalid `globalThis` assignments are accepted. Neither failure is waived.
The original 44 controls retain their prior results; the larger denominator
reflects twelve added controls, not a timing or correctness regression.

| Fresh untimed audit | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Expanded globals | 56/56 | 56/56 | 32/56 |
| Imported owners | 20/20 | 20/20 | 8/20 |
| Tuple controls | 14/14 | 14/14 | 14/14 |
| Assertion controls | 12/12 | 12/12 | 12/12 |

All eighteen positive benchmark workloads pass. Home still fails both graph
rejection gates and passes the other sixteen gates; that is not evidence of
sixteen semantically equivalent workloads. Both graph timing claims remain
ineligible. The tuple and both predicate corpus hashes are unchanged, and no
timings were collected during concurrent workstation activity.

```sh
./pantry/.bin/zig build test -Dfilter=ts_driver
./pantry/.bin/zig build test -Dfilter=ts_program
./pantry/.bin/zig build test -Dfilter=ts_conformance
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

The harness suite passes 33/33. Local evidence, including the independent
discovery probe and raw diagnostics, is retained in
`bench/vs_tsgo/results/prepared-program.Wx2zap`. The fresh ReleaseFast binary
SHA-256 is `a3eddac96fe1b07d7876defc63a2cda06b9f13210b333e8dc57e2b38e8a0ea12`.
This addresses the scheduling/reuse work in
[#505](https://github.com/home-lang/home/issues/505). Actual owner-aware global
and import type resolution, declaration merging, and module-cycle semantics
remain open in [#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487), under the performance
tracker [#416](https://github.com/home-lang/home/issues/416).

### Callable identity and scoped inference (untimed)

The audit added in [`d4e63ff6c`](https://github.com/home-lang/home/commit/d4e63ff6c)
exposes a declaration-identity bug tracked in
[#507](https://github.com/home-lang/home/issues/507): signatures with equal
parameter and return types shared a TypeId even though their predicates,
optional/rest parameters, generic binders, and declaration metadata differed.
For example, the predicate and ordinary boolean methods below must not share
narrowing behavior:

```ts
interface Guards {
  number(value: unknown): value is number;
  plain(value: unknown): boolean;
}
declare const guards: Guards;
declare let value: unknown;
const plain = guards.plain;
if (plain(value)) { const bad: number = value; } // TS2322
```

The earlier Home binary accepts that invalid assignment; both pinned TS
compilers reject it. The permanent audit has seven families: predicate aliases,
direct calls, wrapper objects, predicate assignments, rest parameters, optional
parameters, and generic arity. Every family includes valid/invalid pairs in
both declaration orders and script/module scopes: 56 cases per compiler.
Only invalid statements are appended to each positive project. All compilers
receive identical files, flags, and the minimal library; exit status and exact
diagnostic-code multisets must agree. No failures are skipped and no timings
are taken by this audit.

Commit [`15f050f23`](https://github.com/home-lang/home/commit/15f050f23)
changes callable creation to allocate distinct identities without an erased-shape
hash entry. Structural relations still decide compatibility. Creation reserves
all pool columns before publishing lengths, and retains offsets when its input
parameters borrow the same pool. Type transfer preserves distinct imported
callables while still deduplicating immutable keys.

Related checker corrections explicitly preserve predicates/generic metadata
during inference, prevent local generic callback binders from becoming outer
inference candidates, retain identity for unaffected substitutions, and use
structural subtype reduction for conditional objects with callable members.
Argument context snapshots remain valid while checking earlier arguments grows
the signature pool. These replace dependencies on accidental TypeId sharing;
they do not add name-specific or benchmark-specific exceptions.

| Callable family | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Predicate alias | 8/8 | 8/8 | 4/8 | 8/8 |
| Predicate direct call | 8/8 | 8/8 | 4/8 | 8/8 |
| Predicate wrapper | 8/8 | 8/8 | 4/8 | 8/8 |
| Predicate assignment | 8/8 | 8/8 | 4/8 | 8/8 |
| Rest parameters | 8/8 | 8/8 | 4/8 | 8/8 |
| Optional parameters | 8/8 | 8/8 | 2/8 | 8/8 |
| Generic arity | 8/8 | 8/8 | 4/8 | 8/8 |
| Total | 56/56 | 56/56 | 26/56 | 56/56 |

The fresh release also passes all 14 tuple controls and 12 assertion controls.
The global and imported-owner audits remain at 32/56 and 8/20 respectively;
their individual pass/fail results and diagnostic-code multisets are unchanged.
All eighteen positive benchmark workloads pass, but Home still accepts the
invalid imported-property controls for both module graphs. Both graph timing
claims remain ineligible. Passing the other sixteen admission gates does not
establish semantic equivalence for all their language features.

The checker suite passes 4,257/4,257, conformance 1,417/1,417, driver 186/186,
program 105/105, CLI 69/69, and harness tests 35/35. Tests cover distinct callable identities, pool growth,
allocation-failure publication, transfer relations and metadata, unaffected
substitution, hidden predicate targets, and scoped callback binders. The two
existing overload-context fixtures also match both pinned compilers' complete
diagnostic-code multisets in a separate CLI probe (six checks, no failures).
The transitive-reference probe remains at 2/3 for Home and 3/3 for each TS
baseline. Repository-wide Pickier aborted at its 100,000-file safety limit
(177,405 files discovered); targeted lint of the changed files passes with
one pre-existing README link-fragment warning.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker
./pantry/.bin/zig build test -Dfilter=ts_driver
./pantry/.bin/zig build test -Dfilter=ts_program
./pantry/.bin/zig build test -Dfilter=ts_conformance
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_callables.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

Local raw evidence is retained in
`bench/vs_tsgo/results/signature-identity.6jiDkG`. The before binary SHA-256 is
`a3eddac96fe1b07d7876defc63a2cda06b9f13210b333e8dc57e2b38e8a0ea12`;
the fresh ReleaseFast binary is
`d7ecf960b76ef1f61b3e9acf4ebb97cad70fc3d087db20c5a5cdce03d82e6ffc`.
Both installed baseline versions were verified exactly before the audits.
Predicate and tuple corpus hashes are unchanged. No new timings were collected,
so this checkpoint makes no speedup or universal-leadership claim. Actual
cross-file type resolution remains open in
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487).

### Callable union predicates and receivers (untimed)

The follow-up audit in
[`79d9ce2ca`](https://github.com/home-lang/home/commit/79d9ce2ca), tracked in
[#511](https://github.com/home-lang/home/issues/511), tests the semantic work
required when choosing between callable values. Distinct callable identities
alone do not prevent an erased-shape subtype check from discarding a branch:

```ts
declare function guard(value: unknown): value is number;
declare function plain(value: unknown): boolean;
declare let value: unknown;
const selected = [guard, plain];
if (selected[0](value)) { const bad: number = value; } // TS2322
```

The previous Home binary accepts this invalid narrowing. Conversely, unions
of genuine guards lose their shared narrowing information in several paths,
rejecting valid uses. A callable union also requires a receiver satisfying
every possible branch, rather than any one branch as for an overload set.

The permanent audit contains four families, each tested with declaration and
branch order varied independently, arrays and conditional expressions, bare
callables and object wrappers, script/module scope, and valid/invalid pairs.
That is 64 cases per family and 256 per compiler. Negative projects only append
an invalid use to the corresponding positive project. Files, compiler flags,
and minimal library are identical for all three compilers. Exact installed
versions, exit statuses, and diagnostic-code multisets are checked; no failures
are waived. These are untimed controls, not new timed workloads.

| Callable union family | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Predicate plus ordinary boolean | 64/64 | 64/64 | 60/64 | 64/64 |
| Different predicate targets | 64/64 | 64/64 | 12/64 | 64/64 |
| Same predicate target | 64/64 | 64/64 | 16/64 | 64/64 |
| Explicit receiver requirements | 64/64 | 64/64 | 32/64 | 64/64 |
| Total | 256/256 | 256/256 | 120/256 | 256/256 |

Commit [`7d16f7ab8`](https://github.com/home-lang/home/commit/7d16f7ab8)
consults predicate and receiver metadata before reducing
callable unions. Resolved signatures combine predicate targets only when
every branch promises a compatible predicate kind and argument position.
Combined targets have no fabricated source annotation. Receiver checking uses
the union's combined signatures, which intersect receiver requirements; the
zero-argument and two-branch restrictions are removed. A previous receiver
substitution based on accidentally shared signature identity is also removed.
Arity is captured before interning can invalidate borrowed parameter storage,
and union-member traversal retains its own stable IDs. Matching retains the
selected common parameter contract instead of substituting a longer branch's
parameters, preserving required/minimum and maximum argument counts. Result
overloads are deduplicated by their complete parameter/receiver contracts,
not by the partial compatibility used to find cross-branch candidates.

The two baseline versions agree on every audit case. A separate diagnostic
probe found that a direct, non-union receiver missing one required property
produces TS2684 in TS 6 and TS2741 in native TS 7. The existing native-style
elaboration is retained; this disagreement is not hidden by relaxing the audit.

The final release also passes all 56 callable-identity controls, 14 tuple
controls and 12 assertion controls. Four additional checker-fixture comparisons
cover five-way union arity, valid optional/rest calls, conditional minimum
arity, and three-way predicate/receiver composition: all twelve compiler/fixture
checks match the pinned baselines. All eighteen positive workloads pass and
sixteen rejection gates pass. The two graph gates still fail; global controls
remain 32/56, imported-owner controls 8/20, and transitive-reference checks 2/3
for Home. Those gaps are not waived by the new callable results.

The full checker suite passes 4,261/4,261, including the original arity
regressions unchanged and the new predicate/receiver tests. Conformance passes
1,417/1,417. Driver passes
186/186, program 105/105, CLI 69/69, and harness 37/37. Repository-wide Pickier
aborts at its 100,000-file safety limit (177,457 files discovered); targeted
lint has no errors and one pre-existing README fragment warning.

Raw evidence is retained in `bench/vs_tsgo/results/callable-unions.2pCgVc`;
final compiler verification logs use the `-v5.log` suffix. The frozen pre-change binary
is `signature-identity.6jiDkG/home-final`, SHA-256
`d7ecf960b76ef1f61b3e9acf4ebb97cad70fc3d087db20c5a5cdce03d82e6ffc`.
The final ReleaseFast binary is `callable-unions.2pCgVc/home-v5`, SHA-256
`462eaf0f83137f05205ac50705c5b4878c0e24f18a7b69fcb1804dc1a03a30dc`.
Earlier candidate runs, including failed regression runs, are retained too.
Predicate and tuple workload hashes are unchanged. No new timings were
collected and both graph speed claims remain ineligible. Actual typed global
and imported declaration linkage remains open in
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487).

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker
./pantry/.bin/zig build test -Dfilter=ts_conformance
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_callable_unions.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_callables.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

### Checked-owner lifetime and typed-global consumer contract (untimed)

The next checkpoint for [#480](https://github.com/home-lang/home/issues/480)
and [#487](https://github.com/home-lang/home/issues/487) establishes source
lifetime and checker lookup boundaries. Commit
[`33d8c15c5`](https://github.com/home-lang/home/commit/33d8c15c5) registers each
checked program-file revision with its source-owner registry and tombstones
that identity before replacement or destruction. Parallel publication is
serialized; incremental recompilation retains unaffected owners and assigns
fresh identities to replacements. Commit
[`76d6a8b2d`](https://github.com/home-lang/home/commit/76d6a8b2d) leaves scanner
recovery results without checked type storage unregistered, instead of
asserting that every diagnostic-bearing result has a typed source view.

Commit [`a142705f1`](https://github.com/home-lang/home/commit/a142705f1)
lets the checker accept explicit value/type bindings already relocated into
its receiving type pool and string keyspace. Local and forward declarations
take precedence. A separate property flag distinguishes global `var`-style
bindings from lexical bindings for dotted, bracketed, and indexed-`typeof`
access through `globalThis`; local bindings named `globalThis` still shadow
the global object. Focused tests cover primitive and structural object types,
call signatures, wrong assignments, missing members, invalid arguments,
non-generic type arguments, and lexical isolation.

This is a consumer contract, **not automatic cross-file type transfer**.
Program compilation still supplies presence-only names. Publishing real
bindings requires owner-aware declaration and semantic metadata, including
generic parameters, predicates, nominal identity, declaration merging, and
resolution independent of source order and cycles. The contract does not
authorize foreign local node IDs or incomplete metadata to be treated as local.

The unchanged audits were rerun against the frozen ReleaseFast binary and
exact installed baselines. Each compiler receives the same files and options;
valid cases must succeed silently, and invalid cases must match the expected
diagnostic-code multiset. Failures remain visible:

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Global declaration controls | 56/56 | 56/56 | 32/56 |
| Bound-global discovery controls | 56/56 | 56/56 | 44/56 |
| Imported-owner controls | 20/20 | 20/20 | 8/20 |
| Import/re-export graph admission | 2/2 | 2/2 | 0/2 |

These results are unchanged from the prior checkpoint. Both graph projects
still accept invalid imported-property uses in Home, so neither is readmitted
for timing. The full admission check passes 16/18 workloads, with only those
two failures. No new timings were collected and no speedup is claimed.

The full checker suite passes 4,264/4,264, conformance 1,417/1,417,
program 110/110, driver 187/187, and harness 38/38. Zig formatting checks pass.
Targeted Pickier has no errors
and one pre-existing README fragment warning.

Raw logs and the frozen binary are retained locally in
`bench/vs_tsgo/results/global-consumer.xZ8NXj`. The final binary SHA-256 is
`f401735aa016d571c2aa4def48f47f4ff435a100af98c3d37c5d61afab392f09`.
The installed compilers report `Version 6.0.3` and `Version 7.0.2`; the old
`7.0.0-dev.20260707.2` version is explicitly rejected by harness tests.
Native TS 7 is one baseline, not separate `tsc 7` and `tsgo` competitors.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker
./pantry/.bin/zig build test -Dfilter=ts_program
./pantry/.bin/zig build test -Dfilter=ts_driver
./pantry/.bin/zig build test -Dfilter=ts_conformance
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_bound_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

### Re-export discovery and declaration origins (untimed)

Issue [#520](https://github.com/home-lang/home/issues/520) isolates two
prerequisites for the typed graph work in
[#487](https://github.com/home-lang/home/issues/487): loading the complete
static dependency graph and recognizing the actual declaration behind an
export. These controls are not additional timed workloads.

The discovery audit has 28 cases: imports, named/star/namespace/type-only
re-exports, cycles, and diamonds, each tested with entry-only and all-files
roots. A negative case only appends a wrong local assignment in the leaf.
This detects an omitted source file without depending on imported type
inference. Pre-change Home passes 13/28; both pinned TypeScript baselines
pass 28/28. Commit
[`d440dbee6`](https://github.com/home-lang/home/commit/d440dbee6) loads static
re-export targets and rebuilds unique, current dependency edges. Program
tests also check repeated resolution, source replacement, and include
provenance.

The origin audit has 32 paired cases. It accepts two paths to the same
declaration while retaining genuine TS2308 conflicts and TS2305 missing-name
errors. It also checks default-import aliases, type-only function identity,
and runtime rejection through direct, named-barrel, and star-barrel aliases.
Local parameters that shadow an import remain usable. Both baselines pass
32/32; pre-change Home passes 4/32. Every compiler receives identical source
files, roots, and strict/noEmit/noLib/skipLibCheck options. Positive cases
must succeed silently; negative cases must match the diagnostic-code
multiset, not merely exit unsuccessfully.

The final ReleaseFast binary passes both new audits:

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Re-export discovery controls | 28/28 | 28/28 | 13/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 4/32 | 32/32 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The unchanged global, bound-global, and imported-owner audits remain
32/56, 44/56, and 8/20 for Home; both TypeScript baselines pass every case.
Full workload admission remains 16/18 for Home and 18/18 for each baseline,
with only the two original imported graph failures. No new timing run was
started, and no workload or negative control was removed to improve the result.

Commit [`2e1f795f9`](https://github.com/home-lang/home/commit/2e1f795f9)
implements the origin resolver and its checker/CLI integration. It uses a
visited worklist over source paths, names, lookup
mode, and value visibility. It follows aliases and cycles in the declaration's
own bound source, with a 96-module-chain regression test. Same-origin equality
requires actual overlapping declaration meanings; missing, incomplete, or
ambiguous resolutions cannot prove equality. The CLI retains immutable bound
source views across origin queries. Type-only paths retain symbol identity
for `typeof`, while recording whether the runtime restriction originated at
`import type` (TS1361) or `export type` (TS1362). Restriction positions retain
their source path, rather than becoming fabricated local node IDs.

This is **not automatic cross-file checked-type transfer**. The existing
legacy export-fact/name enumeration paths still have separate recursion
limits; the worklist test does not establish unlimited resolution throughout
the CLI. Generic parameters, predicates, nominal identity, and declaration
merging still require source-owned semantic linkage. The original graph
negative controls remain mandatory before either graph timing is eligible.

Raw evidence is retained in
`bench/vs_tsgo/results/reexport-discovery.rFhIvz`, including pre-change,
intermediate, failed, and superseded runs. `audit-before.log` is the discovery
baseline; `origins-before-final.log` is the final 32-case origin baseline.
The frozen pre-change binary is `global-consumer.xZ8NXj/home-final`, SHA-256
`f401735aa016d571c2aa4def48f47f4ff435a100af98c3d37c5d61afab392f09`.
The final binary is `reexport-discovery.rFhIvz/home-final`, SHA-256
`bff8e072e39c79f0d44e360b0b36ed5b984fd71183debb8e8736efa1aa6e6e3c`.
Its successful build log is `release-v4.log`; final audit logs use the
`-final.log` suffix. The original imported graph negatives are still accepted
without diagnostics by Home, so neither graph is readmitted for timing.
Runs marked TERM were stopped after source revisions and are not counted as
successful final verification. No new timings are reported here.

The final checker suite passes 4,266/4,266, conformance 1,417/1,417,
Program 117/117, driver 187/187, CLI 69/69, and the benchmark harness 41/41.
Zig formatting checks pass. Targeted Pickier reports no errors
and one pre-existing README fragment warning.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_graph_discovery.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_export_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported nominal identity without synthetic properties (untimed)

Tracked in [#521](https://github.com/home-lang/home/issues/521), under
[#487](https://github.com/home-lang/home/issues/487) and
[#416](https://github.com/home-lang/home/issues/416). The installed baseline
binaries were verified again as `Version 6.0.3` and `Version 7.0.2`.
The harness rejects the superseded native dev build; native TS 7 and `tsgo`
are one competitor, not two separate compiler results.

Audit commits [`ab691caf7`](https://github.com/home-lang/home/commit/ab691caf7)
and [`e40a4d546`](https://github.com/home-lang/home/commit/e40a4d546) retain the
failing controls and enforce fairness. The implementation is
[`4ae69562e`](https://github.com/home-lang/home/commit/4ae69562e).

Home previously added a required `__home_class_origin_...` property to imported
classes with non-public members. That implementation detail leaked into missing
property diagnostics (TS2741). The checker now attaches source-qualified origin
metadata to the real non-public members, without creating a property. Recursive
identity and assignability checks compare that metadata, including nested
objects, arrays, signatures, and intersections. Generic substitution preserves
it, and type transfer relocates its string ID independently of HIR node IDs.
The legacy source-path/module/class key is length-prefixed to prevent delimiter
collisions. This does not replace the legacy class projection with complete
source-owned checked declarations.

The new audit has 52 controls: 13 families, each with positive and appended-only
negative variants, checked with the app before and after declaration roots.
All compilers receive identical files, roots, and strict/noEmit/noLib/skipLibCheck
options. Successful controls must be silent; rejection controls must match the
exact diagnostic-code multiset. No failure is skipped or relabeled as a pass.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Imported nominal-identity controls | 52/52 | 52/52 | 30/52 | 36/52 |
| Existing imported-owner controls | 20/20 | 20/20 | 8/20 | 10/20 |
| Re-export discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global declaration controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Bound-global controls | 56/56 | 56/56 | 44/56 | 44/56 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The six newly passing nominal controls cover direct private/protected identity
and a public structural object assigned to a private class. The existing nested
object, array, function, and public-structural controls remain passing. Remaining
failures cover static-private imports (2 controls), generic arguments (2),
re-exported class aliases (2), private `keyof` (2), and private/protected inheritance
(8). Static member metadata is preserved when supplied, but Program's class
projection still omits the static-private declarations exercised here. Positive
inheritance failures are counted, not hidden by the corresponding negative case.

Full workload admission remains 16/18 for Home and 18/18 for each baseline.
Both original imported graphs still accept invalid uses and remain ineligible
for timing. No new performance measurement or speed claim is made. The new
member metadata has not yet been evaluated in a fresh timing/memory comparison.

The frozen pre-change binary is `reexport-discovery.rFhIvz/home-final`, SHA-256
`bff8e072e39c79f0d44e360b0b36ed5b984fd71183debb8e8736efa1aa6e6e3c`.
Evidence for this checkpoint is in `bench/vs_tsgo/results/nominal-origins.doZaNi`:
`audit-before-expanded.log` and `audit-final.log` use all 52 controls;
`audit-before.log` retains the initial 48-case run before static-private controls
were added. The final binary is `home-final`, SHA-256
`3cc741571c00fa3682fb3b4c4931273b0f57a910f12a61c022112ed780f7a245`;
its build log is `release.log`. Audit source SHA-256:
`98dcd584f5dc651d19c80fe28cd538e34b0bb3de176af87be067e64dbd400ea1`.

The checker suite passes 4,270/4,270, conformance 1,417/1,417, driver 187/187,
Program 117/117, CLI 69/69, focused origin tests 5/5 (including the test root),
and the benchmark harness 44/44. Fresh callable-identity and callable-union
audits remain 56/56 and 256/256 for all three compilers. Zig formatting checks
pass; targeted Pickier reports zero errors and the pre-existing README
fragment warning.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_nominal_origins.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Bound class declarations and export aliases (untimed)

Tracked in [#522](https://github.com/home-lang/home/issues/522), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416). All runs below verify the
installed compilers as TS **6.0.3** and native TS **7.0.2**. The old native
`7.0.0-dev.20260707.2` build is rejected, not treated as another competitor.

Audit commits [`79f43d107`](https://github.com/home-lang/home/commit/79f43d107)
and [`cce32867b`](https://github.com/home-lang/home/commit/cce32867b) define 52
controls across 13 families. Each has a valid program and an appended-only
negative variant, with identical inputs/options for all compilers and both app
root orders. Valid controls must be silent; invalid controls must match the
exact diagnostic-code multiset. Type-only aliases must preserve class identity
without permitting runtime construction.

Implementation commits
[`226da3863`](https://github.com/home-lang/home/commit/226da3863) and
[`b45b038e0`](https://github.com/home-lang/home/commit/b45b038e0) replace the
source-text class scanner with already-bound declaration traversal. Export
binding names/paths are separate from declaration names/paths/positions. Alias
queries and a visited star-export candidate worklist retain the actual owner
through renaming, defaults, cycles, and explicit shadows. Class fields use HIR
static/visibility flags; comments are not members and quoted keyword names are
ordinary public properties. Namespace declaration context is retained in HIR,
and `keyof` excludes non-public class members.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Bound-class export controls | 52/52 | 52/52 | 22/52 | 48/52 |
| Imported nominal-identity controls | 52/52 | 52/52 | 36/52 | 40/52 |
| Existing imported-owner controls | 20/20 | 20/20 | 10/20 | 10/20 |
| Re-export discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global declaration controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The four remaining class-export failures are negative static-member and
merged-namespace visibility uses, each in both root orders. The collected facts
are retained, but the consumer still falls back to `any` for these imported
values. The nominal audit still fails private-static identity (2 controls),
generic arguments (2), and private/protected inheritance (8). Alias identity
and private `keyof` now pass. Full workload admission remains 16/18 for Home
and 18/18 for each baseline; the two original graphs remain ineligible for timing.

This is not complete cross-file checked-type transfer. Complex member types,
method/constructor signatures, generic constraints, heritage, ambient class
export aliases, and computed names still need source-owned semantic linkage.
The existing relative module namespace-augmentation text collector remains a
separate legacy boundary. No new timings or speed/memory claims are made.

Raw evidence is in `bench/vs_tsgo/results/bound-classes.8s4Xq1`.
`bindings-before-type-only.log` and `bindings-v1.log` contain the final 52-case
before/after audit; earlier 40/44-case runs are retained but are not mixed into
the table. The frozen baseline is `nominal-origins.doZaNi/home-final`, SHA-256
`3cc741571c00fa3682fb3b4c4931273b0f57a910f12a61c022112ed780f7a245`.
The final ReleaseFast binary is `bound-classes.8s4Xq1/home-v1`, SHA-256
`7f71d18f3a1648032b346183267382573f02475b824f5db8c30e0cc463568bd2`;
its successful build log is `release-final.log`. Other audit logs use `-v1.log`.
Audit source SHA-256:
`97f9bdc75c50957c33e4139f05b66eb21750fad2fa51741a990b6525449ea6ea`.
Debug, failed, interrupted, and superseded runs remain separately labeled and
are not counted as final release verification.

The checker suite passes 4,271/4,271, conformance 1,417/1,417, Program 119/119,
driver 187/187, CLI 69/69, parser 897/897, HIR 12/12, and benchmark harness
47/47. Fresh bound-global controls remain 44/56 for Home and 56/56 for each
baseline. Callable-identity and callable-union controls remain 56/56 and 256/256
for all three compilers. Zig formatting checks pass.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_class_bindings.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_nominal_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported static values and module namespace consumers (untimed)

Tracked in [#523](https://github.com/home-lang/home/issues/523), following
[#522](https://github.com/home-lang/home/issues/522), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416). The harness verifies
TS **6.0.3** and native TS **7.0.2** before every run. Native TS 7 and `tsgo`
remain one competitor; the superseded dev build is rejected.

The main implementation is
[`cdcb60b41`](https://github.com/home-lang/home/commit/cdcb60b41).

Audit commits [`232961504`](https://github.com/home-lang/home/commit/232961504),
[`170613d01`](https://github.com/home-lang/home/commit/170613d01), and
[`89698128c`](https://github.com/home-lang/home/commit/89698128c) define the final
84 controls: 21 families, each with positive and appended-only negative variants
in both app root orders. All compilers receive identical files, roots, and
strict/noEmit/noLib/skipLibCheck options. Positive controls must be silent;
negative controls must match the exact diagnostic-code multiset.

The audit covers named/default imports, aliases, module namespaces, captured
namespaces and constructors, destructuring, element access, mixed exports,
lexical shadowing, unqualified-name isolation, static-private identity,
merged-namespace visibility, type-only restrictions, constructor prototypes,
cyclic namespace aliases, and a 41-link star-export chain. Neither cycles nor
long chains are omitted when they expose a failure.

Named imports now use known class/value facts before presence-only `any`
fallbacks. Module namespace values contain the complete known runtime export
inventory, including non-class exports and default exports. Bound export queries
separate value availability from type-only bindings and identify namespace alias
owners. Namespace class members do not register bare class names in the importing
scope. Constructor values retain their instance type through `prototype`.

Namespace identities are reserved and completed before publication, preserving
cycles through ordinary object consumption. A cycle exposed a non-terminating
free-type-parameter walk; it now uses a visited worklist with reusable scratch
storage. Export-name enumeration also uses a visited worklist rather than a
fixed depth limit ([`bca0fad95`](https://github.com/home-lang/home/commit/bca0fad95)).
Recursive object completion is separately tested
([`c2331bab6`](https://github.com/home-lang/home/commit/c2331bab6)).

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Imported static-value controls | 84/84 | 84/84 | 52/84 | 84/84 |
| Bound-class export controls | 52/52 | 52/52 | 48/52 | 52/52 |
| Imported nominal-identity controls | 52/52 | 52/52 | 40/52 | 42/52 |
| Existing imported-owner controls | 20/20 | 20/20 | 10/20 | 10/20 |
| Re-export discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global declaration controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Bound-global controls | 56/56 | 56/56 | 44/56 | 44/56 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The nominal audit still fails generic arguments (2 controls) and
private/protected inheritance (8); both positive and negative inheritance
failures are retained. Full workload admission remains **16/18 for Home** and
**18/18 for each baseline**. Both original graph negative controls are still
accepted without diagnostics by Home, so neither graph is eligible for timing.
No new speed or memory claim is made.

This remains a projection of supported source-owned facts, not automatic
cross-file checked-type transfer. Complex members, method/constructor signatures,
generic constraints and heritage still need semantic linkage. Unsupported
exported value types retain their existing limits; a known export inventory is
not proof that every member has a complete checked type. Unavailable namespace
shapes, including JavaScript files outside the bound query's coverage, are kept
unknown and cached as such, not published as incomplete empty objects.

Evidence is retained in `bench/vs_tsgo/results/static-values.csYPot`.
`audit-before-final.log` and `static_values-final.log` use all 84 controls.
Earlier 68/76-case and Debug runs are retained separately; they are not mixed
into the table. The initial cyclic test was stopped after non-termination;
`focused-sample.txt` records its recursive traversal. The passing replacement
is recorded in `checker-focused-v2.log`.

The frozen pre-change binary is `bound-classes.8s4Xq1/home-v1`, SHA-256
`7f71d18f3a1648032b346183267382573f02475b824f5db8c30e0cc463568bd2`.
The final ReleaseFast binary is `static-values.csYPot/home-final`, SHA-256
`9fb67479dbd422678c617facf686d4a09317658e7c4a871084db906bf12572c1`;
its build log is `release.log`. Other final audit logs use `-final.log`.
Audit source SHA-256:
`301fe1b661ab781e6cde0c4ee3eac8074d14d653361d682329c5a7a9239812e5`.

The checker suite passes 4,274/4,274, conformance 1,417/1,417, Program 120/120,
driver 187/187, CLI 69/69, and the benchmark harness 50/50. Fresh callable-identity and callable-union audits
remain 56/56 and 256/256 for all three compilers. Zig formatting checks pass;
targeted Pickier reports no errors and one pre-existing README fragment warning.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_static_values.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_class_bindings.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_nominal_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported generic-class baseline and source-owned metadata (untimed)

Tracked in [#524](https://github.com/home-lang/home/issues/524), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416).
Audit commit [`d7f80bd89`](https://github.com/home-lang/home/commit/d7f80bd89)
adds 100 controls: 25 families, each with a positive and appended-only negative
variant in both app root orders. Files, roots and compiler options are identical
across compilers. Positive controls must be silent; negatives must match the
exact diagnostic-code multiset. No timing is collected.

The suite covers named/default/namespace imports, renamed and re-exported
bindings, nested arrays/objects/tuples/unions/functions, method calls, same-owner
and different-owner compatibility, importer-local name isolation, defaults,
dependent defaults and constraints, required/excess argument counts, owner-local
and imported aliases, and recursive aliases. Unsupported cases stay in the audit.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home baseline |
|---|---:|---:|---:|
| Imported generic-class controls | 100/100 | 100/100 | 50/100 |

The frozen Home baseline is `static-values.csYPot/home-final`, SHA-256
`9fb67479dbd422678c617facf686d4a09317658e7c4a871084db906bf12572c1`.
The 300 compiler/case checks produce 50 failures, all Home failures.
Evidence is `bench/vs_tsgo/results/generic-classes.9vD3xi/audit-before.log`;
audit source SHA-256 is
`19a07655d38308109c36714aaa6d9db10638f7758feac67c2ca3404118f8a2e7`.

The metadata foundation
([`af11e4ebf`](https://github.com/home-lang/home/commit/af11e4ebf)) retains parameter identities, defaults, constraints,
variance, nested annotations, declaration origins and recursive references from
the defining source. Imported aliases are resolved in that owner's bound scope;
unsupported forms remain explicit rather than becoming `any` or incomplete
objects. Class-field optional/readonly modifiers are now retained in HIR
([`f0d84813d`](https://github.com/home-lang/home/commit/f0d84813d)), including
comments between a field name, `?` and `:`. This is preparation for the imported
consumer, not a claim that generic instantiation is fixed. The collector is
tested independently and is not yet invoked during production class collection;
unused schemas are not allocated on the compilation path.

The foundation passes 129/129 Program tests (including nine schema controls),
898/898 parser tests, 187/187 driver tests, 69/69 CLI tests and 53/53 benchmark
harness tests. These are targeted foundation checks, not a new full-checker or
conformance checkpoint. Zig formatting passes; targeted Pickier reports no
errors and one pre-existing README link-fragment warning.

An experimental Debug run with schema collection enabled still passes 50/100
generic controls (`audit-foundation-debug.log`); it is not the frozen baseline
or a timing result. The same Debug binary passes all 84 static-value controls
(`static-foundation-debug.log`), as do both pinned baselines. Collection remains disabled in the committed production
path until a checked consumer can use it.

The compiler pins and installed binaries are TS **6.0.3** and native TS **7.0.2**.
The harness rejects `7.0.0-dev.20260707.2` and stable-version suffix mismatches
before collecting results. Native TS 7 and `tsgo` are the same competitor.
The original imported graph admission remains **0/2** for Home; the timing
snapshot above is unchanged and no new performance claim is made.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_generic_classes.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported generic-class instantiation (untimed)

Tracked in [#524](https://github.com/home-lang/home/issues/524), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416).
The source-owned schema collector is now enabled for generic classes. Imported
type annotations instantiate the defining declaration with the consumer's
actual arguments; defaults, dependent constraints and member expressions resolve
in the declaration's scope. Repeated instances are cached by source declaration
identity and effective arguments. Recursive object aliases with unchanged
arguments retain their object identity, optional members and concrete types.
Non-public members retain declaration origins without synthetic brand fields.
Implementation:
[`0a1e5afe8`](https://github.com/home-lang/home/commit/0a1e5afe8) and
[`33ddbef63`](https://github.com/home-lang/home/commit/33ddbef63).

The audit grew from the historical 100 cases above to **120**: 30 families,
each with a positive and appended-only negative control in both root orders.
The additional families cover growing recursive aliases, unused (phantom) type
parameters, explicit method receivers, resolved `unknown` constraints and weak
optional-object constraints. They were added in
[`96d0da00c`](https://github.com/home-lang/home/commit/96d0da00c),
[`71023f916`](https://github.com/home-lang/home/commit/71023f916),
[`65ea1e895`](https://github.com/home-lang/home/commit/65ea1e895), and
[`bb6f55301`](https://github.com/home-lang/home/commit/bb6f55301).
All compilers receive identical files and options. Positives must be silent;
negatives must match the exact diagnostic-code multiset. No cases are excluded
and no timing is collected.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Imported generic-class controls | 120/120 | 120/120 | 62/120 | 118/120 |
| Imported nominal-identity controls | 52/52 | 52/52 | 42/52 | 44/52 |
| Imported static-value controls | 84/84 | 84/84 | 84/84 | 84/84 |
| Bound-class export controls | 52/52 | 52/52 | 52/52 | 52/52 |
| Original workload admission | 18/18 | 18/18 | 16/18 | 16/18 |
| Imported graph admission (subset above) | 2/2 | 2/2 | 0/2 | 0/2 |

The full 120-case baseline was rerun against the same frozen pre-consumer Home
binary used above; **62/120 is not a reinterpretation of the historical 50/100**.
The new release passes every original 100-case control and 18 of the 20 added
controls. Same-owner phantom parameters remain structurally compatible;
different-owner private members remain incompatible. A detached method with an
explicit `this` requirement is rejected. Resolved `unknown` arguments no longer
bypass constraints. Weak-constraint checking uses apparent object types,
including the declared BigInt wrapper when available; it does not invent
required properties or make primitive `bigint` satisfy the `object` constraint.

Both remaining generic failures are the negative growing-recursion controls:
`Link<X> = { item: X; next?: Link<X[]> }` needs lazy parameterized expansion.
An eager finite graph cannot represent every instantiation. This form remains
unsupported and visible in the audit; there is no fixed-depth truncation or
new `any` substitution to manufacture a passing result. The nominal suite's
eight remaining failures concern private/protected inheritance. Generic
constructors, heritage, generic methods, unsupported annotation forms and full
cross-file checked-type transfer are not established by this checkpoint.
Variance metadata is retained, not a claim of complete variance enforcement.
Issue #524 remains open. Both imported graph timing claims remain ineligible.

Evidence is under `bench/vs_tsgo/results/generic-classes.9vD3xi/`:

- `audit-before-120.log`: 360 compiler/case checks, 58 failures, all Home.
- `audit-final-120.log`: 360 checks, two failures, both Home growing-recursion negatives.
- `nominal_origins-final.log`, `static_values-final.log` and `class_bindings-final.log`: adjacent release audits.
- `admission-final.log`: every original workload checked, including required rejection controls.
- `release-final-v2.log`: successful ReleaseFast build; `home-final`: frozen release binary.

The baseline SHA-256 is
`9fb67479dbd422678c617facf686d4a09317658e7c4a871084db906bf12572c1`.
The new release SHA-256 is
`5a4127f13c8901a1899686b09ca7d62d9bf338f41ff8ea5b43c08d179d35bbb7`.
The 120-case audit source SHA-256 is
`4fa967df7188d6f1b5928e8a8cb1ccfeb5bd25b9b56fed93e0f0f69f10a2a377`.
Version preflight verifies the executable outputs, not just the manifest:
TS **6.0.3** and native TS **7.0.2**. TS 7 and `tsgo` are one competitor;
the old `7.0.0-dev.20260707.2` binary is rejected.

Full verification passes **4,279/4,279 checker**, **1,417/1,417 conformance**,
**130/130 Program**, **187/187 driver**, **69/69 CLI** and **53/53 harness**
tests. Logs are `checker-final.log`, `conformance-final.log`,
`program-final.log`, `driver-final.log`, `cli-final.log` and
`harness-final-120.log`. Fresh release audits also retain callable identity
56/56, callable unions 256/256, graph discovery 28/28 and export origins 32/32
for all three compilers. Home's imported-owner 10/20, global 32/56 and
bound-global 44/56 results remain unchanged; both pinned competitors pass all
of those controls. Logs use the audit's underscore-separated name plus
`-final.log`. Zig formatting checks pass. Targeted Pickier reports zero errors
and one pre-existing README fragment warning (`lint-final.log`).
These are correctness results; the existing timing snapshot is unchanged.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/generic-classes.9vD3xi/home-final" python3 bench/vs_tsgo/audit_generic_classes.py
HOME_TSC="$PWD/bench/vs_tsgo/results/generic-classes.9vD3xi/home-final" python3 bench/vs_tsgo/audit_nominal_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Recursive generic-consumer baseline (untimed)

Follow-up to [#524](https://github.com/home-lang/home/issues/524), with parents
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and tracker
[#416](https://github.com/home-lang/home/issues/416).
Audit commits [`6576ff855`](https://github.com/home-lang/home/commit/6576ff855)
and [`42452f823`](https://github.com/home-lang/home/commit/42452f823)
add **216** controls: 16 recursive consumer families and two nonrecursive
calibration families, each tested with a local declaration,
a named import and a namespace import, with paired positive/appended-only
negative uses in both app root orders. All three compilers receive identical
files and options. Positive controls must be silent; negative controls must
produce exactly one TS2322. No cases are excluded and no timing is collected.

| Recursive generic placement | TS 6.0.3 | Native TS 7.0.2 | Home baseline |
|---|---:|---:|---:|
| Local declarations | 72/72 | 72/72 | 16/72 |
| Named imports | 72/72 | 72/72 | 40/72 |
| Namespace imports | 72/72 | 72/72 | 40/72 |
| Total | 216/216 | 216/216 | 96/216 |

The families cover fixed recursion, growing array arguments at depths 1, 4 and
12, growing object arguments, mutually recursive aliases, parameter permutation,
recursive method returns and array members, optional unions, indexed access,
`keyof`, generic inference, destructuring, finite structural targets and
structurally matching distinct recursive origins. Depth variants exercise the
same semantics at different use depths; they do not define an implementation
cutoff. The local controls demonstrate that the remaining problem is not only
cross-file name resolution. The direct-parameter and nonrecursive-member
calibration families pass all 24 controls for all three compilers, distinguishing
the recursive failures from ordinary generic value/member access. All failures
remain visible.

The baseline is the previously verified ReleaseFast binary
`bench/vs_tsgo/results/generic-classes.9vD3xi/home-final`, from implementation
[`33ddbef63`](https://github.com/home-lang/home/commit/33ddbef63), SHA-256
`5a4127f13c8901a1899686b09ca7d62d9bf338f41ff8ea5b43c08d179d35bbb7`.
Evidence: `bench/vs_tsgo/results/recursive-generics.mlQve8/audit-before-216.log`
(648 compiler/case checks, 120 failures, all Home). The initial 192-case run
is separately retained in `audit-before.log` (Home 72/192); the 24 calibration
controls add passes without removing any failures. Final audit source SHA-256:
`65550d718a6369f850474f6699a3d0ec3733da302373fd99ffcb56e31124ff04`.
Executable preflight verifies TS **6.0.3** and native TS **7.0.2**; TS 7 and
`tsgo` remain one competitor.

This **96/216** baseline is not a regression from, or a replacement for, the
distinct **118/120** imported generic-class audit above. Both suites are retained.
Original workload admission remains 16/18, imported graph admission remains
0/2, and the timing snapshot is unchanged. No recursive-generic speed claim is
eligible from this correctness baseline.

The representation foundation
([`c6c6c6652`](https://github.com/home-lang/home/commit/c6c6c6652)) introduces pool-owned generic definitions: a
distinct declaration identity, its declaration-scoped parameter TypeIds, and a
symbolic body. Recursive instantiation references can point back to that
identity without unfolding the body. Construction is two-phase and unpublished
until complete; allocation failure cannot publish a partial parameter list.
Type-pool transfer relocates definitions, parameters, recursive edges and source
provenance together, and rejects incomplete definitions. Separate declarations
remain distinct even when their parameter names or body shapes match.

This is prerequisite representation work. Production lowering still uses the
existing consumer from the preceding checkpoint; shared lazy evaluation and
member/relation/indexed-access consumers have not been connected to the new
definition representation. The audit failures are not claimed fixed, and no
fixed-depth expansion or new permissive fallback is introduced.

Verification passes **4,282/4,282 checker**, **1,417/1,417 conformance**,
**130/130 Program**, **187/187 driver**, **69/69 CLI** and **56/56 harness**
tests. The focused definition tests pass 4/4 and transfer tests 10/10, including
allocation-failure rollback and recursive graph preservation after releasing
the source pool. Evidence is in `recursive-generics.mlQve8/` under
`checker-definitions.log`, `conformance-definitions.log`,
`program-definitions.log`, `driver-definitions.log`, `cli-definitions.log`,
`harness.log`, `definitions-focused.log` and `transfer-focused.log`.
Zig formatting passes; targeted Pickier reports zero errors and the existing
README fragment warning (`lint.log`).

The foundation's ReleaseFast binary is frozen as
`recursive-generics.mlQve8/home-definitions`, SHA-256
`95ababead014327b0e3bc97b7909eae88aeabaf5b2542612ba79fb74ffc6e173`
(`release-definitions.log`). Its fresh 216-case audit retains **96/216** for
Home and **216/216** for both competitors (`audit-definitions-216.log`): all
648 compiler/case outcomes match the pre-foundation baseline. The separate
imported-class suite retains **118/120** for Home and **120/120** for both
competitors (`generic-classes-definitions.log`). Original workload admission
is freshly verified at **16/18** for Home and **18/18** for both competitors
(`admission-definitions.log`); the same two graph rejection gates still fail.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/generic-classes.9vD3xi/home-final" python3 bench/vs_tsgo/audit_recursive_generics.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Lazy source-owned generic consumers

Work for [#524](https://github.com/home-lang/home/issues/524), parents
[#521](https://github.com/home-lang/home/issues/521) and
[#487](https://github.com/home-lang/home/issues/487), tracker
[#416](https://github.com/home-lang/home/issues/416).
[`220a62d57`](https://github.com/home-lang/home/commit/220a62d57) expands the
preceding audit from 216 to **288** controls by adding private-to-module local
declarations. This fourth placement uses the same 18 families, two root orders,
and positive/appended-only-negative pairs. All prior controls remain. Every
compiler receives identical files/options; positive programs must be silent and
negative programs must produce exactly one TS2322. These are correctness
controls, not a recursive-generic throughput benchmark.

The frozen foundation ReleaseFast binary (`c6c6c6652`, SHA-256
`95ababead014327b0e3bc97b7909eae88aeabaf5b2542612ba79fb74ffc6e173`) passes
**112/288**: 16/72 for each local placement and 40/72 for each import placement.
Both TS 6.0.3 and native TS 7.0.2 pass **288/288**. Evidence is
`bench/vs_tsgo/results/lazy-generics.2H3YDX/recursive-before-288.log`.
The added placement exposes 56 additional Home failures; it does not remove or
reclassify any failure from the 216-case baseline. Audit source SHA-256:
`361a6c796efca23e5ef11a76efc119d8d4c7f0b07ecdfbf51acec46d3253ca15`.

Implementation [`3b7f0ea93`](https://github.com/home-lang/home/commit/3b7f0ea93)
builds a declaration-owned symbolic body once, retaining
fresh formal parameter identities. Instantiation substitutes the requested
arguments but leaves nested references symbolic. Member access, indexed access,
expression consumers and structural relations request the same cached expansion;
growing recursion no longer requires eager unfolding. Local generic class
metadata follows the same path without becoming an exported import binding.
Definition identity is based on source owner and declaration position, not a
display name. Transparent aliases preserve the identity of the type they reuse.
No fixed-depth unrolling or new permissive `any` recovery is introduced.

The dedicated growing-recursion test follows 64 requested surfaces and verifies
their concrete arguments, cache reuse and a single generic definition. This test
depth is not an implementation limit. Other focused controls cover owner
separation, dependent defaults, constraints, local export visibility and display
name collisions. Unsupported schema forms remain explicit; this checkpoint does
not establish general imported-function/heritage/mapped-type support or repair
the original graph admission gates by itself.

The final ReleaseFast candidate passes the complete recursive audit:

| Placement or separate audit | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Local exported declarations | 72/72 | 72/72 | 16/72 | 72/72 |
| Local non-exported declarations | 72/72 | 72/72 | 16/72 | 72/72 |
| Named imports | 72/72 | 72/72 | 40/72 | 72/72 |
| Namespace imports | 72/72 | 72/72 | 40/72 | 72/72 |
| Recursive total | 288/288 | 288/288 | 112/288 | 288/288 |
| Imported generic classes (separate suite) | 120/120 | 120/120 | 118/120 | 120/120 |
| Nominal identity (separate suite) | 52/52 | 52/52 | 44/52 | 44/52 |
| Original workload admission | 18/18 | 18/18 | 16/18 | 16/18 |

Evidence is under `bench/vs_tsgo/results/lazy-generics.2H3YDX/`, using the
immutable `release-v5/bin/home-tsc` binary, SHA-256
`267691e33056e2c4a8b23b757bc3eed19c8b3d90fa9407120b8985834a844ccd`.
Logs: `recursive-release-v5.log`, `audit_generic_classes-release-v5.log`,
`audit_nominal_origins-release-v5.log`, and `admission-release-v5.log`.
The 288-case audit makes 864 compiler/case checks with zero failures; the
imported-class audit makes 360 checks with zero failures. Eight Home nominal
inheritance failures and both original graph rejection failures remain visible.

The separate throughput workload
([`de72563b3`](https://github.com/home-lang/home/commit/de72563b3)) consumes 256
distinct payload interfaces through an imported `Box<T>` and four requested
levels of `Link<T[]>`. Every family checks both its complete array container
and its numeric leaf. Before timing, a temporary copy appends nine invalid uses
at the first, middle and last payload: wrong leaf type, wrong nested container,
and missing property. Admission requires exactly six TS2322 and three TS2339
diagnostics; crashes, silent acceptance and incomplete rejection fail the gate.
The original positive corpus is never mutated or replaced for the negative run.

The frozen foundation accepts these invalid uses (`recursive-workload-before.log`)
and is therefore **ineligible** for a before/after timing comparison on this new
workload. All three current compilers pass its positive and negative checks
(`admission-release-v5.log`). The expanded manifest admits 17/19 workloads for
Home and 19/19 for each competitor, while the original 18-workload set remains
16/18 for Home. Adding a passing workload does not repair either failing graph.

Exact committed-source verification passes **4,285/4,285 checker**,
**1,417/1,417 conformance**, **131/131 Program**, **187/187 driver**,
**69/69 CLI**, **9/9 source-owned focus**, and **60/60 benchmark harness** tests.
Logs are `checker-v5.log`, `conformance-v5.log`, `ts_program-v5.log`,
`ts_driver-v5.log`, `ts_cli-v5.log`, `focused-v5.log` and
`harness-recursive-final.log` in the evidence directory above. Earlier
interrupted verification attempts are not counted as passes. Zig formatting
and targeted Pickier checks pass, apart from the pre-existing README fragment
warning (`lint-docs.log`).

Reporting fix [`74d11634e`](https://github.com/home-lang/home/commit/74d11634e)
subsequently raises the harness total to **66/66**
(`harness-report-integrity.log`). Interleaved reports now require the exact
metadata-declared workload/round file set, the rotating compiler order, and one
successful finite positive timing per compiler per round. An unfinished run
cannot print partial averages under a completed-run heading. Missing/extra
rounds, malformed JSON, duplicate compilers and failed samples are rejected,
not filtered. The historical complete report still validates
(`historical-report-check.log`).

Fresh release audits also retain callable identity 56/56, callable unions
256/256, static values 84/84, bound-class exports 52/52, graph discovery 28/28,
and export origins 32/32 for all three compilers. Home's imported-owner 10/20,
global 32/56 and bound-global 44/56 results remain unchanged; each competitor
passes every control in those suites. Logs use `audit_<name>-release-v5.log`.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 bench/vs_tsgo/audit_recursive_generics.py
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload recursive_generics
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Lazy generic checkpoint performance

The full current checkpoint uses compiler `3b7f0ea93` and the frozen release
binary identified above. Raw result directory:
`bench/vs_tsgo/results/20260828T221149Z`; execution log:
`lazy-generics.2H3YDX/timing-release-v5.log`. Apple M3 Pro, arm64, macOS 27.0,
Zig `0.17.0-dev.1441+d5181a9c9`, TS **6.0.3**, native TS **7.0.2**.
TS 7 and tsgo are one competitor. All 17 selected workloads pass current
schema-3 admission before timing. The two failing original graphs are explicitly
excluded, not silently omitted from an all-workload success claim.

Each compiler receives the same generated project, minimal library, strict
checking, `noLib` and `noEmit` options. Three warmups precede 30 fresh-process
timings per compiler/workload, with compiler order rotating in every round.
The complete report validates **510 round files / 1,530 successful samples**.
No measurements are discarded, replaced or trimmed. Means and sample standard
deviations are shown below; ratios compare Home with the faster competitor.

These are **shared-workstation measurements**, not an isolated-host experiment.
This task's builds, tests and audits completed before measurement, but unrelated
CPU and filesystem activity continued. Observed load averages were
13.34 / 37.27 / 42.65 at the start and 9.88 / 21.73 / 34.34 after the run.
Several rows have substantial variance. Interleaving balances order but does
not remove contention or prove statistical significance; the narrow large-case
predicate margin is especially uncertain. Earlier historical timings are retained
elsewhere in this document, not treated as a controlled before/after experiment.

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs faster competitor |
|---|---:|---:|---:|---:|
| Startup | 63.1 ± 1.3 ms | 38.2 ± 1.0 ms | 3.4 ± 0.2 ms | 11.30× faster |
| 256 files | 206.7 ± 2.9 ms | 54.2 ± 2.5 ms | 31.5 ± 0.8 ms | 1.72× faster |
| Deep types | 146.1 ± 58.4 ms | 58.8 ± 19.1 ms | 30.1 ± 11.1 ms | 1.95× faster |
| 128-module import graph | — | — | — | Ineligible: rejection gate fails |
| 64-leaf barrel graph | — | — | — | Ineligible: rejection gate fails |
| TSX components | 161.7 ± 5.2 ms | 47.9 ± 3.1 ms | 23.1 ± 4.7 ms | 2.08× faster |
| Generic calls | 197.7 ± 49.6 ms | 60.7 ± 18.9 ms | 25.6 ± 8.7 ms | 2.37× faster |
| Control flow | 219.0 ± 78.6 ms | 67.6 ± 18.4 ms | 39.9 ± 18.3 ms | 1.69× faster |
| Type predicates | 322.9 ± 151.3 ms | 88.1 ± 33.6 ms | 53.5 ± 16.9 ms | 1.65× faster |
| Large type predicates | 1120.0 ± 211.7 ms | 393.6 ± 94.1 ms | 377.0 ± 100.9 ms | 1.04× lower mean; noisy |
| Null-safe access | 223.1 ± 75.3 ms | 69.7 ± 26.0 ms | 52.0 ± 25.9 ms | 1.34× faster |
| Destructuring | 156.0 ± 18.2 ms | 50.7 ± 4.0 ms | 37.7 ± 7.1 ms | 1.34× faster |
| Overload resolution | 224.9 ± 27.2 ms | 70.2 ± 6.5 ms | 33.6 ± 9.5 ms | 2.09× faster |
| Class hierarchy | 335.8 ± 90.2 ms | 76.8 ± 17.7 ms | 45.3 ± 14.8 ms | 1.69× faster |
| Structural objects | 229.8 ± 28.9 ms | 71.1 ± 12.3 ms | 35.5 ± 4.9 ms | 2.01× faster |
| Interface composition | 241.4 ± 39.7 ms | 73.6 ± 13.5 ms | 52.5 ± 10.3 ms | 1.40× faster |
| Variadic tuples | 275.0 ± 12.9 ms | 84.3 ± 5.7 ms | 48.0 ± 7.9 ms | 1.76× faster |
| Checked JavaScript/JSDoc | 210.3 ± 9.9 ms | 56.4 ± 7.2 ms | 39.8 ± 6.4 ms | 1.42× faster |
| Recursive generic payloads | 151.7 ± 2.2 ms | 71.8 ± 1.1 ms | 29.7 ± 0.2 ms | 2.42× faster |

Home has lower means on **17/17 timed workloads**, while expanded admission
remains **17/19**. In paired rounds Home beats native TS 7 in 30/30 recursive
rounds and 24/30 large-predicate rounds. These observations are not proof of
universal, real-project or cross-platform leadership. This correctness
implementation is not claimed to accelerate the old compiler: its predecessor
fails the new recursive workload's rejection controls, so that speed comparison
would not represent equivalent semantic work.

```sh
# Run all currently eligible workloads; failing graph gates stay explicitly excluded.
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 -c 'import sys; sys.path.insert(0,"bench/vs_tsgo"); import run; run.cmd_cold(30, 3, [w for w in run.manifest()["workloads"] if w not in ("import_graph", "reexport_graph")])'
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T221149Z
```

After the full run, an independent 30-round confirmation was declared for the
new recursive workload and the narrowest mean margin, large predicates. It uses
the same frozen binary, three warmups, pinned competitors and admission gates.
Results are retained separately in `20260828T221611Z`
(`lazy-generics.2H3YDX/timing-confirmation-v5.log`):

| Confirmation workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs faster competitor |
|---|---:|---:|---:|---:|
| Large type predicates | 1151.5 ± 272.4 ms | 392.7 ± 83.0 ms | 349.9 ± 17.0 ms | 1.12× faster |
| Recursive generic payloads | 156.6 ± 14.2 ms | 73.1 ± 3.9 ms | 29.6 ± 0.7 ms | 2.47× faster |

All **60 round files / 180 samples** validate. Home beats native TS 7 in
28/30 paired large-predicate rounds and 30/30 recursive rounds. These numbers
do not replace, get averaged into, or erase the first run's noisy 1.04× margin.
The shared-host and incomplete-coverage qualifications still apply.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload type_predicates_large --workload recursive_generics
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T221611Z
```

### Source-owned exported factory contracts (untimed)

Commit `de8fe28f1`, issue [#534](https://github.com/home-lang/home/issues/534), under
[#487](https://github.com/home-lang/home/issues/487) and
[#416](https://github.com/home-lang/home/issues/416), extends the source-owned
graph to exported interfaces, type aliases, annotated variables and functions.
The old exported-value collector scanned declaration-file lines and discarded
generic signatures. The replacement resolves bound export identities, including
aliases and export-star paths, and shares one annotation graph before checking
consumers. Function signatures retain formal parameter identities, constraints,
ordered defaults, required/rest parameters, receiver types and parameterized
returns. It does not infer missing owner annotations or publish a partial
overload/merged-interface graph as a complete type.

`audit_graph_types.py` retains **240** controls: twelve semantic families across
local, named-import, namespace-import and two two-hop barrel placements, both
root orders, each with a positive and appended-only negative program. Both
compilers receive the same files and strict project configuration. Controls
exercise explicitly annotated interfaces, inferred factory results, wrong
property types, missing/readonly members, explicit type arguments, constraints,
required arity, ordinary/rest arguments, dependent defaults, captured factories
and consumer-local name collisions. A clean positive alone is not a pass:
the negative must emit exactly its expected diagnostic code.

| Untimed control | TS 6.0.3 | Native TS 7.0.2 | Home baseline `3b7f0ea93` | Home `de8fe28f1` Release |
|---|---:|---:|---:|---:|
| Factory contracts | 240/240 | 240/240 | 130/240 | 240/240 |
| Original graph admission | 2/2 | 2/2 | 0/2 | 2/2 |
| Static-value controls | 84/84 | 84/84 | 84/84 | 84/84 |
| Nominal-origin controls | 52/52 | 52/52 | 44/52 | 44/52 |
| Imported-owner controls | 20/20 | 20/20 | 10/20 | 12/20 |
| Recursive generic controls | 288/288 | 288/288 | 288/288 | 288/288 |
| Generic-class controls | 120/120 | 120/120 | 120/120 | 120/120 |
| Bound-class controls | 52/52 | 52/52 | 52/52 | 52/52 |
| Callable identity controls | 56/56 | 56/56 | 56/56 | 56/56 |
| Callable union controls | 256/256 | 256/256 | 256/256 | 256/256 |
| Graph discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Bound-global controls | 56/56 | 56/56 | 44/56 | 44/56 |

Evidence is retained in `bench/vs_tsgo/results/graph-types.4EsbvV/`:
`audit-before.log`, `audit-v2.log`, `audit-v3.log`, `graphs-v2.log`,
`static_values-v2.log`, and `nominal_origins-v2.log`. The intermediate candidate
passed 220/240 factory controls; its twenty dependent-default failures remain
recorded. Applying defaults using owner-resolved type parameter payloads, in
declaration order, removes those failures without changing the controls.
Release repeats are in the corresponding `*-release-v3.log` files. The eight
inherited private/protected nominal-origin failures remain open, as do eight
imported-owner predicate/rest controls and the existing global-control failures.

All **19/19 workloads pass Release admission**, including the unchanged original
graph, tuple, destructuring, predicate and recursive-generic rejection controls
(`admission-release-v3.log`). Full relevant suites pass: **4,286/4,286 checker**,
**1,417/1,417 conformance**, **133/133 Program**, **187/187 driver**, **69/69 CLI**,
**10/10 source-owned focus**, and **69/69 benchmark-harness** tests. These are the
named repository suites, not a claim of complete upstream TypeScript parity.

The frozen binary is `graph-types.4EsbvV/release-v3/bin/home-tsc`, SHA-256
`9f5e333beaf9828a9720ce260ae05a872ebcea3bb51bf5785ffa3ccd7b72f1bc`.
These correctness results are **not timing claims**. The earlier measured
snapshot above still refers to its original frozen binary. A profile also
identified redundant source compilation in CommonJS export queries; follow-up
[#536](https://github.com/home-lang/home/issues/536) will use this corrected
version as its comparison baseline, never the previously ineligible graph run.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/graph-types.4EsbvV/release-v3/bin/home-tsc" python3 bench/vs_tsgo/audit_graph_types.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Exported-factory checkpoint performance

The complete run `20260828T224220Z` measures the frozen `de8fe28f1` ReleaseFast
binary above against **TS 6.0.3** and **native TS 7.0.2**. All **19/19 workloads**
pass admission before measurement, including the unchanged original graph
rejection controls. All **570 round files / 1,710 successful samples** pass the
reporter's coverage, rotating-order, exit-status and finite-duration checks.
Fresh generation independently matches all **513 measured corpus files** byte
for byte (`graph-types.4EsbvV/corpus-verified-v3.log`). No samples are discarded.

Environment: Apple M3 Pro, arm64, macOS 27.0, shared workstation; 30 interleaved
fresh-process measurements per compiler/workload after three warmups. This
task's builds, tests and audits finished before timing. Unrelated CPU and
filesystem activity continued, including another Zig compilation. Load averages
were 6.17 / 8.23 / 12.63 before the run and 6.79 / 7.03 / 10.92 afterward.
Interleaving balances order, not all contention. Means and sample standard
deviations below are observations, not statistical proof of universal leadership.

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs faster competitor |
|---|---:|---:|---:|---:|
| Startup | 68.9 ± 6.2 ms | 40.9 ± 0.9 ms | 3.6 ± 0.1 ms | 11.45× faster |
| 256 files | 220.8 ± 9.7 ms | 57.0 ± 5.4 ms | 34.8 ± 1.5 ms | 1.64× faster |
| Deep types | 131.5 ± 5.3 ms | 52.8 ± 1.7 ms | 26.5 ± 0.5 ms | 2.00× faster |
| 128-module import graph | 145.5 ± 35.6 ms | 50.8 ± 9.9 ms | 33.7 ± 7.4 ms | 1.51× faster |
| 64-leaf barrel graph | 97.2 ± 11.8 ms | 41.1 ± 1.1 ms | 25.1 ± 3.2 ms | 1.63× faster |
| TSX components | 160.4 ± 1.9 ms | 47.0 ± 1.0 ms | 26.3 ± 0.4 ms | 1.79× faster |
| Generic calls | 190.1 ± 21.9 ms | 56.5 ± 4.5 ms | 24.2 ± 1.2 ms | 2.34× faster |
| Control flow | 210.1 ± 37.7 ms | 63.2 ± 5.0 ms | 44.9 ± 7.0 ms | 1.41× faster |
| Type predicates | 259.9 ± 32.0 ms | 80.5 ± 16.2 ms | 50.5 ± 8.9 ms | 1.59× faster |
| Large type predicates | 1071.8 ± 87.3 ms | 380.6 ± 44.8 ms | 541.3 ± 50.7 ms | **1.42× slower** |
| Null-safe access | 198.3 ± 15.7 ms | 58.8 ± 3.1 ms | 41.9 ± 1.8 ms | 1.40× faster |
| Destructuring | 143.6 ± 4.6 ms | 49.8 ± 2.2 ms | 38.6 ± 4.5 ms | 1.29× faster |
| Overload resolution | 204.7 ± 11.0 ms | 66.7 ± 5.2 ms | 30.5 ± 1.4 ms | 2.19× faster |
| Class hierarchy | 193.5 ± 18.1 ms | 55.7 ± 4.2 ms | 29.9 ± 1.3 ms | 1.86× faster |
| Structural objects | 207.2 ± 19.7 ms | 63.9 ± 4.7 ms | 32.4 ± 1.8 ms | 1.97× faster |
| Interface composition | 214.1 ± 14.0 ms | 68.5 ± 6.1 ms | 47.8 ± 4.6 ms | 1.43× faster |
| Variadic tuples | 280.3 ± 21.4 ms | 85.8 ± 5.3 ms | 49.4 ± 4.0 ms | 1.74× faster |
| Checked JavaScript/JSDoc | 233.9 ± 21.7 ms | 60.0 ± 4.2 ms | 39.4 ± 0.8 ms | 1.52× faster |
| Recursive generic payloads | 166.8 ± 12.2 ms | 77.0 ± 7.5 ms | 30.9 ± 1.3 ms | 2.49× faster |

Home has lower means on **18/19**, not all workloads. It beats native TS 7 in
29/30 import-graph and 30/30 re-export-graph paired rounds, but **0/30 large
predicate rounds**. The losing row is retained and tracked by
[#537](https://github.com/home-lang/home/issues/537). Historical results suggest
a scaling regression worth investigating; they are not a controlled before/after
comparison. The cause must be established against a same-correctness baseline.
Broader rejection coverage, real-project and cross-platform measurements, and
the remaining correctness failures above still prevent an overall completion claim.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/graph-types.4EsbvV/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T224220Z
```

The full console record and rendered report are retained as
`graph-types.4EsbvV/timing-release-v3.log` and `report-release-v3.md`.

A separate same-host before/after diagnostic confirms the large-predicate
regression: frozen `3b7f0ea93` takes **351.0 ± 16.9 ms**, versus `de8fe28f1`
**533.8 ± 14.9 ms**, a **1.52× slowdown**. Both binaries first pass this same
workload's positive and unchanged predicate rejection controls. Three warmups
per binary precede thirty two-process rounds, alternating before/after order;
all **30 rounds / 60 successful samples** are retained in
`graph-types.4EsbvV/predicate-ab-v3/` with binary paths, versions and hashes.
The newer binary loses all thirty paired rounds. This diagnostic is not averaged
into the three-compiler table and says nothing about the old binary's eligibility
for the graph workloads. Source inspection identifies repeated whole-block
export-name scans as a candidate cost to investigate under #537. The subsequent
indexed-export checkpoint below implements and verifies that optimization.

### Indexed export queries and variable-list ownership

Commit `b7b9dd9ee`, follow-up [#537](https://github.com/home-lang/home/issues/537), replaces repeated
whole-source export/import scans with an index of each prepared owner's bound
declarations and unresolved alias/star edges. The index is built once per owner;
queries still traverse relevant edges with their own visibility and cycle state.
It does not cache a permissive answer or skip type checking. Lexical edge order,
explicit-export precedence, default exports, type-only restrictions, merged
symbols and declaration provenance are preserved.

An operation-count regression proves the repeated work independently of timing:
resolving 128 exports from a 256-statement source previously visited **65,536**
root statements; the indexed query visits **256**, including subsequent missing
and hidden-name queries. Test-only accounting is absent from production builds.
The original failing test output is retained as
`export-index.NVcIdu/program-before.log`; the indexed/ownership Program suite
passes **137/137**, including ambiguity, cycles, destructured declarations,
provenance and allocation-failure cleanup.

Those tests also exposed an existing parser bug: trailing declarators in
`export const first = 1, second = 2` were emitted as unexported siblings.
Commit `d6878e880` ([#538](https://github.com/home-lang/home/issues/538)) preserves export ownership
for every declarator, without inferring it from source text in the index.
The parser suite passes **891/891** tests.

The new `audit_export_lists.py` has 96 untimed cases across const/let/var/declare-var,
named/namespace/two-hop barrel imports, both root orders, and identical positives
with appended wrong-type or hidden-binding negatives. Both pinned TypeScript
compilers pass all cases. Frozen Home `de8fe28f1` fails all 96; the new candidate
passes **80/96**, with the expected diagnostic codes unchanged:

| Export-list control | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Valid trailing-member consumption | 32/32 | 32/32 | 0/32 | 32/32 |
| Wrong trailing-member type | 32/32 | 32/32 | 0/32 | 32/32 |
| Hidden name through a barrel | 16/16 | 16/16 | 0/16 | 16/16 |
| Hidden name imported directly | 16/16 | 16/16 | 0/16 | 0/16 |

The remaining direct hidden imports are rejected, but with TS2305 instead of
TS2459. They remain failures, tracked by
[#540](https://github.com/home-lang/home/issues/540); currently the more precise
local-declaration diagnostic is available for virtual same-HIR modules but not
real external owners. Evidence: `export-index.NVcIdu/export-lists-before.log`
and `export_lists-v3.log`.

All **19/19 workloads pass admission**. Existing release audits retain their
previous scores: factory 240/240, recursive 288/288, generic classes 120/120,
static 84/84, bound classes 52/52, callable identity 56/56, callable unions 256/256,
graph discovery 28/28, export origins 32/32, owners 12/20, nominal origins 44/52,
globals 32/56 and bound globals 44/56. No pre-existing failure is removed.
Relevant suites pass: checker **4,286/4,286**, conformance **1,417/1,417**,
Program **137/137**, parser **891/891**, driver **187/187**, CLI **69/69**,
emitter **499/499**, and benchmark harness **72/72**. Disk-space-failed build logs
are retained; successful retries are separately named `*-v3-retry.log`.

The frozen ReleaseFast binary is
`export-index.NVcIdu/release-v3/bin/home-tsc`, SHA-256
`615e9fa1f78c2cad17a0b8911b897ede73c00422138d6ecbb2b74801d4564f14`.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/audit_export_lists.py
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
```

The controlled large-predicate before/after run uses frozen `de8fe28f1` and
`b7b9dd9ee`, both of which first pass this workload and its unchanged predicate
rejection controls. After three warmups per binary, thirty rounds alternate the
before/after process order. All **30 round files / 60 successful finite samples**
are retained in `export-index.NVcIdu/predicate-ab-v3/`, with paths, versions and
SHA-256 hashes; console summary: `predicate-ab-v3.log`.

The previous build averages **525.6 ± 12.4 ms** and the indexed build
**353.5 ± 10.5 ms**: **32.7% less time**, with the new build faster in **30/30**
paired rounds. This comparison is restricted to an input on which both builds
pass the same semantic controls. It is separate from the earlier regression
measurement and from the full three-compiler run; results are not averaged
together. The operation-count test and same-correctness measurement support
removing the repeated export-query scans, not skipping semantic work.

### Indexed-export checkpoint performance

The complete `b7b9dd9ee` checkpoint, `20260828T231439Z`, uses the frozen binary
above on an Apple M3 Pro, arm64, macOS 27.0 shared workstation. The harness
verifies **TS 6.0.3 and native TS 7.0.2** before admission; TS 7 and `tsgo` are
one competitor. All 19 positive workloads and their unchanged rejection gates
pass on all three compilers before measurement. After three warmups, 30 rounds
rotate compiler order for every workload. Integrity validation accepts all
**570 round files / 1,710 successful finite samples**. Fresh generation after
timing matches all **513 measured corpus files byte-for-byte**.

Own builds, tests and audits had finished before timing, but unrelated shared-host
activity remained. Load averages before/after were 5.51 / 15.13 / 14.10 and
4.72 / 10.21 / 12.23. No rounds or outliers were discarded. Times below are
mean ± sample standard deviation; ratios use unrounded means and the faster
competitor (native TS 7 for every row).

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 65.3 ± 3.2 ms | 39.5 ± 2.9 ms | 3.3 ± 0.2 ms | 11.82× faster |
| `many_files` | 216.5 ± 18.0 ms | 57.0 ± 4.9 ms | 38.1 ± 12.4 ms | 1.50× faster |
| `deep_types` | 137.5 ± 12.3 ms | 55.2 ± 4.3 ms | 28.2 ± 2.6 ms | 1.96× faster |
| `import_graph` | 140.7 ± 14.4 ms | 49.2 ± 5.8 ms | 33.3 ± 4.4 ms | 1.48× faster |
| `reexport_graph` | 99.1 ± 4.3 ms | 44.1 ± 8.9 ms | 25.6 ± 3.1 ms | 1.72× faster |
| `tsx_components` | 162.8 ± 6.6 ms | 47.5 ± 1.3 ms | 23.8 ± 3.3 ms | 1.99× faster |
| `generic_calls` | 181.4 ± 13.4 ms | 56.1 ± 4.2 ms | 23.0 ± 0.8 ms | 2.44× faster |
| `control_flow` | 194.3 ± 10.4 ms | 61.3 ± 7.7 ms | 36.5 ± 1.9 ms | 1.68× faster |
| `type_predicates` | 248.1 ± 8.2 ms | 74.0 ± 1.8 ms | 45.4 ± 1.2 ms | 1.63× faster |
| `type_predicates_large` | 1053.4 ± 204.0 ms | 377.7 ± 66.4 ms | 371.6 ± 125.5 ms | 1.02× lower mean; noisy |
| `null_safe_access` | 189.6 ± 8.8 ms | 61.1 ± 23.1 ms | 39.7 ± 1.0 ms | 1.54× faster |
| `destructuring` | 145.0 ± 20.3 ms | 49.5 ± 9.2 ms | 36.6 ± 6.8 ms | 1.35× faster |
| `overload_resolution` | 194.1 ± 4.0 ms | 62.5 ± 1.5 ms | 29.1 ± 0.8 ms | 2.15× faster |
| `class_hierarchy` | 178.9 ± 19.5 ms | 50.6 ± 1.9 ms | 28.2 ± 3.0 ms | 1.79× faster |
| `structural_objects` | 180.0 ± 14.9 ms | 56.2 ± 1.2 ms | 29.2 ± 0.9 ms | 1.92× faster |
| `interface_composition` | 191.7 ± 1.7 ms | 60.4 ± 1.1 ms | 42.9 ± 0.4 ms | 1.41× faster |
| `variadic_tuples` | 242.4 ± 6.7 ms | 76.1 ± 2.7 ms | 42.9 ± 1.3 ms | 1.77× faster |
| `checkjs_jsdoc` | 204.9 ± 6.4 ms | 54.7 ± 2.4 ms | 38.0 ± 1.5 ms | 1.44× faster |
| `recursive_generics` | 157.2 ± 10.9 ms | 73.9 ± 3.5 ms | 30.2 ± 1.7 ms | 2.45× faster |

Home has lower means on **19/19**, but this is not universal or statistically
established benchmark leadership. Large predicates lead by only 1.02× with
substantial variance and **25/30 paired wins** over TS 7. Import graph, re-export
graph and many-files paired wins are 29/30, 30/30 and 29/30 respectively.
Real projects, additional platforms and the outstanding correctness gaps above
remain unvalidated. The earlier losing checkpoint stays documented separately.

An independent large-predicate confirmation, `20260828T231856Z`, uses the same
binary, unchanged controls, three warmups and 30 rotating-order rounds. All
**30 round files / 90 successful samples** validate. Home has the lower time
in **29/30 paired rounds**; the margin remains narrow. This targeted run is
reported separately, not substituted for the full-run row or pooled with it:

| Confirmation workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `type_predicates_large` | 950.2 ± 6.6 ms | 331.4 ± 4.6 ms | 320.4 ± 2.8 ms | 1.03× faster |

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T231439Z
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload type_predicates_large
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T231856Z
```

Full-run, confirmation and input-integrity logs are retained locally as
`export-index.NVcIdu/timing-v3.log`, `confirmation-v3.log` and
`corpus-verified-v3.log`. Raw round files and metadata remain in their named
result directories under `bench/vs_tsgo/results/`; they are not combined with
any earlier checkpoint.

### Prepared CommonJS export queries

Commit `1cfc33c1a`, follow-up [#536](https://github.com/home-lang/home/issues/536), removes a repeated
compilation in the empty-name export query. The CLI previously read the file
and ran a complete parse/bind/check to find a CommonJS constructor name before
obtaining its already cached bound module. The query now borrows that prepared
owner's HIR and bindings directly; the conformance adapter retains prepared
owners for both shape and export-table queries as well. The source-only API
prepares bindings but no longer checks merely to answer this shape question.

Raw `module.exports` substring recovery is removed. Display names come from
bound class constructors and const aliases, not comments, strings, unbound
names or unrelated function constructors. Local `module` bindings are
distinguished from the CommonJS wrapper binding. Multiple export assignments
do not get flattened into the first class's name: this single-class display
fact is absent when the actual union type is needed. This metadata query does
not replace semantic type checking or supply an `any` type.

The new audit in commit `d95dfaac1` also exposes a separate cross-file typing
gap, tracked by [#541](https://github.com/home-lang/home/issues/541). It includes
11 source forms, both root orders, valid consumption, and the identical program
with an appended wrong-type or missing-member use. Every configuration
explicitly lists the JavaScript files and enables strict `allowJs`/`checkJs`.
Both pinned compilers pass **66/66**; frozen Home `b7b9dd9ee` passes **22/66**:

| Untimed CommonJS control | TS 6.0.3 | Native TS 7.0.2 | Home baseline |
|---|---:|---:|---:|
| Valid instance consumption | 22/22 | 22/22 | 22/22 |
| Wrong consumed member type (TS2322) | 22/22 | 22/22 | 0/22 |
| Missing member (TS2339) | 22/22 | 22/22 | 0/22 |

The missing 44 diagnostics are retained, not waived. CommonJS instance
consumption is **not a timed workload**. Reassignment can produce union types;
TS 6 and TS 7 differ in union ordering/display for some probes, so the shared
audit compares exact diagnostic-code multisets, not an invented common wording.

```sh
python3 bench/vs_tsgo/audit_commonjs.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

Evidence is retained locally in `bench/vs_tsgo/results/commonjs-query.hyU20d/`:
`audit-before.log` records the 198 checks. `probe-roots-before.log` includes
diagnostic wording. The initial `probe-before.log` accidentally excluded JS
via a TS-only include and is **not valid admission evidence**; the replacement
uses explicit JS roots, and harness tests now enforce those roots and flags.

The ReleaseFast candidate is `commonjs-query.hyU20d/release-v1/bin/home-tsc`,
SHA-256 `573257a819a178c9387f6d02a7992c08f995185f5dbc94034eb5eadc0ae956c0`.
All **19/19** existing workload admission gates pass before timing. The complete
15-audit comparison checks case identities as well as totals: **every previously
passing case still passes**. Home's CommonJS result remains 22/66 and all other
audit scores remain unchanged, including exported factories 240/240, recursive
generics 288/288, exported variable lists 80/96, nominal origins 44/52, owners
12/20, globals 32/56 and bound globals 44/56. Both competitors pass every case.

Program **140/140**, conformance **1,418/1,418**, CLI **69/69** and harness
**75/75** tests pass; unchanged checker and driver targets verify from cache.
Program tests cover bound aliases,
shadowing, comments/strings, multiple assignments, and 128 repeated queries with
an unchanged HIR/type pool and no checked-owner state. Conformance adds cache
identity checks in both JavaScript modes. Three disk-interrupted audit logs are
retained alongside complete `*-v1-retry.log` replacements; the final per-case
verification is `verification-final.log`. No incomplete audit was counted as
passing, and no source, frozen compiler or benchmark evidence was deleted.
The first conformance command returned success but lost its console output
during disk exhaustion; the complete successful retry is retained as
`conformance-v1-retry.log`.

### Prepared-query checkpoint performance

The same-correctness before/after diagnostic compares frozen `b7b9dd9ee` with
`1cfc33c1a`. Both first pass the original import and re-export graph positives
and their unchanged negative controls. Each workload has three warmups per
binary followed by 30 rounds alternating process order. All **60 round files /
120 successful finite samples** are retained in
`commonjs-query.hyU20d/graph-ab-v1/`, including commands, versions and hashes.

| Paired graph comparison | Before | Prepared query | After / before | Lower after time |
|---|---:|---:|---:|---:|
| `import_graph` | 32.4 ± 1.7 ms | 28.4 ± 0.6 ms | 0.876 (12.4% less time) | 30/30 rounds |
| `reexport_graph` | 27.9 ± 5.2 ms | 27.3 ± 4.2 ms | 0.977 (2.3% less time) | 17/30 rounds |

The import-graph improvement is consistent across this run. The small barrel
mean difference is noisy and does **not** establish a reliable improvement.
This comparison is separate from the full three-compiler run; the measurements
are not averaged together. Before-run load averages were 5.43 / 7.41 / 8.00 on
the shared Apple M3 Pro workstation, after our builds, tests and audits finished.

The checkpoint also records resolved compiler artifacts outside timed commands:
both Home binaries, the actual native TS 7 executable, TS 6's compiler payload
(`lib/_tsc.js`), launchers and Node runtime. The native compiler is distinguished
from its JavaScript launcher. Evidence: `provenance-before.json` and the
checkpoint-local `provenance.py`; automatic harness-wide provenance remains
tracked by [#544](https://github.com/home-lang/home/issues/544).

The complete three-compiler measurement is **`20260828T234350Z`**, on the same
Apple M3 Pro arm64 / macOS 27.0 shared workstation. Verified versions are
**TS 6.0.3 and native TS 7.0.2**; native TS 7/`tsgo` is one competitor. All 19
workloads pass admission before three warmups and 30 rotating-order rounds.
Integrity validation accepts **570 round files / 1,710 successful finite
samples**. No sample is discarded. Fresh generation matches all **513 corpus
files byte-for-byte**, and the recorded compiler/runtime/launcher paths and
hashes match after measurement (`provenance-after.json`).

Our builds, tests and audits had finished before timing; unrelated shared-host
activity persisted. Full-run load averages before/after were 4.89 / 7.16 / 7.89
and 6.37 / 7.56 / 7.94. Times below are mean ± sample standard deviation;
ratios use unrounded means and the faster competitor (native TS 7 in every row).

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 65.7 ± 1.2 ms | 40.0 ± 1.1 ms | 3.6 ± 0.1 ms | 11.26× faster |
| `many_files` | 214.6 ± 2.7 ms | 57.2 ± 1.8 ms | 34.8 ± 1.0 ms | 1.65× faster |
| `deep_types` | 132.6 ± 17.7 ms | 53.1 ± 2.5 ms | 27.1 ± 1.1 ms | 1.96× faster |
| `import_graph` | 131.0 ± 2.1 ms | 47.0 ± 1.3 ms | 28.1 ± 1.1 ms | 1.67× faster |
| `reexport_graph` | 102.7 ± 14.8 ms | 42.7 ± 1.3 ms | 25.6 ± 2.5 ms | 1.67× faster |
| `tsx_components` | 167.9 ± 1.9 ms | 48.0 ± 0.9 ms | 23.3 ± 0.2 ms | 2.06× faster |
| `generic_calls` | 182.8 ± 3.2 ms | 56.3 ± 1.7 ms | 23.2 ± 0.4 ms | 2.42× faster |
| `control_flow` | 288.2 ± 93.7 ms | 86.9 ± 35.4 ms | 46.7 ± 11.7 ms | 1.86× faster |
| `type_predicates` | 434.7 ± 102.3 ms | 142.9 ± 87.0 ms | 67.7 ± 15.1 ms | 2.11× faster |
| `type_predicates_large` | 1023.2 ± 72.0 ms | 362.2 ± 30.4 ms | 340.5 ± 18.2 ms | 1.06× lower mean; narrow |
| `null_safe_access` | 187.3 ± 2.2 ms | 57.0 ± 1.8 ms | 39.6 ± 0.4 ms | 1.44× faster |
| `destructuring` | 137.7 ± 2.1 ms | 47.6 ± 1.4 ms | 35.3 ± 0.7 ms | 1.35× faster |
| `overload_resolution` | 196.8 ± 10.6 ms | 63.7 ± 1.8 ms | 29.5 ± 0.7 ms | 2.16× faster |
| `class_hierarchy` | 233.5 ± 135.8 ms | 62.6 ± 39.5 ms | 34.2 ± 18.4 ms | 1.83× faster |
| `structural_objects` | 186.2 ± 11.0 ms | 59.1 ± 4.4 ms | 30.6 ± 1.7 ms | 1.93× faster |
| `interface_composition` | 200.3 ± 5.2 ms | 63.9 ± 1.8 ms | 44.8 ± 1.2 ms | 1.43× faster |
| `variadic_tuples` | 240.3 ± 5.6 ms | 74.8 ± 2.3 ms | 43.1 ± 2.6 ms | 1.74× faster |
| `checkjs_jsdoc` | 200.8 ± 4.6 ms | 53.6 ± 1.3 ms | 37.1 ± 0.6 ms | 1.45× faster |
| `recursive_generics` | 150.7 ± 3.7 ms | 71.1 ± 1.8 ms | 29.1 ± 0.5 ms | 2.44× faster |

Home records lower means on **19/19**. Large predicates lead by only 1.06×
and win 29/30 paired rounds. Small predicates and class hierarchy also win
29/30; every other row wins 30/30. Control-flow, small-predicate and class rows
show substantial variance. These observations are not universal or statistically
established leadership: real projects, other platforms and the outstanding
CommonJS/global/owner/diagnostic gaps remain unvalidated. Earlier checkpoints
and their losses stay documented separately.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/commonjs-query.hyU20d/release-v1/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T234350Z
```

Console/report evidence: `commonjs-query.hyU20d/timing-v1.log` and
`report-v1.md`; unchanged input verification: `corpus-verified-v1.log`.

The independent large-predicate confirmation **`20260828T234818Z`** uses the
same frozen compiler and unchanged admission gates, three warmups and 30
rotating-order rounds. All **30 round files / 90 successful finite samples**
validate. Home has the lower time in **30/30 paired rounds**; the margin is
still modest. This confirmation is separate, not pooled with or substituted
for the full-run row:

| Confirmation workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `type_predicates_large` | 1111.8 ± 54.4 ms | 388.5 ± 16.7 ms | 358.6 ± 11.7 ms | 1.08× faster |

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/commonjs-query.hyU20d/release-v1/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload type_predicates_large
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T234818Z
```

The console record is `commonjs-query.hyU20d/confirmation-v1.log`.
`provenance-confirmation.json` verifies that all recorded artifact hashes still
match the pre-measurement snapshot. Raw full-run and confirmation JSON remain
in their separately named directories under `bench/vs_tsgo/results/`.
