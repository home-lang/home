# Template literal placeholder oracle (#1011)

A template literal type folded a string literal placeholder into its text and
nothing else. `` `${1}` `` stayed a template with a numeric placeholder, which
matches every numeric string, so `const n: `${1}` = "2"` passed; `` `${1n}` ``
was printed as written; `` `${1 | 2}` `` accepted `"3"`.

TypeScript builds the type with `getTemplateLiteralType`, and Home now does
the same in `buildTemplateLiteralType`, for a written template literal type
and for an instantiated one:

- **Every literal placeholder becomes text** (`getTemplateStringForType`): a
  number as JavaScript prints it (`-1`, `0.5`, `0.1`, `1e+21`, `1e-7`, `16`
  for `0x10`, `0` for `-0`), a bigint without its `n`, `true`, `false`, `null`, `undefined`, and
  an enum member by its value. A literal beside a placeholder that stays joins
  the text around it, so `` `a${1}${number}` `` is `` `a1${number}` ``.
- **A union of literals is spread** into a union of results, as is `boolean`:
  `` `${1 | 2}` `` is `"1" | "2"`. That includes a union of string literals,
  which used to stay a placeholder. Spreading only some unions made equal
  types unequal: `` `a${"x" | "y"}${boolean}`` `` spread over `boolean` did
  not relate to `` `a${"x" | "y"}${"false" | "true"}` `` kept whole.
- **No alias names the result.** `getTemplateLiteralType` takes no alias, so
  `type U = `${1 | 2}`` displays as `"1" | "2"` and `F<1>` for
  `type F<T> = `${T}`` as `"1"`. Recording `F<1>` on the shared literal `"1"`
  would have labelled every `"1"` in the program.

The number formatting of the instantiation path changed with it: it printed
`1e21` as all of its digits.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 24 lines.

`placeholder.ts` pins a numeric literal alone, between text, negative,
negative zero, fractional, exponential in both directions and hexadecimal; a
bigint literal;
`true`, `null` and `undefined`; a numeric and a string enum member; a union of
numeric literals, written and through an alias; an instantiation with a
number, a bigint, a union and a boolean; the matching string accepted for
each; and `` `${number}` `` beside a folded literal.

Not covered, and why:

- **Member order of a spread union.** TypeScript 5.7.3 and native 7 print a
  spread union in different orders; native 7 owns order (#975), so those rows
  are in `issue975-union-member-order/template.ts`.
- **A whole enum as a placeholder** (`` `${E}` ``), which TypeScript spreads
  over the enum's members. Home models an enum type as one nominal type, not a
  union of its members.
- **A nested template literal placeholder**, which TypeScript splices into the
  outer one.

[Issue #1011](https://github.com/home-lang/home/issues/1011) tracks this work.
