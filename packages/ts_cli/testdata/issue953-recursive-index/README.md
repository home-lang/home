# Generic index compatibility (#953)

From this directory, run each file with TypeScript 5.7.3 using
`tsc --strict --noEmit --pretty false FILE.ts`, and with Home using
`home-tsc --ignoreConfig --strict --noEmit --pretty false FILE.ts`.

`compatible.ts` must be clean: a number index value `T` is assignable to
the string index union `T | (() => T)`, including through forward generic
inheritance. `repro.ts` adds a recursive return and must report only TS2542
at line 6; its numeric and numeric-string writes are mutable.
`invalid.ts` is the negative control and must report TS2413 at line 3:
`() => T` is not assignable to `T`. The exact CLI output and exit codes
are asserted by `test-tsc-streams`.
