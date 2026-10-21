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
# `enable_jsc`, default true on macOS, false elsewhere). An explicit build
# capability query permits a skip only for non-JSC builds. A JSC-enabled build
# whose native runtime fails the probe must fail the suite, not silently skip.
#
# Usage:   scripts/runtime-regression.sh
# Exit 0:  all runtime tests passed, OR the build has no JS runtime (skipped).
# Exit 1:  the runtime is present and one or more tests failed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Locate the Home binary: an explicit override, else the newest build present.
# shellcheck source=scripts/home-bin.sh
source "$ROOT/scripts/home-bin.sh"
if ! resolve_home_bin "$ROOT"; then
    if [[ -n "${HOME_BIN:-}" ]]; then
        echo "runtime-regression: explicit HOME_BIN is not executable" >&2
        exit 1
    fi
    HOME_BIN=""
fi

if [[ -z "$HOME_BIN" || ! -x "$HOME_BIN" ]]; then
    echo "runtime-regression: no Home binary found (looked for zig-out/bin/home[-debug]); skipping" >&2
    exit 0
fi

# A debug build writes its [sys]/[fs]/[loop] trace to the SAME stdout the tests
# read back. Several of these tests spawn the binary and JSON.parse its output,
# so without this the trace is prepended to every payload and the file fails on
# a syntax error that has nothing to do with the runtime — 14 of 69 in one run,
# all of them phantom. Bun's own test launcher exports this before starting a
# Debug executable; do the same, and export it so spawned children inherit it.
export BUN_DEBUG_QUIET_LOGS="${BUN_DEBUG_QUIET_LOGS:-1}"
# This suite is evidence for Home's embedded runtime, never for a delegated
# system Bun. Export the gate before the capability probe so every invocation,
# including children spawned by a fixture, stays on Home's native VM.
export HOME_NATIVE_VM=1

TEST_DIR="$ROOT/tests/runtime"
shopt -s nullglob
tests=("$TEST_DIR"/*.test.mjs)
if [[ ${#tests[@]} -eq 0 ]]; then
    echo "runtime-regression: no tests/runtime/*.test.mjs found; nothing to do"
    exit 0
fi

# Ask the Home binary whether JSC was linked. A failed JS probe cannot answer
# this question: a broken enabled runtime must fail the suite, not skip it.
if ! capability="$("$HOME_BIN" --home-internal-native-vm-capability 2>&1)"; then
    echo "runtime-regression: native VM capability query failed: $capability" >&2
    exit 1
fi
case "$capability" in
    disabled)
        echo "runtime-regression: non-JSC build; skipping ${#tests[@]} test(s)"
        exit 0
        ;;
    enabled) ;;
    *)
        echo "runtime-regression: invalid native VM capability response: $capability" >&2
        exit 1
        ;;
esac

# Probe the actual native JS path and executable identity before running tests.
PROBE="$(mktemp -t home-rt-probe.XXXXXX).mjs"
trap 'rm -f "$PROBE"' EXIT
printf 'import { realpathSync } from "node:fs";\nif (realpathSync(process.execPath) !== realpathSync(process.env.HOME_RUNTIME_EXPECTED_BIN)) throw new Error("runtime delegated outside Home");\nconsole.log("__home_rt_probe_ok__");\n' > "$PROBE"
if ! probe_out="$(HOME_RUNTIME_EXPECTED_BIN="$HOME_BIN" "$HOME_BIN" run "$PROBE" 2>&1)"; then
    echo "runtime-regression: native VM probe failed: $probe_out" >&2
    exit 1
fi
if [[ "$probe_out" != *"__home_rt_probe_ok__"* ]]; then
    echo "runtime-regression: native VM probe returned no success marker: $probe_out" >&2
    exit 1
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
