# packages/parser/src/parsers/

Per-construct subparsers extracted from the monolithic
`packages/parser/src/parser.zig` (6 554 LOC at the start of Phase 0.7).

Per [`docs/TS_PARITY_PLAN.md`](../../../../docs/TS_PARITY_PLAN.md) §0
Phase 0.7 ("split parser.zig into per-construct modules; pure
lift-and-extract, no behavior change").

## Status

Phase 0.7 lands the **directory + extraction pattern + first
module** (`precedence.zig`). The remaining sections are scheduled as
Phase 0.7-followups, each landing as a separate PR with the parser
test suite as the regression gate.

## Planned splits

Roughly tracked against the line ranges of the monolith at the start
of the refactor (line numbers will drift):

| Module | Source range (original) | Status |
|---|---|---|
| `precedence.zig` | 63–120 (`Precedence` enum + `fromToken`) | ✅ Phase 0.7 — extracted |
| `helpers.zig` | 239–540 (peek / advance / check / match / expect / isAtEnd) | ⬜ |
| `attributes.zig` | 582–930 (parseAttributes + attribute helpers) | ⬜ |
| `declarations.zig` | 932–1700 (functionDeclaration, type-aliases, …) | ⬜ |
| `types.zig` | 1701–2441 (parseTypeAnnotation, parseTypeString) | ⬜ |
| `patterns.zig` | 2442–3625 (parsePattern, anonymous types) | ⬜ |
| `statements.zig` | 3626–3691 (blockStatement + stmt drivers) | ⬜ |
| `expressions.zig` | 3692–3845 (Pratt parser entry + parsePrecedence) | ⬜ |
| `constant_folding.zig` | 3846–4612 (foldIntegerBinary + friends) | ⬜ |
| `match_expr.zig` | 4613–5800 (parseMatchValue + parseMatchExprPattern) | ⬜ |
| `closures.zig` | already in `../closure_parser.zig` | (move into this dir) |
| `traits.zig` | already in `../trait_parser.zig` | (move into this dir) |
| `asm.zig` | already in `../asm_parser.zig` | (move into this dir) |

## Refactor protocol

For each new extraction:

1. Create the new module file under this directory.
2. Move the function/type into it verbatim, adjusting only imports.
3. Add a `pub usingnamespace` re-export to `parser.zig` if external

   callers reference the symbol; otherwise import directly.

4. Run `zig build test`. Block the PR if any pre-existing parser test

   regresses.

5. Update the table above.

## Why we're doing this gradually

The monolith has 24+ public methods and many implicit
cross-references between sections (e.g., expression parsing
reaches into the function-declaration section to handle anonymous
function expressions). A clean split requires understanding each
section's true dependency graph, which is high-risk to do all at
once. Phase 0 unblocks Phase 1 (TS frontend) by establishing the
_pattern_; the full split is mechanical follow-up work that can run
concurrently with Phase 1.
