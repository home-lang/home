# Anonymous object diagnostics (#971)

The 11-, 12-, and 20-property controls compare TypeScript 5.7.3's TS2339 display with Home. The first remains fully expanded; the latter two elide the middle after the type-node display budget while retaining the final property. The names and types are deliberately uniform so the fixture isolates declaration order and elision rather than member lookup.

Run the exact CLI comparison through `scripts/tests/compare-issue846-oracles.mjs` after building `home-tsc`.
