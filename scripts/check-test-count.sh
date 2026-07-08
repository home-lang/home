#!/usr/bin/env bash
# check-test-count.sh — gate PRs on test pass-count not regressing.
#
# Runs Pantry-pinned `zig build test --summary all`, sums every "+- run test N pass (M total)"
# line into a single pass-count, and compares it against the committed baseline
# in docs/test-baseline.txt. Exits non-zero if current < baseline.
#
# v0 strategy (intentionally simple):
#   - Gate on the *total* passing-test count across the whole Pantry Zig `build test`
#     umbrella, not on a conformance subset. When the conformance suite gets a
#     dedicated Pantry Zig `build test-conformance` step, swap the command below and
#     point the script at docs/conformance-baseline.txt.
#   - The baseline is a single integer in docs/test-baseline.txt. To raise it
#     after intentionally adding tests, commit a new value in that file in the
#     same PR — reviewers will see the bump explicitly.
#
# Usage (local):
#   ./scripts/check-test-count.sh
#
# Wired from .github/workflows/ci.yml as the `test-count-gate` job.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline_file="${repo_root}/docs/test-baseline.txt"
log_file="${repo_root}/test-summary.log"
count_file="${repo_root}/test-count.txt"
expected_zig_version="0.17.0-dev.1275+59a628c6d"
zig_bin="${repo_root}/pantry/.bin/zig"

if [[ ! -x "${zig_bin}" ]]; then
  echo "error: Pantry Zig not found at ${zig_bin}; run 'pantry install' first" >&2
  exit 2
fi

actual_zig_version="$("${zig_bin}" version 2>/dev/null || true)"
if [[ "${actual_zig_version}" != "${expected_zig_version}" ]]; then
  echo "error: unsupported Zig version '${actual_zig_version}' at ${zig_bin}" >&2
  echo "expected Pantry Zig ${expected_zig_version}" >&2
  exit 2
fi

if [[ ! -f "${baseline_file}" ]]; then
  echo "error: baseline file not found at ${baseline_file}" >&2
  exit 2
fi

baseline="$(tr -d '[:space:]' < "${baseline_file}")"
if ! [[ "${baseline}" =~ ^[0-9]+$ ]]; then
  echo "error: baseline file does not contain a positive integer: '${baseline}'" >&2
  exit 2
fi

echo "Running ${zig_bin} build test --summary all ..."
# Capture both stdout and stderr; tolerate non-zero exit (we want the partial
# count even if a single test executable fails to compile, so we can report
# the regression with a useful number rather than dying silently).
set +e
"${zig_bin}" build test --summary all >"${log_file}" 2>&1
zig_exit=$?
set -e

# Sum every "+- run test N pass (M total)" line. Robust to test names and
# whitespace variations because we anchor on the literal "+- run test " prefix.
current="$(grep -oE '\+\- run test [0-9]+ pass \([0-9]+ total\)' "${log_file}" \
  | awk '{ sum += $4 } END { print (sum ? sum : 0) }')"

echo "${current}" > "${count_file}"

echo "Pass count: current=${current} baseline=${baseline} (zig exit=${zig_exit})"

if [[ "${current}" -lt "${baseline}" ]]; then
  echo "::error::Test pass-count regressed: ${current} < baseline ${baseline}." >&2
  echo "If this regression is intentional (e.g. a flaky test removed), update" >&2
  echo "docs/test-baseline.txt in the same PR with the new lower count." >&2
  exit 1
fi

if [[ "${zig_exit}" -ne 0 ]]; then
  # Pass count held, but the build itself returned non-zero (e.g. a single
  # test executable failed to compile). The umbrella Pantry Zig `build test`
  # in build-and-test-home already gates overall build health, so we only
  # warn here — this script's narrow job is regression-detection on the
  # passing count, and that count is intact.
  echo "::warning::Pantry Zig build test exited ${zig_exit}, but pass count holds." \
       "build-and-test-home covers overall build health; not failing the gate."
fi

if [[ "${current}" -gt "${baseline}" ]]; then
  echo "Note: pass count exceeds baseline by $((current - baseline)). Consider" \
       "bumping docs/test-baseline.txt in a follow-up PR to lock in the gain."
fi
