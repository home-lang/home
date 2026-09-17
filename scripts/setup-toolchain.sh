#!/usr/bin/env bash
#
# Install the toolchain this repo builds with.
#
#   ./scripts/setup-toolchain.sh
#
# Pantry owns the native toolchain pin: `ziglang.org` in pantry.json resolves to
# ./pantry/.bin/zig, which is what the `build:compiler` and `test:compiler`
# scripts invoke. Bun owns the JS/TS dev tooling (pickier, tsc, bunpress).
#
# Safe to re-run; both installers are idempotent.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

echo "==> installing JS/TS dev dependencies (bun)"
bun install || echo "WARNING: bun install failed; pickier/tsc may be unavailable"

# `ts-pantry install` takes an explicit package rather than reading the
# manifest, so feed it every pin from pantry.json's `dependencies`. That keeps
# the pinned version in one place instead of duplicating it here.
deps=$(bun --print 'Object.entries(require("./pantry.json").dependencies ?? {}).map(([n, v]) => `${n}@${v}`).join(" ")')
if [ -z "$deps" ]; then
  echo "ERROR: pantry.json declares no dependencies to install" >&2
  exit 1
fi

echo "==> installing pinned native toolchain (pantry): $deps"
# shellcheck disable=SC2086 -- deps is an intentional space-separated list
if ! bunx --bun ts-pantry install $deps; then
  cat >&2 <<'MSG'

ERROR: pantry could not install the pinned Zig toolchain.

If the output above shows "HTTP 403" or a CONNECT/tunnel failure, the fault is
the sandbox egress policy rather than pantry or the pin itself. Pantry needs
BOTH of these hosts reachable:

  ziglang.org          upstream dev/master tarballs
  registry.pantry.dev  pantry's mirror of pruned dev builds

In a restricted environment (Claude Code on the web, CI sandboxes, corporate
proxies) allowlist both, then re-run this script. Until then `zig build` and
`zig build test` cannot run.
MSG
  exit 1
fi

if [ -x pantry/.bin/zig ]; then
  echo "==> zig ready: $(pantry/.bin/zig version)"
  echo "    add it to PATH for this shell with:"
  echo "      export PATH=\"\$PWD/pantry/.bin:\$PATH\""
else
  echo "ERROR: pantry reported success but pantry/.bin/zig is missing" >&2
  exit 1
fi
