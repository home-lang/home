# Number literal display oracle (#1014)

A number literal type in exponent form printed with all of its digits:
`1e21` printed as `1000000000000000000000` and `1.5e-7` as `0.00000015`.
Display used Zig's `{d}`, which never switches to exponent form.

TypeScript prints a number literal type as JavaScript's
`Number.prototype.toString` writes the number, and names a numeric property
key the same way. Home now has one formatter for that, `number_literal.zig`.
It replaces the private `formatCanonicalNumber` that template literal text
used, and every `{d}` that turned a number into JavaScript text: type display,
diagnostic names, property keys, enum keys and template substitutions.

- **Exponent form** from `1e21` up and below `1e-6`, with a `+` on a positive
  exponent: `1e+21`, `1.5e-7`, `1.7976931348623157e+308`, `5e-324`.
- **Shortest round-trip digits** otherwise. A whole number above 2^53 prints
  those digits padded with zeros, not its exact value: `2 ** 60` is
  `1152921504606847000`.
- **`-0` is `0`**, also in a template literal: `` `${-0}` `` is `"0"`.

Two key paths first converted a whole number to a 64-bit integer: a property
key for any value below 1e21, and an enum key for any value at all. That
conversion is illegal behavior in Zig above about 9.2e18. Both now go through
the formatter.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 16 lines.

`display.ts` pins exponent form at both ends of the range and at the largest
and smallest numbers, positive and negative, through an annotation and a
`const`; plain digits just below `1e21`, above 2^53, at `0.000001` and for a
fraction; and the same text inside a template literal under `as const`, for
`1e21` and `-0`, and in an `as const` tuple.

Not covered, and why:

- **A property declared with a numeric name**, such as `interface I { 1e21:
  string }`. TypeScript lists a missing one as written (`1e21`, `0x10`,
  `1.50`). Home lists the canonical value in quotes (`'1e+21'`, `'16'`,
  `'1.5'`), and TS2741 prints `'1'` for `1e21`. `keyof` over such properties
  gives string literals where TypeScript gives number literals. Both predate
  this change, and they are tracked in their own issue.

[Issue #1014](https://github.com/home-lang/home/issues/1014) tracks this work.
