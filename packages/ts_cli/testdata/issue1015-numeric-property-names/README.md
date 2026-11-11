# Numeric property name oracle (#1015)

A property declared with a numeric name was displayed by its canonical value,
and `keyof` gave it a string type. Mapped types and `Pick`, `Omit` and `Record`
could not take a number literal key at all.

## Names in diagnostics

TypeScript names a declared property by its declaration's text
(`symbolToString` → `getNameOfSymbolAsWritten` → `declarationNameToString`).
So a missing `1e21` is listed as `1e21`, `0x10` as `0x10` and `1.50` as `1.50`,
and a string-literal name keeps its own quotes: `"a-b"`, `'c'`. Home listed
`'1e+21'`, `'16'` and `'1.5'`. TS2741 printed `'1'` for `1e21` and `'0'` for
`0b11`, because its source scan read only digits and dots.

`objectMemberDeclaredNameText` now reads the member's whole name token from
its declaration, skips modifiers, and checks that the token names the member.
TS2741, the TS2739 list and `Types of property '…'` use it. A member that no
declaration names, such as a mapped type's, follows
`getNameOfSymbolFromNameType`: a numeric name is bare.

## Number literal keys

`getLiteralTypeFromPropertyName` gives a name written as a numeric literal its
number literal type, so `keyof { 1: string }` is `1`. A quoted `"1"` stays the
string `"1"`. `memberNameKeyType` does the same for `keyof`.

Before, `keyof I` was all strings. `Pick<I, 1>` then failed its `keyof I`
constraint (TS2344), and `f(1)` for `K extends keyof I` failed with TS2345. A
mapped type over `1 | 2` was `unknown`, because only string literal keys were
collected. Its key `P` is now the number, as in `resolveMappedTypeMembers`, and
`Pick`, `Omit` and `Record` collect number literal keys too.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 23 lines.

- `names.ts` pins missing members written in exponent, hexadecimal, binary and
  fractional form, and as double- and single-quoted strings. It covers an
  interface, a type literal and a class, the `Types of property` line, and
  mapped members with number and numeric-string keys.
- `keys.ts` pins `keyof` for numeric, quoted, exponential and hexadecimal
  names; `Exclude` over it; a `keyof`-constrained call; a mapped type over
  number keys and over `keyof`; and `Pick`, `Omit` and `Record` with a number
  key.

Not covered, and why:

- **Order of a union of keys.** 5.7.3 and native 7 order `keyof` and
  missing-member lists differently (`2 | 1` against `1 | 2`). Native 7 owns
  order (#975), so every row here has one member or a fixed order.
- **`keyof I` displayed by its name.** TypeScript prints `keyof I2` where Home
  expands the union. That is #994's class.
- **A member declared in another file.** Home reads the spelling from the
  current file's source only, so an imported member falls back to the old
  quoting.
- **A string-named mapped member** such as `"a-b"`. TypeScript double-quotes
  it; Home keeps its single-quote fallback, which other paths still rely on.

[Issue #1015](https://github.com/home-lang/home/issues/1015) tracks this work.
