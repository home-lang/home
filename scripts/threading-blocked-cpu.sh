#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

iterations="${1:-5}"
if [[ ! "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [positive-iteration-count]" >&2
  exit 2
fi

zig_bin="${ZIG_BIN:-./pantry/.bin/zig}"

for ((iteration = 1; iteration <= iterations; iteration++)); do
  printf 'blocked-waiter-cpu: run=%d/%d\n' "$iteration" "$iterations"
  "$zig_bin" run \
    -lc \
    --dep threading \
    -Mroot=packages/threading/tests/blocked_cpu.zig \
    --dep threading_futex \
    -Mthreading=packages/threading/src/threading.zig \
    -Mthreading_futex=packages/runtime/src/threading/Futex.zig
done
