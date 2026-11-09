# Named array element oracle (#996)

An array literal assigned to a *named* array target was reported as a whole
value at the variable; TypeScript reports the offending element, exactly as it
does for a bare `number[]`. The name was the only thing that changed the
behaviour.

The cause was a guard in `tryReportArrayLiteralArrayElementMismatch` that
declined per-element reporting whenever the target had a name. Its own comment
explains it in terms of "the first incompatible **spread** element", and the
regression that motivated it — `checker: parity 4451-5250 named array spreads
report whole assignments` — is entirely about spreads. #989 later added the
precise rule for that case, so the broad test on the target's name became
redundant and was removed rather than narrowed.

Two neighbouring defects shared the same shape and are fixed here too.

An **array-shaped element target** (`AliasArray[]`, `number[][]`) fell into
`arrayLiteralHasObjectElementMismatch`, the gate that routes an object-shaped
element failure into the enclosing assignment's elaboration. An array element
type is not that case: TypeScript descends through the nested array literal to
the innermost offending element, whether or not anything along the way is
named. The gate now steps aside for an element type with array provenance, and
the reporter recurses into the nested literal — falling back to the element
itself when the literal declines, as an all-spread one does.

A **non-augmenting interface over an array** (`interface I extends Array<number> {}`)
elaborated through `'number' index signatures are incompatible.`, the wrapper
that belongs to a merely indexed object. tsc collapses a single-base interface
that declares no members of its own to its base, so such an interface *is* an
array and its element types are compared directly, in both directions. Home
already models that collapse as `decl_single_base`; the array case now records
it as array provenance as well. `typeNodeHasArraySyntax` could not answer the
question on its own, because it reads the heritage name through
`bareTypeNodeName`, which declines a type reference carrying arguments — so
`extends Array<number>` has no bare name to match.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`named.ts` pins the element diagnostic for a type alias, an interface
extending `Array<number>`, a readonly alias and a mixed-element literal, with
the bare `number[]` that was already correct as the control. It then pins the
descent through an array-shaped element target — aliased, bare, three levels
deep, and through an interface — and the two cases that stop the descent: an
element that is not an array literal, and one that is an all-spread literal,
each reported where it stands with its own elaboration beneath it.

The interface rows pin both directions of the collapse, including a second
interface that extends the first, against an interface that merely indexes and
therefore keeps the index-signature wrapper.

The rest are the controls the fix must not disturb. An all-spread literal is
still reported as a whole value at the variable, against the named target by
name — including the three-level elaboration for `(string | number)[]` against
`InterfaceArray` — and a fixed element beside a spread keeps the positional
reporting. A tuple element target runs its own positional pass, so descending
into such an element must add nothing: `[string, number][][]` keeps the single
innermost diagnostic that #990 pinned.

[Issue #996](https://github.com/home-lang/home/issues/996) tracks this work.
