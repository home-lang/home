#1030: catch bindings shadow outer write targets

Both a direct catch parameter and a destructured catch parameter bind the
assignment target inside the catch block. The outer annotated variable does
not constrain those writes. `scripts/tests/compare-issue846-oracles.mjs`
checks the exact diagnostic stream against TypeScript 5.7.3.
