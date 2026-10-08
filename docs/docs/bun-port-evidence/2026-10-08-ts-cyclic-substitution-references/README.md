# Owned cyclic substitution references

Sources: [9e98f427d](https://github.com/home-lang/home/commit/9e98f427d) and
[774f72f16](https://github.com/home-lang/home/commit/774f72f16).

The substitution guard previously returned the original graph at a recursive
back edge. That edge retained unsubstituted parameters, and its deferral event
prevented completed ancestors from being memoized. Back edges under declaration
parameter maps now retain a pool-owned body, exact parameter identities and
mapped arguments. Consumers resolve the referenced surface through the existing
generic resolver, including structural assignability. Non-parameter rewrites
retain the existing unresolved guard and do not earn completed-result credit.

The first controls retain three negative failures against the preceding source.
Owned-edge controls then pass 4/4. They check independent string/number mappings,
32 shared recursive branches with bounded work, mutual object/callable edges,
readonly/optional members, semantic assignability and mapper ownership transfer.
The creating and consuming checkers need not assign equal template identities;
the mapped recursive surface and each consumer's completed identity must remain
stable.

A subsequent control exposed binder capture in the first reference revision:
a recursive object reached through a generic method lost that method's binder.
The retained run has 4 pass / 1 fail. The active graph now records its lexical
binder-scope entry. A recursive edge excludes signature binders introduced after
that entry, while preserving actual outer arguments. Constraints and defaults
are inside the same binder scope. An initial scope revision has two retained
compile errors and no executed tests. Corrected scope controls pass 5/5, and the
extended constraints/defaults controls pass 6/6.

The first source passes checker 4,506/4,506, driver 200/200, Program 241/241,
opt-in controls 3/3 and survey admission/mismatch controls 10/10. Its compiler
builds at 2,899 MB. Pinned 106-file Zod retains 195 TS diagnostics and three
HM9002 recoveries at 490 MB, with the ceiling unchanged. Normalized diagnostics
match the preceding checkpoint; this is not a passing Zod project.

The first original React attempt is deliberately interrupted with exit 130 to
correct the binder regression. It starts `intraExpressionInferencesJsx`, leaves
`contextuallyTypedStringLiteralsInJsxAttributes02` unstarted and earns no complete
aggregate or passing-case credit. It is not a memory-ceiling measurement.

The corrected source passes checker 4,508/4,508, driver 200/200, Program
241/241, opt-in controls 3/3 and survey admission/mismatch controls 10/10. Its
compiler builds at 2,896 MB. Zod retains 195 TS diagnostics and three HM9002
recoveries at 512 MB, with normalized output unchanged from the first reference
build and the preceding checkpoint.

The corrected original React attempt exits 124 at the unchanged 900-second
wall-clock bound. `intraExpressionInferencesJsx` is unfinished and
`contextuallyTypedStringLiteralsInJsxAttributes02` unstarted. It produces no
complete aggregate or passing-case credit. The timeout path does not report
its final memory peak; sampled footprints are not a replacement for that peak.
This run does not establish completion of the earlier memory-failure case or a
controlled performance improvement across the intervening fixture-input changes.

Samples are phase-qualified: about one minute shows owner-specific type transfer;
about seven minutes shows interface checking, repeated base refresh and UMD
source scans; about ten minutes shows generic constraint comparison dominated by
`relation.Engine.substituteTpDeepLimit`. The engine's separate structural walk
remains a target for correct shared/cyclic graph substitution. Fixtures, declarations, baselines, original skips/TODOs, 900-second
React deadline and resource ceilings remain unchanged. Remaining compiler graph
and declaration policy work is tracked in
[#842](https://github.com/home-lang/home/issues/842), input fidelity in
[#841](https://github.com/home-lang/home/issues/841), complete corpus acceptance
in [#832](https://github.com/home-lang/home/issues/832), and full Bun parity in
[#66](https://github.com/home-lang/home/issues/66).

The manifest records exact source stages, hashes and retained unsuccessful runs.
