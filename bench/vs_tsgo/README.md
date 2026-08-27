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

## Methodology

- Every compiler receives `--noEmit -p <same tsconfig>`; all other benchmark
  options live in that shared project file.
- Every generated project enables `strict`, `noLib`, and `skipLibCheck`.
- `noLib` makes this a frontend benchmark: it prevents bundled library size or
  availability from advantaging any compiler.
- A validation pass requires every compiler to exit successfully and silently
  before timing begins. A compiler cannot win by skipping an unsupported input.
- Hyperfine runs three warmups followed by ten measured processes by default.
  Each measured round contains all three compilers, with their order rotated so
  changing workstation load cannot systematically favor one compiler.
- Compiler versions, host details, timestamp, and run counts are saved beside
  the raw results.

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
| `overload_resolution` | 128 groups × 8 calls | Overload candidate selection, generic literal inference, and contextual argument typing |
| `class_hierarchy` | 128 generic class families | Inheritance, overrides, constructors, instance members, and structural interface checking |
| `structural_objects` | 128 source/target object families | Nested structural compatibility, optional and readonly members, tuples, intersections, generic function properties, and excess source members |
| `interface_composition` | 128 merged interface families | Multi-base generic inheritance, repeated interface declarations, namespace/type merging, inherited member aggregation, and structural consumption |
| `variadic_tuples` | 256 readonly tuple families | Variadic tuple concat, readonly inference, conditional head/tail extraction, generic rest and spread, indexed reads, and typed consumption |

These synthetic workloads are intentionally deterministic and dependency-free.
They do not stand in for application-scale measurements; pinned real-world
projects should be added only when all three compilers can validate the same
configuration and dependency graph.
