#!/usr/bin/env bash
# Scan the Bun corpus through the native full-VM path, categorizing each file as
# pass / fail / slow / crash / hang / deps / oom / defer. Writes a TSV to the
# given out-file. `defer` means the supervisor never started the file (machine
# lock unavailable, or the host had no room) -- a fact about the host, never a
# verdict on the file.
#
# Every run is bounded in BOTH time and memory (see scripts/home-bin.sh):
# macOS honours no `ulimit` memory cap, so without the resident-set watchdog a
# single runaway file can exhaust the machine.
#
# A file that hits either bound is re-run ONCE at a much higher bound before it
# is recorded. A low bound is what makes a broad scan affordable, but it also
# manufactures failures: `http-backpressure-max` needs ~46s and ~4.8 GB, and
# `worker_heap_snapshot_gc` needs ~42s, so both were filed as hangs purely
# because the first bound was 25s. Escalating only the files that hit a bound
# keeps the scan fast and stops the bound from being mistaken for a defect.
#
# The same correction applies one level down, to the timeouts the corpus sets on
# ITSELF. Those are calibrated for a release build, and a debug Home is several
# times slower on compute-bound fixtures — the pathToFileURL leak fixture runs
# its 256k-iteration loop in 6.0s against a 5s per-test default, so the file
# reports a failure while the property under test (RSS 144 MB against a 250 MB
# limit) is comfortably satisfied. A file whose ONLY failures are per-test
# timeouts is therefore re-run once with a scaled `--timeout` and recorded as
# `slow` if it then passes: still visibly not-a-pass, but not a parity gap
# either. `cp.test.ts`, `abort-signal-leak-read-write-file.test.ts` and
# `pathToFileURL.test.ts` were all this, and all three match pinned Bun exactly
# once the debug build is given time proportional to its slowness.
#
# Usage: vm-corpus-scan.sh <subdir-under-corpus> <out.tsv> [timeout-secs]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/home-bin.sh
source "$ROOT/scripts/home-bin.sh"
resolve_home_bin "$ROOT" || { echo "vm-corpus-scan: no Home binary in $ROOT/zig-out/bin" >&2; exit 1; }
CORPUS="$ROOT/packages/runtime/test/test"
SUB="${1:-js/node/path}"
OUT="${2:-/tmp/vm-scan.tsv}"
TO="${3:-15}"
TRIAGE_RSS="${HOME_TEST_MAX_RSS_MB:-4096}"
# Bounds for the confirmation re-run. A corpus file sets its own timeouts (the
# heap-snapshot test allows itself 120s), so the escalated wall clock has to
# clear those rather than the scan's triage budget.
ESC_TO="${VM_SCAN_ESCALATE_SECS:-180}"
ESC_RSS="${VM_SCAN_ESCALATE_RSS_MB:-6144}"
# Per-test timeout for the timeout-only re-run. Generous on purpose: the point
# is to separate "too slow for a debug build" from "does not pass".
ESC_TEST_TIMEOUT_MS="${VM_SCAN_ESCALATE_TEST_TIMEOUT_MS:-60000}"

cd "$ROOT"
: > "$OUT"
RUNLOG="$(mktemp -t home-vm-scan.XXXXXX)"
trap 'rm -f "$RUNLOG"' EXIT

# Run one corpus file under the given bounds; sets `status` and `sig`.
run_one() {
  local rel="$1" secs="$2" rss="$3" code
  local -a extra=()
  [[ $# -gt 3 ]] && extra=("${@:4}")
  # Write to a file rather than capturing through a pipe. A test that leaves a
  # server or installer running keeps the pipe's write end open, so command
  # substitution blocks for that grandchild even after the bound has killed the
  # file's own process group — the scan then wedges on one file forever instead
  # of recording a hang and moving on. Closing stdin stops a child from waiting
  # on a terminal that is not there.
  # Bun's own test launcher exports BUN_DEBUG_QUIET_LOGS before starting a Debug
  # executable. Setting it only from preload.ts is too late for env-omitted
  # child processes: both Home and the pinned Bun control inherit their
  # original process env.
  BUN_DEBUG_QUIET_LOGS=1 HOME_NATIVE_VM=1 HOME_CORPUS_FULL_VM=1 HOME_TEST_MAX_RSS_MB="$rss" \
    run_bounded "$secs" "$HOME_BIN" test "$rel" ${extra+"${extra[@]}"} >"$RUNLOG" 2>&1 </dev/null
  code=$?
  if [[ $code -eq 124 ]]; then
    status=hang
  elif [[ $code -eq 125 ]]; then
    # Killed at the resident-set ceiling rather than finishing. Reported on its
    # own so a memory blow-up is never silently filed as a crash.
    status=oom
  elif [[ $code -eq 121 || $code -eq 122 ]]; then
    # The supervisor never started the file: the machine lock was unavailable,
    # or the host had no room. That is a fact about the HOST, not about the
    # file, and filing it as a crash invents a defect -- exactly the mistake
    # this scanner keeps having to unlearn.
    status=defer
  elif [[ $code -ge 128 ]]; then
    status=crash
  elif grep -qE '^\(fail\)' "$RUNLOG"; then
    status=fail
  elif grep -qE "Cannot find package '|Could not resolve: \"|ENOENT while resolving package '|bun install failed with exit code" "$RUNLOG"; then
    # An unresolved npm dependency aborts the file before any test runs. That is
    # a corpus provisioning gap (run scripts/provision-corpus-deps.sh), not a
    # defect in the runtime, and counting it as a crash overstates the surface.
    status=deps
  elif [[ $code -eq 0 ]]; then
    status=pass
  else
    # nonzero exit, no parsed (fail) line — abort/crash before tests ran
    status=crash
  fi
  # capture a one-line signature. For panics/segfaults, prefer the first
  # in-tree (home) stack frame — far more actionable than "Segmentation".
  if [[ "$status" == "crash" ]]; then
    sig=$(grep -m1 -oE '[a-zA-Z0-9_./-]+\.zig:[0-9]+:[0-9]+: 0x[0-9a-f]+ in [^ ]+ \(home\)' "$RUNLOG" | sed -E 's/: 0x[0-9a-f]+ in / /; s#packages/runtime/src/##' | cut -c1-110)
    [[ -z "$sig" ]] && sig=$(grep -m1 -oE 'panic: .*|reached unreachable|Segmentation' "$RUNLOG" | cut -c1-110)
  else
    sig=$(grep -m1 -oE 'panic: .*|error: .*|TODOError: [^@]*' "$RUNLOG" | tr '\t' ' ' | cut -c1-110)
  fi
}

# True when every reported failure in the last run was a per-test timeout, so
# the re-run is testing the clock and not papering over a real failure.
timeouts_are_the_only_failures() {
  local failures timeouts
  failures=$(grep -cE '^\(fail\)' "$RUNLOG")
  timeouts=$(grep -cE 'this test timed out after' "$RUNLOG")
  [[ $failures -gt 0 && $failures -eq $timeouts ]]
}

pass=0 fail=0 crash=0 hang=0 deps=0 oom=0 slow=0 defer=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  run_one "$rel" "$TO" "$TRIAGE_RSS"
  # Only a bound-hit is re-run, and only once: every other status is already a
  # real observation, and re-running the whole corpus at the high bound would
  # cost hours.
  if [[ "$status" == hang || "$status" == oom ]]; then
    run_one "$rel" "$ESC_TO" "$ESC_RSS"
  elif [[ "$status" == fail ]] && timeouts_are_the_only_failures; then
    run_one "$rel" "$ESC_TO" "$ESC_RSS" --timeout "$ESC_TEST_TIMEOUT_MS"
    [[ "$status" == pass ]] && status=slow
  fi
  printf '%s\t%s\t%s\n' "$status" "$rel" "$sig" >> "$OUT"
  case "$status" in
    pass) pass=$((pass+1)) ;;
    fail) fail=$((fail+1)) ;;
    crash) crash=$((crash+1)) ;;
    hang) hang=$((hang+1)) ;;
    deps) deps=$((deps+1)) ;;
    oom) oom=$((oom+1)) ;;
    slow) slow=$((slow+1)) ;;
    defer) defer=$((defer+1)) ;;
  esac
# `*.test.*` also matches sidecars that are not runnable files — `__snapshots__`
# holds `<name>.test.ts.snap`, which the runner reports as a crash. Select the
# executable extensions instead.
done < <(find "$CORPUS/$SUB" \( -name "*.test.js" -o -name "*.test.jsx" -o -name "*.test.mjs" -o -name "*.test.cjs" -o -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.test.mts" -o -name "*.test.cts" \) | sort)
echo "SUB=$SUB pass=$pass fail=$fail slow=$slow crash=$crash hang=$hang deps=$deps oom=$oom defer=$defer total=$((pass+fail+slow+crash+hang+deps+oom+defer))"
