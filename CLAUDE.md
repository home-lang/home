# Claude Code Guidelines

## About

Home is a modern programming language for systems, apps, and games that combines the speed of Zig, the safety of Rust, and the joy of TypeScript. The compiler is built with Zig and produces native x64 code, with features including pattern matching, generics, async/await, comptime evaluation, null safety operators, and error handling via Result types. Source files use `.home` or `.hm` extensions, and the project includes a lexer, parser, type system with inference, and a standard library with HTTP server and database modules.

## Bun parity (TS→JS transpiler / runtime)

- Home maintains Bun's engine for them (they moved to Rust). The **source of truth is Bun's official Zig at `~/Code/bun`** — when implementing TS→JS lowering or runtime parity, READ the corresponding Bun code (e.g. `src/js_printer/js_printer.zig`, `src/js_parser/`, `src/ast/`) and mirror its shape rather than reinventing or guessing. The TS→JS printer lives in `packages/ts_emit/src/js_emit.zig`.
- Diagnostic parity (`TSxxxx`) is checked against the pinned typescript-go source at `_submodules/typescript-go`; TS→JS *emit* parity is checked against Bun.

## TypeScript diagnostic parity

- When emitting `TSxxxx` diagnostic codes for parity, **only implement codes in the REACHABLE set** — codes the reference compiler (typescript-go) actually emits. About half the `catalog-only` rows in `docs/TS_DIAGNOSTIC_CODE_STATUS.md` are **dead** (obsolete/superseded wording tsgo never produces, e.g. TS6015→TS6705); emitting those is anti-parity, not progress.
- Pick work from `docs/TS_DIAGNOSTIC_REACHABILITY.md` (regenerate with `node scripts/gen-ts-reachability.mjs`). Do not chase dead codes to inflate the ledger.

## Linting

- Use **pickier** for linting — never use eslint directly
- Run `bunx --bun pickier .` to lint, `bunx --bun pickier . --fix` to auto-fix
- When fixing unused variable warnings, prefer `// eslint-disable-next-line` comments over prefixing with `_`

## Frontend

- Use **stx** for templating — never write vanilla JS (`var`, `document.*`, `window.*`) in stx templates
- Use **crosswind** as the default CSS framework which enables standard Tailwind-like utility classes
- stx `<script>` tags should only contain stx-compatible code (signals, composables, directives)

## Dependencies

- **buddy-bot** handles dependency updates — not renovatebot
- **better-dx** provides shared dev tooling as peer dependencies — do not install its peers (e.g., `typescript`, `pickier`, `bun-plugin-dtsx`) separately if `better-dx` is already in `package.json`
- If `better-dx` is in `package.json`, ensure `bunfig.toml` includes `linker = "hoisted"`

## Commits

- Use conventional commit messages (e.g., `fix:`, `feat:`, `chore:`)
