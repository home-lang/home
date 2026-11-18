# keyof display oracle (#1002)

Since #995, `keyof` over a primitive is resolved, but an error message did not
show the result as TypeScript does. Two separate causes are fixed here, and on
every row of this fixture TypeScript 5.7.3 and native TypeScript 7.0.2 print
the same text, so nothing in it depends on which of the two is the reference.

**A `keyof` annotation printed its own source text.**
`keyofAnnotationNameForIdentifier` returned the annotation's raw characters for
any `keyof X` except `keyof any`, so `keyof   boolean` kept its spacing and
`keyof /* c */ boolean` kept its comment. TypeScript keeps `keyof X` only as the
origin of a key *union* whose operand is a class, an interface, a reference or
an aliased object type. A single key is that literal (`keyof One` is `"a"`), no
key is `never`, and a primitive, an anonymous object or a union operand shows
its keys (`keyof boolean` is `"valueOf"`). The function now applies that rule
and builds the kept name from the operand, and it follows a non-generic alias
whose body is a `keyof`, so `type KS = keyof Shape` displays as `keyof Shape`.

**An alias name was recorded on a type every other use shares.** Literals and
`keyof` results have one identity for every place that produces them, so the
name of `type Lit = "x"` labelled every `"x"` in the program, and
`type KB = keyof boolean` turned an unrelated `keyof (string | number)` into
`KB | "toString"`. TypeScript never shows either alias. There were two writers:
`alias_display_names`, and the type-to-name half of `putTypeName`, which
`namedTypeForId` reads. `aliasResultIsSharedType` now stops the first, and
`putSharedAliasTypeName` registers the name without the reverse entry — keeping
a name an earlier declaration already gave the type.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`display.ts` pins the kept name for an interface, a class, an aliased object, a
generic reference and an alias of a `keyof`, with stray spacing and a comment
in the annotation; and the expanded keys for a single key, no key, a primitive,
an anonymous object and a union operand, at a variable, an array element, a
reassignment and a parameter. It ends with the literal alias that must not be
shown, on its own annotation and on an unrelated one.

Not covered, and why:

- **Member order of a longer union.** TypeScript 5.7.3 prints declaration
  order; native 7.0.2 sorts members by value. Native 7 owns member order (#975).
  `tsconfig-long.json` checks the complete long-key display, including
  TypeScript's `... N more ...` elision, against native 7's text and 5.7.3's
  diagnostic positions and exit status.
- **An alias for a union.** Covered separately by #1003.
- **`keyof (Shape & One)`**, which TypeScript prints as `keyof Shape` because
  the key union was first created under that name.
- **A literal returned against a literal return type.** Covered by #1004.

[Issue #1002](https://github.com/home-lang/home/issues/1002) tracks this work.
