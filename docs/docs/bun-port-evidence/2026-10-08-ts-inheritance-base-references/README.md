# Mapped inheritance base references

Source: [4656fcaf3](https://github.com/home-lang/home/commit/4656fcaf3).

Object substitution previously traversed each complete inheritance-base graph
again while copying declaration metadata. It now retains a pool-owned generic
reference containing the exact source body, declaration-parameter identities
and mapped arguments. Member-order recovery, relation normalization, builtin
Function classification and private-class assertions resolve the base surface
when they consume it. Non-parameter rewrites retain the general substitution
path. No mapper pointer escapes its scope.

Relocated checked metadata now imports inheritance and display-base links as
well as tuple links. A control releases the creating mapper, transfers checked
metadata and resolves the mapped base through a new checker. Other controls
check independent string/number arguments, deferred eight-level inheritance
metadata, own-before-inherited ordering and zero-own-member normalization.

The first revision exposed two real lifetime defects: resolving a base could
relocate the pool beneath a borrowed member slice, and interning an object from
another object's pooled members could read freed storage. Consumers now borrow
members after resolution, and object interning snapshots inputs that borrow its
own pool before growth. A direct control forces pool relocation and verifies
the original and copied member descriptors.

Baseline controls retain 2 pass / 1 fail. The initial revision retains one
failure and one crash. Final owned-base controls pass 4/4 and the pooled-member
control passes 2/2 without weakened expectations. Pre-integration checker,
driver and Program suites pass 4,495/4,495, 198/198 and 234/234.

After rebasing onto the concurrently published ambient-enum and export-worklist
changes, the combined tree passes checker 4,497/4,497, driver 199/199, Program
237/237, opt-in controls 3/3 and all ten survey admission/mismatch controls.
The standalone compiler builds at 3,021 MB observed peak. Pinned 106-file Zod
retains three HM9002 recoveries with the ceiling unchanged, at 487 MB, and reports
195 TS diagnostics. Its diagnostic text changes from the preceding checkpoint;
the normalized diff is retained. This is not a passing Zod project.

Subsequent integration controls on the source tree at
[ab5d774e4](https://github.com/home-lang/home/commit/ab5d774e4) pass
4,501/4,501 checker, 199/199 driver, 238/238 Program and 3/3 opt-in controls.
The compiler builds at 3,047 MB; pinned Zod retains 195 TS diagnostics and three
HM9002 recoveries at 534 MB. Its normalized output matches the first inheritance
reference build, which differs from the preceding 196-diagnostic checkpoint.

After the later fixture-configuration and upstream-variant integration at
[773ca888f](https://github.com/home-lang/home/commit/773ca888f), final opt-in
controls pass 3/3 at 2,035 MB and survey admission/mismatch controls pass 10/10.
These controls do not establish a complete original-corpus aggregate. The React
attempt and diagnostic replay below belong to source 4656fcaf3; they were not
remeasured on the later fixture-harness source.

The original React attempt stops at 3,842 MB against the unchanged 3,840 MB
ceiling. A diagnostic replay on the same source, run to capture the remaining
work, stops at 3,844 MB. Both exit 125 while processing
`intraExpressionInferencesJsx`; `contextuallyTypedStringLiteralsInJsxAttributes02`
is unstarted. Neither produces a complete aggregate or passing-case credit.
The replay sample places remaining work in structural member/union substitution
during generic interface instantiation. It no longer shows eager inheritance-base
metadata substitution as the dominant sampled call.

Original fixtures, declarations, expected diagnostics, skips, TODOs, 900-second
deadline and resource ceilings remain unchanged. Correct shared/cyclic type
graphs and faithful declaration-check policy remain open in
[#842](https://github.com/home-lang/home/issues/842); complete corpus and Bun
acceptance remain open in [#832](https://github.com/home-lang/home/issues/832)
and [#66](https://github.com/home-lang/home/issues/66).

The manifest records exact source stages and hashes. Negative controls, crash,
successful gates, resource stops, diagnostic diff and sample are retained.
