# TypeScript frontend benchmarks

This harness compares the pinned JavaScript `tsc` 6.x compiler, the pinned
native `tsgo` 7.x compiler, and a local release build of `home-tsc` on
identical, deterministic TypeScript projects.

## Run it

```sh
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
./bench/vs_tsgo/run.sh setup
./bench/vs_tsgo/run.sh corpus
./bench/vs_tsgo/run.sh cold
./bench/vs_tsgo/run.sh report
```

Set `HOME_TSC=/absolute/path/to/home-tsc` to benchmark a different Home binary.
Raw Hyperfine JSON and run metadata land under `results/<UTC timestamp>/`.
The runner rejects installed TS 6 or TS 7 versions that differ from
`corpus.toml` before creating timing results. Rerun `setup` after changing a pin.
The native TS 7 compiler is the single `tsgo` entry, not a separate competitor.

Run harness regression tests with
`python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'`.

## Linux container

Build `home-tsc` natively for the Linux machine that will run the benchmark,
then build the pinned benchmark image from the repository root:

```sh
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
docker build -f bench/vs_tsgo/Dockerfile -t home-ts-frontend-bench .
docker run --rm --mount type=bind,src="$PWD",dst=/work \
  home-ts-frontend-bench cold --runs 30 --warmup 3
```

The root `.dockerignore` keeps the image context limited to the container
entrypoint. The repository is mounted only at run time, and the entrypoint
installs the exact TS 6.0.3 and native TS 7.0.2 manifest pins, regenerates the
corpus, runs every admission control, and then measures. Raw results are
written back to `bench/vs_tsgo/results/<UTC timestamp>/`.

Use a workspace on a native Linux filesystem. A repository shared from macOS
through VirtioFS is useful for functional diagnostics but is not an eligible
Linux performance environment because filesystem-heavy workloads measure the
share implementation. For a Linux VM, copy the repository to its ext4 volume
before building and running the container. The runner records and verifies
compiler payload and tool hashes before admission and after measurement; the
report refuses results whose provenance changed.

## Qualified checkpoints

| Platform | Result ID | Home lower means | Detailed report |
|---|---|---:|---|
| Apple M3 Pro / macOS arm64 | `20260831T053521Z` | 20/20 | [macOS snapshot](../../docs/docs/TS_PERFORMANCE.md#current-snapshot) |
| Linux arm64 / pinned Bookworm container | `20260829T035150Z` | 20/20 | [Linux checkpoint](../../docs/docs/TS_PERFORMANCE.md#linux-arm64-container-checkpoint) |

Both checkpoints compare TS 6.0.3 with the single native TS 7.0.2 (`tsgo`)
competitor. They retain every measured sample and document narrow rows and
host-specific variance; they do not replace real-project benchmarking or
measure unlisted platforms.

The separate global-declaration admission audit is **untimed**:

```sh
python3 bench/vs_tsgo/audit_globals.py
```

It checks valid and invalid projects with all three pinned compilers, including
script/module isolation and explicit declaration-before/after-app file orders.
Cross-file controls include ambient `var`, `let`, and `const` bindings, typed
`globalThis` reads, interfaces, and declaration merging; unresolved lexical
globals and erased property types are failures, not exclusions.
Every compiler receives the same files and configuration. A crash, missing
diagnostic, extra diagnostic, or rejected valid input fails the audit. The
default includes unresolved cross-file cases tracked in
[#480](https://github.com/home-lang/home/issues/480), so it is expected to exit
nonzero until those cases are fixed; it does not skip known failures or add them
to the timing table. Use `--family same-file` or `--family cross-file` to focus
an investigation, and retain the full audit for admission decisions.

The separate imported-owner audit is also **untimed**:

```sh
python3 bench/vs_tsgo/audit_owners.py
```

It checks same-named declarations from two real modules: constrained generics,
type predicates, private class origins, rest arguments, and readonly flags.
Each family has valid/invalid pairs with the app explicitly listed before and
after both declaration files. Only invalid statements are appended to the
negative app; declarations and compiler settings stay identical. It uses the
same version/diagnostic checks as the global audit and keeps known failures in
the default selection. These controls inform cross-file integration under
[#487](https://github.com/home-lang/home/issues/487), not the timing table.

The callable-identity audit is **untimed** as well:

```sh
python3 bench/vs_tsgo/audit_callables.py
```

Its 56 cases test whether equal parameter/return shapes accidentally share
predicate, rest, optional, or generic metadata. Each valid/invalid pair uses
identical declarations in both declaration orders and in script/module scope;
only the invalid statement is appended. Predicate controls exercise direct
calls, aliases, wrappers, and assignments. It uses the same exact-version and
diagnostic checks, with no skipped failures. Use `--family` for an investigation
and the complete audit for verification. Tracked in
[#507](https://github.com/home-lang/home/issues/507).

Callable-union reduction has a separate **untimed** audit:

```sh
python3 bench/vs_tsgo/audit_callable_unions.py
```

Its 256 cases cover mixed predicate/boolean functions, different predicate
targets, compatible predicates, and explicit receiver types. Declaration order
and branch order vary independently across arrays, conditional expressions,
object wrappers, and script/module scope. Every negative control only appends
an invalid use to its positive project. All three compilers receive identical
projects, exact version checks, and exact diagnostic-code comparisons; no
failures are waived. Tracked in [#511](https://github.com/home-lang/home/issues/511).

For an additional targeted confirmation, use
`./bench/vs_tsgo/run.sh cold --runs 30 --warmup 3 --workload type_predicates_large`.
Repeat `--workload` for multiple cases; omitting it still runs the full suite.
Selection is recorded in metadata, and unknown or duplicate names are rejected
before creating results. Validation and timing rules are unchanged. A targeted
run supplements the full-suite report; retain and report both results.

Static CommonJS dependency discovery has a separate **untimed** audit:

```sh
python3 bench/vs_tsgo/audit_commonjs_discovery.py
```

Its 44 cases distinguish six followed `require` graph shapes from comment,
string, dynamic-specifier, property-call and multiple-argument decoys. Entry-only
projects prove whether the dependency is discovered; all-file controls prove
the same leaf diagnostic is observable. TS 6.0.3, native TS 7.0.2 and Home pass
44/44 after [#545](https://github.com/home-lang/home/issues/545). This result is
not timed and does not waive the separate CommonJS type-linkage failures below.

Cross-file CommonJS instance consumption has an **untimed** audit:

```sh
python3 bench/vs_tsgo/audit_commonjs.py
```

Its 66 cases use explicit JavaScript roots with `allowJs` and `checkJs`, both
owner/app orders, and identical positives with appended wrong-type or missing
member controls. Direct, bracket, parenthesized and aliased construction,
reassignment, nested/shadowed assignments and comment/string decoys are covered.
Both pinned TypeScript compilers pass all cases. Home passes only the 22
positives in the frozen baseline and passes all 66 cases after checked owner
types are transferred under [#541](https://github.com/home-lang/home/issues/541).
This audit remains an untimed correctness result. The separate `commonjs_graph`
timing under [#546](https://github.com/home-lang/home/issues/546) is admitted
only after this audit and its workload-specific negative controls pass. Query
reuse under [#536](https://github.com/home-lang/home/issues/536) does not itself
establish cross-file CommonJS typing.

## Methodology

- Every compiler receives `--noEmit -p <same tsconfig>`; all other benchmark
  options live in that shared project file.
- Every generated project enables `strict`, `noLib`, and `skipLibCheck`.
- `noLib` makes this a frontend benchmark: it prevents bundled library size or
  availability from advantaging any compiler.
- Positive validation requires every compiler to exit successfully and silently.
  That alone does not establish equivalent semantic checking: untimed negative
  controls additionally cover destructuring, predicates, variadic tuples, both
  ES-module graphs, and the checked CommonJS graph.
  The entire selected suite must pass admission before any timing or result
  directory is created. Other features need broader rejection-control coverage.
- Hyperfine runs three warmups followed by ten measured processes by default.
  Each measured round contains all three compilers, with their order rotated so
  changing workstation load cannot systematically favor one compiler.
- Compiler versions, host details, timestamp, and run counts are saved beside
  the raw results.
- Comparisons use the faster competitor. Ratios that round to `1.00×` are
  labeled near ties in either direction; this display rule is not a statistical
  significance test. Directional labels compare means, not certainty of a win.

The workloads cover distinct costs rather than repeating one favorable shape:

| Workload | Shape | Purpose |
|---|---:|---|
| `startup` | 1 small file | Cold process and frontend startup |
| `many_files` | 256 files | File discovery and repeated parse/check overhead |
| `deep_types` | 1 large file | Conditional, mapped, indexed, and template literal types |
| `import_graph` | 128 linked modules | Module resolution, export lookup, and cross-file checking |
| `reexport_graph` | 64 leaves + 8 barrels | Recursive export-star projection through barrel modules |
| `tsx_components` | 256 typed components | TSX scanning, parsing, contextual props, expressions, and checking |
| `generic_calls` | 256 typed call groups | Constrained inference, `keyof`, indexed access, mapped returns, and contextual callbacks |
| `control_flow` | 256 exhaustive functions | Discriminated-union narrowing, branch joins, definite assignment, and exhaustiveness |
| `type_predicates` | 256 predicate families | User-defined predicates, assertion functions, call-driven narrowing, nested property reads, and typed consumption |
| `type_predicates_large` | 2,048 predicate families | Scaling behavior of the same generator, feature mix, and compiler configuration |
| `null_safe_access` | 256 nullable object families | Optional property, element, and call chains, nullish coalescing, non-null assertions, and typed consumption |
| `destructuring` | 128 object families | Nested object and tuple bindings, defaults, object rest, spread reconstruction, and typed consumption |
| `overload_resolution` | 128 groups × 8 calls | Overload candidate selection, generic literal inference, and contextual argument typing |
| `class_hierarchy` | 128 generic class families | Inheritance, overrides, constructors, instance members, and structural interface checking |
| `structural_objects` | 128 source/target object families | Nested structural compatibility, optional and readonly members, tuples, intersections, generic function properties, and excess source members |
| `interface_composition` | 128 merged interface families | Multi-base generic inheritance, repeated interface declarations, namespace/type merging, inherited member aggregation, and structural consumption |
| `variadic_tuples` | 256 readonly tuple families | Variadic tuple concat, readonly inference, conditional head/tail extraction, generic rest and spread, indexed reads, and typed consumption |
| `checkjs_jsdoc` | 128 checked-JavaScript families | JSDoc typedefs, constrained templates, callbacks, classes, property reads, and typed result consumption |
| `commonjs_graph` | 128 checked-JavaScript owners + one app | Static `require` discovery, inferred whole-export fields, reassignment unions, and typed cross-file consumption |
| `recursive_generics` | 256 recursive generic consumers | Imported generic declaration ownership, four recursive array levels, and concrete container/leaf checking |

These synthetic workloads are intentionally deterministic and dependency-free.
The destructuring workload also runs five automatic negative controls before
timing: nested property, tuple element, rest-field, default-value, and excluded
rest-property checks must produce four TS2322 diagnostics and one TS2339 in
every compiler. These controls run in a temporary copy and are never timed.
Both predicate sizes have four automatic controls inside the guard branch and after
the assertion call: assigning a narrowed string property to `number` and
reading an excluded union member must produce two TS2322 diagnostics and two
TS2339 diagnostics in every compiler. These also use an untimed temporary copy.
Both module graphs additionally require TS2322 for assigning an imported
generic property to the wrong type and TS2339 for reading a missing member.
The checked CommonJS graph appends wrong-label and missing-member uses for the
first, middle, and last owner in an untimed copy; every compiler must emit
exactly three TS2322 and three TS2339 diagnostics. The result directory is not
created until all selected positive and negative controls pass.
Home `de8fe28f1` passes these unchanged controls after source-owned factory typing
([#534](https://github.com/home-lang/home/issues/534)); the final candidate also
passes the CommonJS controls, so all 20 workloads now pass admission. Earlier
binaries failed and were not eligible for graph timings.
The graphs remain in the suite; they are not silently omitted. Historical graph timings remain available, but
the reporter marks results without schema-2 admission as ineligible speed claims.

They do not stand in for application-scale measurements; pinned real-world
projects should be added only when all three compilers can validate the same
configuration and dependency graph.
