# Union member order oracle (#975)

The order in which a union's members are printed is taken from **native
TypeScript 7.0.2**, not from TypeScript 5.7.3. This is the one place the two
references are deliberately split, decided on 2026-11-11.

TypeScript 5.7.3 prints members in the order their types were first allocated.
That is not a property of the program being checked: #975 found
`number[] | string[]` and `string[] | number[]` for the same source depending
only on `skipLibCheck`, because lib checking allocates array types earlier.
Home has no lib files to allocate from, so it could only imitate that order by
accident. Native TypeScript 7 sorts members deterministically (`CompareTypes`
in `_submodules/typescript-go/internal/checker/utilities.go`), and Home applies
the same comparison wherever a union is displayed:

1. **By kind**, in this order: `string`, `number`, `bigint`, `symbol`; string
   literals; numeric literals; `boolean` and the boolean literals;
   `unique symbol`; enum members; object types; template literal types; string
   mapping types such as `Uppercase<string>`. `null` and `undefined` are
   printed last.
2. **A named type by its name**, so `Alpha | Zed` and
   `Date | Map<string, number> | Set<string>`, and a named type before an
   unnamed one. An array counts as `Array` and a readonly array as
   `ReadonlyArray`, so `number[] | readonly string[]`.
3. **Within one kind by its data**: string literals by value, numeric literals
   by value, enum members by where they are declared rather than by name
   (`Color.Red | Color.Green`), arrays and other instances of one generic by
   their type arguments (`string[] | number[]`, `Box<string> | Box<number>`),
   template literal types by their text. A tuple sorts after other unnamed
   object types, and among tuples a mutable one first, then by length, then by
   elements.
4. Otherwise by creation order.

The same order decides which member an explanation line names: the first
member, in displayed order, that fails.

Run native TypeScript 7.0.2 (`bench/vs_tsgo/.tools/tsgo`) and Home from this
directory with `-p tsconfig.json --pretty false --noEmit`. The
`test-tsc-streams` step lists this config in `nativeOrderConfigs`: stdout and
stderr are compared exactly against native 7, the exit status against
TypeScript 5.7.3 (native 7 exits 1 where 5.7.3 and Home exit 2, #982), and the
step fails unless both TypeScript versions report the same diagnostics at the
same positions — so only the spelling of a union can differ, and here it does
on 41 of the 61 output lines.

- `order.ts` pins literal, primitive, array and named-type order at a
  variable, a parameter, a reassignment, an array element and an object
  property, on the target side and the source side.
- `nested.ts` pins the same order for a union inside a generic argument, an
  array, a tuple, a function type, an object type, a return type and a
  nullable union, and the order of enum members for an enum declared at the
  top level, in a namespace and in a function.
- `kinds.ts` pins tuples, instances of one generic, `boolean` beside literals
  and `symbol`, template literal types, a string mapping type, built-in
  generics by name, a tuple beside named and unnamed object types, a nullable
  annotation on the source side, a `unique symbol`, and the keys of `number`
  and `bigint` at a variable, an array element and a parameter (#1002).

Not covered, and why — none of these is an order, and on each one TypeScript
5.7.3 and native 7 agree with each other against Home:

- **`boolean` and a complete enum inside a longer union.** TypeScript prints
  `1 | boolean` and `"s" | Shade`; Home prints `1 | true | false` and
  `"s" | Shade.Dark | Shade.Light`. The members are in the right order and are
  not collapsed.
- **Parentheses around a union member.** Home prints `"s" | (Color)` for an
  enum beside a literal, and drops the outer parenthesis of a parenthesized
  function type at either end of a union annotation of three or more members.
- **`Array<T>` written in the union annotation of a source**, which Home
  prints as written and TypeScript prints as `T[]`.
- **A union of literals as the source of a failure**, which TypeScript widens
  (`"a" | boolean` is reported as `string | boolean`).
- **A `bigint` literal, or an enum member reached through a namespace
  (`NS.Color.Blue`), as an annotation**, where Home reports nothing.
- **`keyof string` and `keyof symbol`.** Home prints all of `keyof string`'s
  keys where TypeScript elides the middle (`... 34 more ...`), and one
  `unique symbol` for `keyof symbol` where TypeScript prints two (#1002).
- **A JavaScript constructor function used as a base class.** Native 7 no
  longer accepts one, so there is no native output to compare.

[Issue #975](https://github.com/home-lang/home/issues/975) tracks this work.
