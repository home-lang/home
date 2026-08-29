#!/bin/sh
set -eu

workspace=${HOME_BENCH_WORKSPACE:-/work}
runner="$workspace/bench/vs_tsgo/run.py"
home_compiler=${HOME_TSC:-$workspace/zig-out/bin/home-tsc}

if [ ! -f "$runner" ]; then
    echo "benchmark repository is not mounted at $workspace" >&2
    exit 1
fi
if [ ! -x "$home_compiler" ]; then
    echo "native Linux ReleaseFast home-tsc is missing or not executable: $home_compiler" >&2
    exit 1
fi

export HOME_TSC="$home_compiler"
cd "$workspace"
python3 "$runner" setup
python3 "$runner" corpus
exec python3 "$runner" "$@"
