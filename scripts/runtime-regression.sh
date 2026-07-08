#!/usr/bin/env bash
# Real-runtime regression tests.
#
# Runs every tests/runtime/*.test.mjs through the Home binary's JS runtime
# (`home run <file>`) and asserts a clean exit. These exercise the embedded
# JavaScriptCore runtime end-to-end (real sockets, real event loop) — the paths
# the native corpus runner cannot reach because it runs under a restricted JSC
# bootstrap with no real network.
#
# The JS runtime is only linked when the build is JSC-enabled (build.zig:
# `enable_jsc`, default true on macOS, false elsewhere). On a non-JSC build the
# `home run` path is absent, so this runner PROBES first and SKIPS cleanly
# (exit 0) when the runtime is unavailable — it must never break CI on a target
# that legitimately has no JS runtime. Where the runtime IS present it gates
# hard: any test that exits non-zero fails the run.
#
# Usage:   scripts/runtime-regression.sh
# Exit 0:  all runtime tests passed, OR the build has no JS runtime (skipped).
# Exit 1:  the runtime is present and one or more tests failed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Locate the Home binary. Prefer an explicit override, then a release build,
# then the debug build.
HOME_BIN="${HOME_BIN:-}"
if [[ -z "$HOME_BIN" ]]; then
    for cand in "$ROOT/zig-out/bin/home" "$ROOT/zig-out/bin/home.exe" "$ROOT/zig-out/bin/home-debug"; do
        if [[ -x "$cand" ]]; then HOME_BIN="$cand"; break; fi
    done
fi

if [[ -z "$HOME_BIN" || ! -x "$HOME_BIN" ]]; then
    echo "runtime-regression: no Home binary found (looked for zig-out/bin/home[-debug]); skipping" >&2
    exit 0
fi

TEST_DIR="$ROOT/tests/runtime"
shopt -s nullglob
tests=("$TEST_DIR"/*.test.mjs)
if [[ ${#tests[@]} -eq 0 ]]; then
    echo "runtime-regression: no tests/runtime/*.test.mjs found; nothing to do"
    exit 0
fi

# Probe: can this build actually run JS? A non-JSC build has no `run` runtime.
PROBE="$(mktemp -t home-rt-probe.XXXXXX).mjs"
trap 'rm -f "$PROBE"' EXIT
printf 'console.log("__home_rt_probe_ok__");\n' > "$PROBE"
probe_out="$("$HOME_BIN" run "$PROBE" 2>/dev/null || true)"
if [[ "$probe_out" != *"__home_rt_probe_ok__"* ]]; then
    echo "runtime-regression: build has no JS runtime (non-JSC target); skipping ${#tests[@]} test(s)"
    exit 0
fi

echo "runtime-regression: JS runtime available ($HOME_BIN); running ${#tests[@]} test(s)"
pass=0
fail=0
failed=()
for t in "${tests[@]}"; do
    name="$(basename "$t")"
    if "$HOME_BIN" run "$t" >/tmp/runtime-regression.log 2>&1; then
        pass=$((pass + 1))
        echo "ok    $name"
    else
        fail=$((fail + 1))
        failed+=("$name")
        echo "FAIL  $name"
        sed 's/^/      /' /tmp/runtime-regression.log
    fi
done

echo
echo "runtime-regression: $pass ok, $fail failed"
if [[ $fail -gt 0 ]]; then
    printf '  failed: %s\n' "${failed[@]}"
fi
exit $(( fail > 0 ? 1 : 0 ))
