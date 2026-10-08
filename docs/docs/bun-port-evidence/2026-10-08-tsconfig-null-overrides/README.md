# TypeScript config null overrides and recovery diagnostics

This checkpoint closes the null-override and malformed-list slice of
[#841](https://github.com/home-lang/home/issues/841). It preserves the
difference between an option that is absent and one that TypeScript converts
to `undefined`, so an `extends` merge no longer revives a parent value that a
child explicitly cleared.

The behavioral oracle was the locally pinned TypeScript **6.0.3** package at
`pantry/typescript`, invoked through
`parseJsonSourceFileConfigFileContent`. The implementation was also compared
with the pinned TypeScript source in the local `typescript-go` checkout.

Implemented here:

- recognized `compilerOptions` values set to JSON `null` are retained as
  explicit unsets, without a diagnostic, and clear inherited values;
- malformed recognized scalar options retain their TypeScript diagnostic and
  also clear the inherited value because conversion produced `undefined`;
- `files`, `include`, and `exclude` set to `null` remain absent and therefore
  inherit their parent lists;
- null elements in string lists are filtered without a diagnostic, while
  other non-string elements emit TS5024 at the offending element;
- valid members of an `extends` array still apply when sibling entries are
  invalid, with one TS5024 per invalid entry;
- an invalid scalar `extends` value is recoverable and emits the same TS5024
  type wording as TypeScript instead of aborting the config parse.

## TypeScript oracle

The same in-memory configs were parsed with TypeScript 6.0.3. The oracle
reported:

- child null compiler options produced an empty options object and no
  diagnostics, while null root lists retained the parent's `index.ts`;
- `extends: ["./base.json", null, 42]` retained the base and emitted TS5024 at
  line 1, columns 30 and 36, each requiring `string`;
- `extends: null` emitted TS5024 at line 1, column 14, requiring
  `string or Array`;
- `files: ["index.ts", null, 42, true]` retained only `index.ts`, silently
  filtered null, and diagnosed the number and boolean elements.

No fixture, expected diagnostic, or resource limit was changed to obtain
these results.

## Guarded verification

Every substantial Home command ran serially through `scripts/run-bounded.pl`
with `HOME_RUN_MAX_MB=3840`.

- complete `tsconfig` package: **138/138** tests passed; peak 222 MB;
- explicit-undefined virtual-config control: **1/1** test passed; peak 210 MB;
- inherited-null compiler-input controls: **2/2** tests passed; peak 297 MB;
- invalid `extends` array diagnostic controls: **2/2** tests passed; peak
  2,133 MB;
- invalid scalar `extends` diagnostic controls: **2/2** tests passed; peak
  2,041 MB;
- named local category regression: **87/87** configured cases passed with no
  failures or skips; peak 2,157 MB.

An unfiltered `ts_conformance` package run was attempted separately. The
supervisor stopped it with exit 125 when tree footprint reached 3,843 MB,
three megabytes above the 3,840 MB ceiling. That attempt is **inconclusive**
and is not represented as a passing package result. The focused controls and
the independently asserted 87-case category gate are the evidence for this
checkpoint.

This is not a complete-corpus claim. Default-library/compiler-API fidelity and
honest unsupported/skip accounting remain open in #841. Complete TypeScript
corpus work remains tracked in
[#832](https://github.com/home-lang/home/issues/832), and full Bun acceptance
remains tracked in [#66](https://github.com/home-lang/home/issues/66).
