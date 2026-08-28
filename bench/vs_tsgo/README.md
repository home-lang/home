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

The separate global-declaration admission audit is **untimed**:

```sh
python3 bench/vs_tsgo/audit_globals.py
```

It checks valid and invalid projects with all three pinned compilers, including
script/module isolation and explicit declaration-before/after-app file orders.
Cross-file controls include ambient `var`, `let`, and `const` bindings as well
as interfaces and declaration merging; unresolved lexical globals are failures,
not exclusions.
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

For an additional targeted confirmation, use
`./bench/vs_tsgo/run.sh cold --runs 30 --warmup 3 --workload type_predicates_large`.
Repeat `--workload` for multiple cases; omitting it still runs the full suite.
Selection is recorded in metadata, and unknown or duplicate names are rejected
before creating results. Validation and timing rules are unchanged. A targeted
run supplements the full-suite report; retain and report both results.

## Methodology

- Every compiler receives `--noEmit -p <same tsconfig>`; all other benchmark
  options live in that shared project file.
- Every generated project enables `strict`, `noLib`, and `skipLibCheck`.
- `noLib` makes this a frontend benchmark: it prevents bundled library size or
  availability from advantaging any compiler.
- Positive validation requires every compiler to exit successfully and silently.
  That alone does not establish equivalent semantic checking: untimed negative
  controls additionally cover destructuring, predicates, and both module graphs.
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
Home currently fails these controls ([#487](https://github.com/home-lang/home/issues/487)),
so the default full run stops before timing. The graphs remain in the suite;
they are not silently omitted. Historical graph timings remain available, but
the reporter marks results without schema-2 admission as ineligible speed claims.

They do not stand in for application-scale measurements; pinned real-world
projects should be added only when all three compilers can validate the same
configuration and dependency graph.
