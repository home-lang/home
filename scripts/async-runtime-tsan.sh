#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

iterations="${1:-100}"
task_count="${2:-1000000}"
batch_size="${3:-4096}"

for value in "$iterations" "$task_count" "$batch_size"; do
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 [positive-iterations] [positive-task-count] [positive-batch-size]" >&2
    exit 2
  fi
done

zig_bin="${ZIG_BIN:-./pantry/.bin/zig}"
max_mb="${HOME_TEST_MAX_RSS_MB:-1024}"
timeout_seconds="${HOME_ASYNC_STRESS_TIMEOUT_SECONDS:-900}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/home-async-tsan.XXXXXX")"
test_bin="$tmp_dir/async-runtime-stress"
trap 'rm -rf "$tmp_dir"' EXIT

source scripts/home-bin.sh

(
  export HOME_TEST_MAX_RSS_MB="$max_mb"
  export HOME_RUN_LOCK_WAIT="${HOME_RUN_LOCK_WAIT:-300}"
  export HOME_RUN_LABEL="async-runtime-tsan-build"
  run_bounded "$timeout_seconds" "$zig_bin" test \
    -fsanitize-thread \
    --test-no-exec \
    "-femit-bin=$test_bin" \
    --dep async \
    -Mroot=packages/async/tests/runtime_stress.zig \
    --dep threading_futex \
    -Masync=packages/async/src/async.zig \
    -Mthreading_futex=packages/runtime/src/threading/Futex.zig
)

for ((iteration = 1; iteration <= iterations; iteration++)); do
  printf 'async-runtime-tsan: starting run %d/%d (%s tasks, batch %s)\n' \
    "$iteration" "$iterations" "$task_count" "$batch_size"
  (
    export HOME_ASYNC_STRESS_TASKS="$task_count"
    export HOME_ASYNC_STRESS_BATCH="$batch_size"
    export HOME_TEST_MAX_RSS_MB="$max_mb"
    export HOME_RUN_LOCK_WAIT="${HOME_RUN_LOCK_WAIT:-300}"
    export HOME_RUN_LABEL="async-runtime-tsan-$iteration"
    export TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1}"
    run_bounded "$timeout_seconds" "$test_bin"
  )

  if ((iteration % 10 == 0 || iteration == iterations)); then
    printf 'async-runtime-tsan: %d/%d runs passed (%s tasks each)\n' \
      "$iteration" "$iterations" "$task_count"
  fi
done
