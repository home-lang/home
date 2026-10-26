# JavaScript export shapes (#846, #957, #958)

Run `tsc -p tsconfig.json --pretty false` from this directory with
TypeScript 5.7.3. The project admits each JavaScript source through an import
from `main.ts` with `allowJs`, `checkJs`, and `strict` enabled.

String, array, and JSDoc-function exports check the existing whole-export
projection. `map.js` exports an inferred `Map<string, number>`; the wrong
`set` call inside that owner and the wrong call in the TypeScript importer
must both report TS2345. The importer error is at `main.ts(11,21)`.

With `tsconfig.json`, the expected stdout has seven diagnostics in TypeScript
source order, no stderr, and exit code 2. With
`tsconfig-no-checkjs.json`, the six TypeScript-consumer diagnostics remain,
but the owner-side `map.js` error is absent. Imported JS types still constrain
TypeScript consumers when owner diagnostics are disabled. `zig build
test-tsc-streams` asserts both exact TypeScript 5.7.3 streams against Home.
Before #957, Home emits the other diagnostics but misses the importer error
because the collection instance cannot cross the checked-source schema
boundary.

`tsconfig-named-no-checkjs.json` is the ESM named-export control for #958.
The JavaScript owner has only a JSDoc `@param` tag, so its `number` return
is inferred from the body. TypeScript 5.7.3 reports TS2345 at
`named-consumer.ts(2,11)` even with owner diagnostics disabled. The Program
regression checks this in serial and parallel compilation and with both root
orders; the CLI stream asserts the exact diagnostic and exit code.
