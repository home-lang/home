#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

start="${1:-0}"
end="${2:-5907}"
slice_size="${3:-200}"

for value in "$start" "$end" "$slice_size"; do
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "usage: $0 [start] [exclusive-end] [positive-slice-size]" >&2
    exit 2
  fi
done

if ((slice_size == 0 || start >= end)); then
  echo "usage: $0 [start] [exclusive-end] [positive-slice-size]" >&2
  exit 2
fi

zig_bin="${ZIG_BIN:-./pantry/.bin/zig}"
timeout_seconds="${HOME_TS_CONFORMANCE_TIMEOUT_SECONDS:-900}"
max_mb="${HOME_RUN_MAX_MB:-3840}"

# shellcheck source=scripts/home-bin.sh
source "$repo_root/scripts/home-bin.sh"

while ((start < end)); do
  remaining=$((end - start))
  limit="$slice_size"
  if ((remaining < limit)); then
    limit="$remaining"
  fi

  printf 'ts-conformance-exact: START=%d LIMIT=%d\n' "$start" "$limit"
  HOME_TS_CONFORMANCE_FULL=1 \
    HOME_TS_CONFORMANCE_EXACT=1 \
    HOME_TS_CONFORMANCE_START="$start" \
    HOME_TS_CONFORMANCE_LIMIT="$limit" \
    HOME_RUN_MAX_MB="$max_mb" \
    HOME_RUN_LABEL="ts-conformance-exact-$start-$limit" \
    run_bounded "$timeout_seconds" "$zig_bin" build test -Dfilter=ts_conformance

  start=$((start + limit))
done
