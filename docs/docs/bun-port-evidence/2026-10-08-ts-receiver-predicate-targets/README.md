# Receiver predicate targets and locations

Source: [0b8d584c1](https://github.com/home-lang/home/commit/0b8d584c1).

A receiver predicate with the same resolved target as its callable signature
could take a separate substitution path when its annotation location differed.
That path rebuilt the signature's local type parameter independently and left
the receiver with a different binder. Target reuse now follows the actual
rebuilt callable target while retaining the receiver's parameter index, assertion
kind and annotation node. Unresolved targets with different nodes still resolve
independently, preserving forward-reference behavior.

Negative controls are retained at their exact stages. The preceding source
passes 2/3 location controls and fails the binder assertion. The first revision
passes those controls, but an added receiver-override control reveals another
binder mismatch (3 pass / 1 fail). The final source passes all 4/4 without
weakening either expectation. Guard/assertion variants, string/number binder
environments, independent unresolved targets and receiver overrides are checked.

Complete checker 4,491/4,491, driver 198/198, Program 234/234, opt-in runner
controls 3/3 and survey admission/mismatch controls 10/10 pass. The standalone
compiler builds at 2,993 MB observed peak. The pinned 106-file Zod corpus retains
196 TS diagnostics and three HM9002 recoveries at 615 MB, with its ceiling
unchanged. Its diagnostics equal the preceding checkpoint after normalizing
only the temporary directory. This recovery check is not a passing project.

The unchanged original React attempt stops at 3,844 MB against the unchanged
3,840 MB ceiling, with exit 125. `intraExpressionInferencesJsx` starts;
`contextuallyTypedStringLiteralsInJsxAttributes02` is unstarted. No complete
aggregate or passing-case credit exists. The original 900-second deadline,
fixtures, declarations, baselines, skips and TODOs remain unchanged.

The retained sample pins remaining repeated work to `decl_single_base`
inheritance-base metadata substitution at `check.zig:166393`, reached during
declaration member lowering. Earlier signature-memo evidence and issue comments
are corrected to name this inheritance path rather than receiver predicates.
The independently reproduced predicate defects are fixed; recursive inheritance
metadata substitution remains unresolved in
[#842](https://github.com/home-lang/home/issues/842). Complete corpus and Bun
acceptance remain open in [#832](https://github.com/home-lang/home/issues/832)
and [#66](https://github.com/home-lang/home/issues/66).

Pins, source/artifact hashes and all negative, successful and unsuccessful
results are retained in `manifest.json` and the accompanying compressed logs.
