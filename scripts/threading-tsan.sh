#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

iterations="${1:-100}"
if [[ ! "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [positive-iteration-count]" >&2
  exit 2
fi

zig_bin="${ZIG_BIN:-./pantry/.bin/zig}"

for ((iteration = 1; iteration <= iterations; iteration++)); do
  if ! output="$("$zig_bin" test \
      -fsanitize-thread \
      --dep threading_futex \
      -Mroot=packages/threading/src/threading.zig \
      -Mthreading_futex=packages/runtime/src/threading/Futex.zig 2>&1)"; then
    printf '%s\n' "$output" >&2
    exit 1
  fi

  if ((iteration % 10 == 0 || iteration == iterations)); then
    printf 'threading-tsan: %d/%d runs passed\n' "$iteration" "$iterations"
  fi
done
