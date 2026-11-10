# Object array element oracle (#999)

An array literal whose element target is an *object* type was reported as a
whole value at the variable. TypeScript descends to the innermost node the
syntax allows: into an object literal element's failing property, or onto the
element expression itself when there is nothing deeper to reach.

#996 fixed the array-shaped element target and #1000 the chain for a generic
instance. The remaining case was owned by `arrayLiteralHasObjectElementMismatch`,
a gate that declined per-element reporting whenever the element type was a
concrete object, so the failure elaborated the enclosing assignment instead.

The descent itself did not need writing. `tryReportTupleElementObjectLiteralMismatch`
already did excess, then missing, then the property descent, and was already
byte-exact — it was simply wired only to tuple element targets. The array path
now reuses it, so an array target and a tuple target cannot disagree about
those three cases. The gate is removed rather than narrowed: its knowledge now
lives in the reporter as explicit array, object and tuple element-target cases.

A tuple element target is the one case that must still decline. The positional
pass owns it end to end and reports the innermost element itself, so anything
this reporter adds is a second diagnostic TypeScript does not emit. Removing
the gate without that early return put one back at the inner literal of
`[string, number][]` against `[[1, 2]]`, turning #990, #993 and #996 red — a
tuple's element type is named by `simpleDiagnosticTypeName`, so the display-name
guard does not stop it, and a lowered tuple answers `isActualTupleType` rather
than `isTupleShapedTarget`.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`elements.ts` pins the property descent for a plain object literal, a nested
one, an array inside an object, two failing elements in one literal, and an
optional property; the literal's own TS2741 for a missing property and TS2353
for an excess one; and the element-anchored report with its chain for an
element that is not an object literal, including a generic instance whose
chain #1000 fixed.

The rest are the controls. A tuple element target keeps the single innermost
diagnostic that #990 pinned, at one and two levels of nesting. A source that is
not an array literal has no element to anchor to, so the whole value is still
reported at the variable with the full chain. A matching literal, a matching
nested literal and an omitted optional property are accepted.

[Issue #999](https://github.com/home-lang/home/issues/999) tracks this work.
