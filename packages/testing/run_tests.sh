#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

exec "$repo_root/pantry/.bin/zig" build \
    --build-file "$script_dir/build_tests.zig" \
    test "$@"
