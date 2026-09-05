#!/usr/bin/env bash
# Provision the Bun corpus's npm dependencies from its checked-in lockfile.
#
# The corpus is a byte-for-byte copy of Bun's `test/` tree, including its
# package.json and bun.lock. Files that import verdaccio, happy-dom, strip-ansi,
# detect-libc, body-parser and friends abort before their first test until those
# are installed, which reads as a runtime failure when it is a provisioning one.
#
# The install is lockfile-pinned: `--frozen-lockfile` fails rather than resolving
# anything new, so a run either reproduces the pinned tree exactly or tells you
# the lockfile and manifest disagree. bun.lock is tracked; this must never
# rewrite it.
#
# Usage:   scripts/provision-corpus-deps.sh
# Exit 0:  the corpus tree matches its lockfile.
#
# Two `file:` dependencies resolve against Bun's repository layout rather than
# the copied corpus directory:
#
#   bun-plugin-svelte@../packages/bun-plugin-svelte -> packages/runtime/test/packages/...
#   react@../node_modules/react                     -> packages/runtime/test/node_modules/...
#
# In Bun's tree they are siblings of `test/`. Recreate that layout without
# changing the corpus or creating manual symlinks: provision React from the
# checked-in parent lockfile, then materialize the tracked plugin mirror at the
# path named by Bun's manifest. Bun itself owns the ordinary node_modules links.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$ROOT/packages/runtime/test"
CORPUS="$TEST_ROOT/bun-corpus"
PLUGIN_SOURCE="$ROOT/packages/runtime/upstream/packages/bun-plugin-svelte"
PLUGIN_TARGET="$TEST_ROOT/packages/bun-plugin-svelte"

if [[ ! -f "$CORPUS/bun.lock" ]]; then
    echo "provision-corpus-deps: no bun.lock at $CORPUS" >&2
    exit 1
fi
if [[ ! -f "$TEST_ROOT/bun.lock" ]]; then
    echo "provision-corpus-deps: no parent bun.lock at $TEST_ROOT" >&2
    exit 1
fi
if [[ ! -f "$PLUGIN_SOURCE/package.json" ]]; then
    echo "provision-corpus-deps: no bun-plugin-svelte mirror at $PLUGIN_SOURCE" >&2
    exit 1
fi

before="$(git -C "$ROOT" status --porcelain -- packages/runtime/test/bun.lock packages/runtime/test/bun-corpus/bun.lock)"

bun install --cwd "$TEST_ROOT" --frozen-lockfile

mkdir -p "$TEST_ROOT/packages"
rm -rf "$PLUGIN_TARGET"
cp -R "$PLUGIN_SOURCE" "$PLUGIN_TARGET"

bun install --cwd "$CORPUS" --frozen-lockfile

after="$(git -C "$ROOT" status --porcelain -- packages/runtime/test/bun.lock packages/runtime/test/bun-corpus/bun.lock)"

if [[ "$before" != "$after" ]]; then
    echo "provision-corpus-deps: a pinned bun.lock changed during provisioning" >&2
    exit 1
fi

test -f "$TEST_ROOT/node_modules/react/package.json"
test -f "$PLUGIN_TARGET/package.json"
test -f "$CORPUS/node_modules/react/package.json"
test -f "$CORPUS/node_modules/bun-plugin-svelte/package.json"
