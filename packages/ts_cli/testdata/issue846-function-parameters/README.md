# Imported optional and rest JSDoc parameters (#846)

The two configurations pin the exact TypeScript 5.7.3 CLI stream with
`allowJs` enabled and `checkJs` on or off. The JavaScript owner exports a
function with one required and one optional argument, plus a function with a
rest string argument. The TypeScript consumer exercises valid calls, too few
and too many arguments, wrong optional and rest argument types, and wrong
return-type assignments.

Both configurations produce the same six importer diagnostics. Turning off
owner checking does not erase the imported function signatures. This fixture
tests these function forms, not every JSDoc parameter grammar.
