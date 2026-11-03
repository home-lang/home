# Checked JavaScript constructor imports (#968)

Compare this project with physical TypeScript 5.7.3 using the same `allowJs`,
`checkJs`, `strict`, and `noEmit` settings. The imported generic constructor
instantiates instance members; an inferred fixed member remains fixed. A
JavaScript function's `prototype` remains dynamic when read from the imported
value, including for non-generic constructors. The two deliberate assignment
errors keep the emitted CLI diagnostics observable in the exact-stream audit.
