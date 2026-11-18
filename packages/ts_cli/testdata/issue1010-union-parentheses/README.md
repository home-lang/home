# Union member parentheses (#1010)

Function and constructor members retain their enclosing parentheses when an
annotation is rendered in a diagnostic, including the first and last member.
Enum names beside literals remain bare. The fixture covers callable members in
the first, middle, and last positions, a constructor at the last and middle
positions, and an enum beside a string literal.

Native TypeScript 7.0.2 owns the diagnostic stream because it sorts union
members deterministically. TypeScript 5.7.3 reports the same errors with a
different member order. See [issue #1010](https://github.com/home-lang/home/issues/1010).
