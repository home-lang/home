# Owned transfer scratch and member batches

Source: [bdb366c03](https://github.com/home-lang/home/commit/bdb366c03).

The original React sample in the preceding checkpoint spends its sampled phase
in owner import and type-transfer materialization, including temporary mapped
argument allocation/free. The transfer builder now reuses separate bounded
buffers for type arguments, template text and tuple elements. Each interner
consumer copies these borrowed results into its own storage before the buffer
is reused. Signature parameters are consumed before the same argument buffer
is used for generic binders. Generic definitions also copy their parameter list
before the scratch lifetime ends.

Object finalization reserves the complete member batch once. Name/provenance
callbacks cannot mutate either type pool; callback and allocation failures still
use the existing unpublished-pool rollback. No type, declaration identity,
metadata table, validation or source owner is omitted or deduplicated differently.
The builder releases all scratch buffers on success and every error path.

A 64-row ownership control alternates argument widths and exercises receiver and
constructor signatures, generic binders, tuple optionality, template text and
nested generic references. It destroys the source and changes name callbacks
before validating destination contents. It passes before and after the change.
On this exact control, measured destination allocations fall from 256 to 81;
this is an allocation count for that control, not a whole-compiler performance
or memory-completion claim.

Both transfer selections pass 11/11, including every payload kind, distinct
owner/declaration identities, shared recursive edges, complete generic bodies,
exhaustive allocation-failure rollback, cancellation and malformed-input checks.
The full checker passes 4,527/4,527, driver 200/200, Program 243/243 and opt-in
controls 3/3. The concurrent publication during rebase adds only documentation;
all recorded source hashes still match the published source. The compiler builds
at 3,067 MB; pinned 106-file Zod retains 195 TS diagnostics and three HM9002
recoveries, ceiling unchanged, at 490 MB. Normalized diagnostics match the
preceding checkpoint; Zod is not a passing project. All ten survey admission and
mismatch controls pass.

The unchanged original React selection exits 125 at observed tree footprint
3,849 MB against the unchanged 3,840 MB ceiling. The first fixture is unfinished
and the second unstarted. There is no complete aggregate or passing-case credit.
A sample attempt finds the process already terminal and produces no sample.
The controlled allocation reduction does not establish that owner graph transfer
or the original corpus is complete, and this run earns no green parity credit.

Original fixtures, declarations, expected diagnostics, skips/TODOs, normal lock,
900-second original React deadline and 3,840 MB ceiling remain unchanged. Correct
owner-specific graph transfer and declaration policy remain open in
[#842](https://github.com/home-lang/home/issues/842); input fidelity, complete
corpus and Bun acceptance remain open in
[#841](https://github.com/home-lang/home/issues/841),
[#832](https://github.com/home-lang/home/issues/832) and
[#66](https://github.com/home-lang/home/issues/66).
