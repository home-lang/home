#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fake="$root/scripts/tests/fixtures/runtime-capability-fake.sh"
runner="$root/scripts/runtime-regression.sh"

check() {
    local mode="$1" expected_status="$2" expected_text="$3" output status
    if output="$(HOME_BIN="$fake" HOME_FAKE_MODE="$mode" bash "$runner" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -ne "$expected_status" || "$output" != *"$expected_text"* ]]; then
        printf 'mode=%s: expected status %s and %s; got status %s and output:\n%s\n' \
            "$mode" "$expected_status" "$expected_text" "$status" "$output" >&2
        exit 1
    fi
}

check query-fail 1 'native VM capability query failed'
check disabled 0 'non-JSC build; skipping'
check invalid-response 1 'invalid native VM capability response'
check probe-fail 1 'native VM probe failed'
check probe-no-marker 1 'native VM probe returned no success marker'
check probe-marker-then-fail 1 'native VM probe failed'

if output="$(HOME_BIN="$root/scripts/tests/fixtures/not-a-binary" bash "$runner" 2>&1)"; then
    printf 'nonexistent explicit HOME_BIN was incorrectly accepted:\n%s\n' "$output" >&2
    exit 1
fi
if [[ "$output" != *'explicit HOME_BIN is not executable'* ]]; then
    printf 'nonexistent explicit HOME_BIN reported the wrong failure:\n%s\n' "$output" >&2
    exit 1
fi

printf 'runtime-regression capability controls passed\n'
