# keyof over a non-object operand (#995)

`keyof` over a primitive, a literal, a union of literals or a template literal
accepted any key at all, because the checker only evaluated `keyof` for an
object operand and left everything else as a symbolic `keyof X` that nothing
constrained. TypeScript reads such an operand's keys from its apparent type:
`keyof string` is `keyof String`, `keyof 1` is `keyof Number`.

`keyofApparentSurface` now maps a primitive or literal to that surface at the
top of each key collector, so the collectors' existing union branch gives a
union of primitives its common keys. It is deliberately not
`indexValueApparentType`, which tests `flags.is_string` without a union guard
— a union header carries its members' flags, so that test answers `String` for
`string | number` as a whole.

The annotation path also had its own copy of `keyof` evaluation that had
drifted from `keyofTypeFromOperand`: it handled `any` but not `never`,
`unknown`, `null`, `undefined` or `void`, so `keyof unknown` accepted any key.
It now delegates.

Three surface details had to be right for the result to carry exactly
TypeScript's keys, or a valid key would have become a new error:

- `String`'s members are those of #1001, plus a `[Symbol.iterator]` keyed by
  its unique symbol rather than a `"Symbol.iterator"` string literal.
- `String`'s `readonly [index: number]: string` contributes `number`. That key
  is added by `keyof` itself rather than by giving the synthesized proto the
  index: Home models `T[]` structurally as `{ length; [n: number]: T }`, so the
  index on the shared proto made `string` assignable to `string[]`, which
  `issue846-generic-revision` caught.
- `Number` gained `toLocaleString`, which it had only through the `Object`
  prototype fallback.

`keyof (A | B)` is `keyof A & keyof B` for index keys as well as members, so
each union member's index keys now join its candidate set before the
intersection — `String`'s `number` must not survive `keyof (string | number)`.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`keyof.ts` pins every valid key against each operand kind — so no valid key
became an error — together with the `unknown` and `any` extremes and the
symbolic `keyof T` of a genuine type parameter.

What it does not pin, and why: the rejection of an *invalid* key against a
primitive's `keyof` is covered by the checker's unit tests rather than here,
because Home does not yet display that target as TypeScript does. It renders
`'keyof string'` where TypeScript expands the union, and the member order of
an expanded lib-derived union follows TypeScript's internal type allocation
(#975). `keyof symbol` and `keyof bigint` stay symbolic: their surfaces lack
keys TypeScript has, so resolving them would reject a valid key. `keyof
boolean` still accepts `"toString"`, which Home's `Boolean` carries and
TypeScript's does not.

[Issue #995](https://github.com/home-lang/home/issues/995) tracks this work.
