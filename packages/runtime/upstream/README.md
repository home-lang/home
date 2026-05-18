# `packages/runtime/upstream/` — Bun source mirror

> **Verbatim mirror of `~/Code/bun/`** at upstream SHA `fd0b6f1a271fca0b8124b69f230b100f4d636af6` (matches `packages/runtime/UPSTREAM_SHA.txt`). Snapshot date: **2026-05-17**.
>
> **This directory is reference-only.** Nothing here is compiled by `zig build` and no Home subsystem imports from this tree. It exists so the porting effort (see `docs/TS_PARITY_PLAN.md` §12) can proceed without needing a checkout of `~/Code/bun/` on every machine.

## What's mirrored

| Path | Source | Why mirrored |
|---|---|---|
| `src/` | `~/Code/bun/src/` (106 MB, 4640 files) | The Zig + Rust + C/C++ runtime we're porting incrementally into `packages/runtime/src/`. |
| `packages/` | `~/Code/bun/packages/` (15 MB) | Bun's npm-published subpackages — `@types/bun`, `bun-error`, `bun-inspector-protocol`, `bun-lambda`, plus the `bun-native-bundler-plugin-api` + `bun-native-plugin-rs` SDK we'll port for plugin parity. |
| `scripts/` | `~/Code/bun/scripts/` (1.7 MB) | Codegen + build scripts (`auto-close-duplicates.ts`, `run-clang-format.sh`, `gen-ts-diag-codes.pl`, etc.). Referenced by the workflow ports in `docs/TS_PARITY_PLAN.md` §12.18. |
| `test/` | `~/Code/bun/test/` (69 MB) | The full Bun test corpus. **This is the 100 % acceptance gate per `packages/runtime/README.md`** — once feature-complete, every test here must pass via `home test`. |
| `completions/` | shell completion installers | Will fold into `home`'s completion story. |
| `misctools/` | `~/Code/bun/misctools/` | Internal dev tools (`fetch.zig`, `hash.zig`, etc.). |
| `patches/` | `~/Code/bun/patches/` | Patches Bun applies to vendored deps (libuv, BoringSSL, JSC, …). Required when we build the same deps natively per §12.0.11. |
| `dockerhub/` | `~/Code/bun/dockerhub/` | Bun's Docker image build recipes. Reference for `release.yml`. |
| `docs/` | `~/Code/bun/docs/` | Bun's user docs (Astro-built). Reference for our own runtime docs. |
| `bench/` | `~/Code/bun/bench/` | Bun's benchmark corpus. Should also pass once the runtime hits feature-complete. |
| Top-level | `LICENSE.md`, `CLAUDE.md`, `AGENTS.md`, `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `package.json`, `tsconfig.base.json`, `tsconfig.json`, `bunfig.toml` | License / convention / toolchain pins. |

## What's NOT mirrored

- `.git/` — git history takes hundreds of MB and isn't relevant.
- `node_modules/`, `target/`, `build/`, `zig-cache/`, `.zig-cache/` — derived/build artifacts.
- `vendor/` if absent in upstream — Home builds vendored deps itself per §12.0.11.

## How this relates to `packages/runtime/src/`

The directory _next to_ this one — `packages/runtime/src/` — is the **curated, ported, compiling** Home runtime. Files there carry an MIT attribution banner, have inline tests, are wired through `packages/runtime/src/home_rt.zig`, and use `@import("home_rt")` instead of `@import("bun")`. As porting progresses, more files in `upstream/src/` get matching curated copies under `runtime/src/`.

Rough rule for agents porting a file:
1. Read the original from `upstream/src/<path>/<file>.zig` (don't reach outside the repo).
2. Apply the copy convention from `packages/runtime/README.md` (banner, import rewrite, JSC-bridge omissions, inline test, Zig 0.17 compat).
3. Write the curated copy to `packages/runtime/src/<path>/<file>.zig`.
4. Wire it into `packages/runtime/src/home_rt.zig`.
5. The mirror under `upstream/` is left untouched as the source of truth.

## License

Bun is MIT-licensed; the full text lives in `LICENSE.md` (mirrored). Every curated copy under `packages/runtime/src/` reproduces the MIT notice in its banner. This is a sanctioned vendoring of MIT-licensed source — see `packages/runtime/README.md` for the project-level convention.

## Snapshot refresh

To refresh the mirror to a newer Bun upstream:

```sh
cd ~/Code/Home/lang
# Update the pinned SHA
echo "<new-sha>" > packages/runtime/UPSTREAM_SHA.txt
# Re-mirror
rsync -a --delete \
  --exclude='.git' --exclude='node_modules' \
  --exclude='zig-cache' --exclude='.zig-cache' \
  --exclude='target' --exclude='build' \
  ~/Code/bun/{src,packages,scripts,test,completions,misctools,patches,dockerhub,docs,bench} \
  packages/runtime/upstream/
cp ~/Code/bun/{LICENSE.md,CLAUDE.md,AGENTS.md,Cargo.toml,Cargo.lock,rust-toolchain.toml,package.json,tsconfig.base.json,tsconfig.json,bunfig.toml} \
  packages/runtime/upstream/
```

Then re-verify the affected ports under `packages/runtime/src/` against any upstream changes. The `UPSTREAM_SHA.txt` pin guards against silent drift.
