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
# KNOWN INCOMPLETE: two `file:` dependencies resolve against Bun's own repository
# layout, not the copied corpus's, and cannot be satisfied by an install here:
#
#   bun-plugin-svelte@../packages/bun-plugin-svelte -> packages/runtime/test/packages/...
#   react@../node_modules/react                     -> packages/runtime/test/node_modules/...
#
# In Bun's tree those are `<bun>/packages/bun-plugin-svelte` and
# `<bun>/node_modules/react`, siblings of `test/`. Home keeps the corpus at
# packages/runtime/test/bun-corpus/, so both paths point at directories that do
# not exist. Home does mirror the plugin at
# packages/runtime/upstream/packages/bun-plugin-svelte. Wiring the two without a
# symlink or a corpus edit — both excluded by the acceptance criteria — is the
# remaining work in home-lang/home#618.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS="$ROOT/packages/runtime/test/bun-corpus"

if [[ ! -f "$CORPUS/bun.lock" ]]; then
    echo "provision-corpus-deps: no bun.lock at $CORPUS" >&2
    exit 1
fi

before="$(git -C "$ROOT" status --porcelain -- packages/runtime/test/bun-corpus/bun.lock)"
cd "$CORPUS"
bun install --frozen-lockfile
code=$?
after="$(git -C "$ROOT" status --porcelain -- packages/runtime/test/bun-corpus/bun.lock)"

if [[ "$before" != "$after" ]]; then
    echo "provision-corpus-deps: bun.lock changed; the corpus lockfile is upstream's and must stay byte-identical" >&2
    exit 1
fi
exit $code
