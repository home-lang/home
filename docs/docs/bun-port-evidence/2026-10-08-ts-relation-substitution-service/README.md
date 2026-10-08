# Relation substitution through owned type graphs

Published source: [d1b893abf](https://github.com/home-lang/home/commit/d1b893abf).

The relation engine's positional rewrite repeatedly rebuilt shared structural
subtrees. It dropped receiver types and checked predicate metadata, ignored tuple
and generic-reference arguments, and followed mapper replacements transitively.
The pinned reference compiler applies a positional mapper simultaneously. Home
now preserves that mapping behavior and uses the checker's substitution service
for checked-source graphs, retaining callable, predicate and declaration metadata.
The service is attached only after the checker has a stable address and detached
only when that active owner is destroyed.

The standalone pool graph walk has a memo per fixed mapper and separate lexical
binder scopes. Exact recursive edges retain pool-owned bodies, parameter
identities and mapped arguments. Structural consumers resolve their requested
surface. Tuples, receiver types, string mappings and mapped-key identities are
retained. Fresh generic binders keep constraints, defaults, variance, constness
and source-declaration identity. Borrowed template text is snapshotted before
nested rewriting can relocate its owning pool.

Negative controls retain three graph failures, one metadata failure and one
recursive-edge failure. An initial revision fails compilation and executes no
tests. An allocation-failure control exposes a pre-existing 32,768-byte leak when
L2 construction fails after L1 allocation; constructor cleanup now releases L1.
Additional negative controls expose publication of partial expansions after a
depth/count guard. Both services now track unresolved deferrals and withhold
completion-cache entries; a checker reference can be retried after budget recovery.
Original depth/count and memory limits remain unchanged.

Final focused gates pass graph 8/8 and metadata/ownership/recovery 4/4. Exhaustive
allocation-failure injection propagates errors and releases scratch storage.
The pre-integration tree passes checker 4,518/4,518, driver 200/200, Program
241/241, opt-in controls 3/3 and survey admission/mismatch controls 10/10. Its
compiler builds at 2,888 MB. Pinned 106-file Zod retains 195 TS diagnostics and
three HM9002 recoveries, with the ceiling unchanged, at 490 MB; normalized output
matches the preceding checkpoint. Zod is not a passing project.

The first original React attempt is deliberately interrupted with exit 130 to
validate the concurrently published CommonJS-index integration. It starts
`intraExpressionInferencesJsx`, leaves
`contextuallyTypedStringLiteralsInJsxAttributes02` unstarted and earns no complete
aggregate or passing-case credit.

After CommonJS-index integration, source d1b893abf passes checker 4,519/4,519,
driver 200/200, Program 242/242, opt-in controls 3/3 and all ten survey controls.
Its compiler builds at 2,901 MB; Zod retains 195 TS diagnostics and three
recoveries at 478 MB, with normalized diagnostics unchanged. The original React
measurement on this integrated source is still running at the 2026-10-08
18:06:59 UTC snapshot: the first fixture is unfinished, the second unstarted,
and no original-case credit is claimed. A sample at about four minutes shows
interface checking with repeated UMD namespace source scans. Its sampled 1.1 GB
physical footprint is not a final peak. The subsequently retained terminal run exits 124 at the unchanged 900-second
wall-clock limit. The first fixture remains unfinished and the second unstarted;
there is no complete aggregate or passing-case credit. The timeout path does not
report its final memory peak. A further sample at about thirteen minutes shows
repeated UMD namespace scans, with sampled footprint 1.3 GB. Neither sampled
footprint is a final peak or proof that earlier memory failures are solved.

Fixtures, declarations, expected diagnostics, skips/TODOs, the 900-second original
React deadline, normal lock and resource floors remain unchanged. The manifest
records exact source stages and hashes. Retained failures and interruptions are
not passing corpus cases. Graph/declaration-policy acceptance remains open in
[#842](https://github.com/home-lang/home/issues/842), compiler-input fidelity in
[#841](https://github.com/home-lang/home/issues/841), complete corpus acceptance in
[#832](https://github.com/home-lang/home/issues/832), and full Bun parity in
[#66](https://github.com/home-lang/home/issues/66).
