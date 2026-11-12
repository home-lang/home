# Inferred export type oracle (#1016)

#1013 gave an importer the checked type of an exported variable whose
initializer the declaration graph cannot project. Several kinds of value were
still opaque, so the importer saw `any` and reported nothing:

- a function with an inferred return type;
- a non-generic standard-library value (`Date`, `RegExp`), and `Error`, which
  was published as its expanded shape;
- a bigint literal;
- a tuple the checker built, readonly or not.

Four changes close them:

- **Functions.** `populateCheckedExportSchemas` publishes a TypeScript
  function's checked signature, through `lowerGenericSignatureInArena` for a
  generic one, as the JavaScript path already did. An overloaded name is
  skipped: its checked type is the implementation signature, which no caller
  sees.
- **Library types by name.** `checked_schema` publishes a type in
  `builtin_object_names` as `builtin_object`, the same reference a syntactic
  annotation produces. The consumer owns the shape, so `Date` displays and
  relates as `Date`.
- **Bigint literals.** The schema has a `bigint` expression holding the
  canonical base-ten digits, so `5n` and `-5n` cross as literals.
- **Tuples.** The checker builds a tuple as an object with positional members
  and a literal `length`. `checked_schema` reads that object back into a
  `tuple`, or into the new `readonly_tuple` when every element is readonly,
  as for `as const`. A rest or variadic tail stays opaque.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 25 lines.

- `owner.ts` exports six library values, two bigint literals, a readonly
  tuple, and functions: generic, plain, async, returning a tuple and an
  object, overloaded, and an arrow. It also exports a class instance.
- `consumer.ts` checks each value against `symbol`, then checks literal
  targets that show the bigints and the tuple keep their literal types. It
  ends with calls that show each function's inferred signature.

Not covered, and why:

- **A named local type reached by inference.** For `const f = mk()` where
  `mk(): Foo`, Home lowers the annotation `Foo` to a structural copy with a
  fresh TypeId. `named_type_by_id` cannot name that copy, so the importer gets
  `{ a: number; }` where TypeScript prints `Foo`. This is tracked in its own
  issue.
- **`[] as const`**, which Home's checker types as `[]` rather than
  `readonly []` in the exporter itself.
- **A literal returned from a function.** `flag ? 1 : undefined` is widened
  to `number | undefined` by TypeScript and kept as `1 | undefined` by Home's
  checker, in the exporter itself.
- **The elaboration of a nested tuple mismatch**, which 5.7.3 and native 7
  word differently.

[Issue #1016](https://github.com/home-lang/home/issues/1016) tracks this work.
