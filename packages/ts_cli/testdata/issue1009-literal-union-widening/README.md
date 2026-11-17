# Literal union source widening (#1009)

When every member of a failed assignment source is a literal or unit,
TypeScript reports its primitive base against a target that cannot be a
singleton. The relation still explains the failing union member; if all
members widen to one primitive, that explanation can repeat the primitive
line. A union containing a broad `symbol` stays written as declared. A target
containing literal types keeps the source literals.

Native TypeScript 7.0.2 owns the deterministic union member order (#975).
The oracle audit checks the same diagnostic codes and locations against tsc
5.7.3, then compares the full text with native 7.0.2. Run either compiler
from this directory with `-p tsconfig.json --pretty false --noEmit`.

[Issue #1009](https://github.com/home-lang/home/issues/1009) tracks this work.
