# Type-only declaration spaces and conformance honesty

Previous TypeScript corpus pass claims are withdrawn. The harness at the source
base recorded in `manifest.json` replaced actual diagnostics with expected
headers for 2,499 fixture names, returned passes without compilation for 13
names, copied missing library errors, rescued mismatches, and filtered option
diagnostics. Historical logs preserve the old harness's reports; they do not
establish faithful compiler parity. See [#840](https://github.com/home-lang/home/issues/840),
[#832](https://github.com/home-lang/home/issues/832) and
[#66](https://github.com/home-lang/home/issues/66).

These result overrides and baseline-dependent output transformations are
removed. Both coarse and exact modes use the same compilation route; virtual
file boundaries are determined from the source layout. Option diagnostics
remain in expected and actual streams. Explicit surveys fail on mismatches in
either mode. Negative controls require genuine TS2322 errors for former
exception names, retain option diagnostics, reject absent expected diagnostics,
and verify that library errors are not copied into either compiler route.

The compiler batch independently preserves namespace declaration-space meaning
through erased aliases and accepts computed keys in interfaces, type literals,
abstract and ambient declarations. Emitted object/class keys still report
type-only-import misuse. Enums retain namespace meaning and remain subject to
conflicting namespace-import diagnostics.

Verified controls:

- complete checker: 4,482/4,482, 2,071 MB peak;
- complete program tests: 228/228, 2,167 MB peak;
- harness honesty controls: 4/4, 2,100 MB peak.
- stripped ReleaseFast compiler: 3/3 build steps, 2,931 MB peak;
- opt-in survey artifact: 3/3 tests, 2,079 MB peak.

The full normal conformance run reports 1,400/1,423 passing tests and **23
failures**, exits 1, and peaks at 2,245 MB. All failing test names are recorded
in `conformance-failures.json`. The baseline-aware survey measures 582/586,
with four genuine mismatches and zero skips. Smoke/category surveys measure
16/16 and 86/86 under the intermediate harness; these are bounded survey
results, subject to the remaining input/options audit below.

All heavy commands use the normal machine lock and 3,840 MB ceiling. Generated
inactive local Zig objects were reclaimed without changing sources or pinned
upstream artifacts. Original upstream cases, baselines, deadlines, skips, TODOs
and ratchet ceilings remain unchanged.

The input/options/library audit remains open: expected diagnostics still
influence legacy strictness inference, and synthetic library declarations,
file inclusion and variant selection need independent upstream verification.
Fresh results from this intermediate harness must be read with that boundary.
Neither these controls nor TypeScript cases earn original Bun test-case credit.
Full logical Bun parity remains incomplete.
