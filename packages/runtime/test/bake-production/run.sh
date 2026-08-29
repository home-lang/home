#!/usr/bin/env bash
set -euo pipefail

home_exe=$1
fixture_dir=$(cd "$(dirname "$0")/fixture" && pwd)
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/home-bake-production.XXXXXX")
trap 'rm -rf "$tmp_root"' EXIT

cp -R "$fixture_dir/." "$tmp_root/"
cd "$tmp_root"

BUN_DEV_SERVER_TEST_RUNNER=1 "$home_exe" build --app ./app.ts --outdir ./dist >build.log 2>&1

test "$(cat dist/index.html)" = '{"page":"Home Bake works","params":null}'
test "$(cat dist/alpha/index.html)" = '{"page":{"DEV":false,"PROD":true,"MODE":"production","SSR":true,"STATIC":true},"params":{"slug":"alpha"}}'
test "$(cat dist/beta/index.html)" = '{"page":{"DEV":false,"PROD":true,"MODE":"production","SSR":true,"STATIC":true},"params":{"slug":"beta"}}'
grep -q '^done$' build.log
test -d dist/_bun
test -n "$(find dist/_bun -type f -print -quit)"
test ! -e _bun

if BUN_DEV_SERVER_TEST_RUNNER=1 "$home_exe" build --app ./missing.ts >missing.log 2>&1; then
  echo "expected a missing Bake config to fail" >&2
  exit 1
fi
grep -q "could not resolve application config file './missing.ts'" missing.log
