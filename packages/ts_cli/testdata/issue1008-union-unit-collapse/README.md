# Complete union unit display (#1008)

TypeScript prints a complete boolean member run as `boolean` and all members
of one enum as the enum name. A partial enum remains a union of member names.
The fixture checks those cases alone and alongside unrelated union members,
plus a one-member enum and a local enum shadowing one at module scope.

Native TypeScript 7.0.2 owns the deterministic union member order (#975).
The oracle audit checks the same diagnostic codes and locations against tsc
5.7.3, then compares the full text with native 7.0.2. Run either compiler
from this directory with `-p tsconfig.json --pretty false --noEmit`.

[Issue #1008](https://github.com/home-lang/home/issues/1008) tracks this work.
