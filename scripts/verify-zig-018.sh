#!/usr/bin/env bash
# Reproduce the Zig 0.18 CI gate for the migrated production surfaces.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

expected_version="0.18.0-dev.146+35accc06e"
actual_version="$(zig version)"
if [[ "${actual_version}" != "${expected_version}" ]]; then
    echo "error: expected Zig ${expected_version}, found ${actual_version}" >&2
    exit 2
fi

# This is a separate migration gate, not a substitute for the pinned 0.17
# compiler/runtime test suite. Each command must succeed; none is optional.
zig build home-tsc -j1
zig build test -Dfilter=basics_crypto -j1 --summary all
zig build --build-file packages/io/build.zig check -j1
zig build --build-file packages/io/build.zig test -j1 --summary all
zig build --build-file packages/build/build.zig check -j1
zig build --build-file packages/build/build.zig test -j1 --summary all
