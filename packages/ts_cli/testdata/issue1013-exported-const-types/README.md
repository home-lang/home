# Exported const type oracle (#1013)

An importer saw the inferred type of an exported unannotated variable only for
a few initializer shapes: a bare literal, a parenthesized literal, and objects
and arrays made of plain literals. For anything else it saw `any`, so it
reported nothing. That covered `2 + 3`, a call, `as const`, `-5`, `!0`,
`null`, a template, an arrow function, `new Map()`, an object with a computed
member, a reference to another const, and every unannotated `let`.

The Program publishes each export as a schema built from syntax before any
file is checked (`declaration_graph.zig`, `class_schema.zig`). A shape the
syntax projector cannot write down makes the route `projection_only`, and the
importer never publishes such a route as a type. JavaScript exports already
had a second pass: once a file is checked, its opaque routes take the file's
checked types, and files are checked in dependency order, so every exporter is
ready before its importers.

`populateCheckedExportSchemas` now runs that pass for TypeScript as well. A
`var`, `let` or `const` route whose syntactic projection failed takes the
checked type of its declaration, when `checked_schema` can transfer it
exactly. An exact syntactic schema is left alone. Re-export routes share the
declaration, so they see the same type.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 29 lines.

- `owner.ts` exports 25 values: the issue's eight shapes, other literal,
  object and array shapes, `null`, a template, an arrow function, two `let`s, a
  const alias, `Map`, `Set`, `Promise` and a class instance.
- `consumer.ts` checks each one against `symbol`. It then checks literal
  targets, which show that an imported const keeps its literal type (`-5`,
  `5 as const`, an alias of `5`) while a `let` widens.

Not covered, and why:

- **A non-generic library type** (`new Date()`, `/a/`, `new Error()`). The
  checked schema has no reference to a library interface by name: `Date` and
  `RegExp` stay `any`, and `Error` is published as its expanded shape.
- **A named local type reached by inference**, such as `const f = mk()` where
  `mk(): Foo`. The importer gets `{ a: number; }` where TypeScript prints
  `Foo`, because the call result is a structural copy that Home does not name.
- **A bigint literal** (`5n`) and **a readonly tuple** (`[1, "a"] as const`),
  which the checked schema cannot represent.
- **A function with an inferred return type**, `export function g() { return
  1 }`. Its route is a function, not a variable; it stays opaque.
- **`!0` typed as `boolean`** where TypeScript gives `true`. That is a checker
  gap in the exporter itself, so the literal row is left out.

[Issue #1013](https://github.com/home-lang/home/issues/1013) tracks this work.
