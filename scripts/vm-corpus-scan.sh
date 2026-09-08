#!/usr/bin/env bash
# Scan strict-name Bun test files through the native full-VM path.
# Preserve exactly one attempt and its complete log per file. Supervisor bounds
# produce incomplete observations (time_bound / memory_bound / defer), never
# compatibility verdicts. The caller can choose a suitable bound before a run;
# the scanner never retries, escalates it or changes original test deadlines.
#
# TSV columns are status, path, signature, log path, and exit code.
# Output includes an adjacent .logs directory. Existing output is never
# overwritten. Nonzero exit means at least one file failed or was incomplete.
# This remains a triage tool: strict-name discovery is not full pinned CI
# discovery, and an exit-zero script does not establish assertion coverage.
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
cd "$ROOT"
if [[ -e "$OUT" || -e "$OUT.logs" ]]; then
  echo "vm-corpus-scan: refusing to overwrite $OUT or $OUT.logs" >&2
  exit 1
fi
mkdir "$OUT.logs" || exit 1
(set -o noclobber; : > "$OUT") || exit 1
RUNLOG=""

# Run one corpus file under the given bounds; sets `status` and `sig`.
run_one() {
  local rel="$1" secs="$2" code
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
  BUN_DEBUG_QUIET_LOGS=1 HOME_NATIVE_VM=1 HOME_CORPUS_FULL_VM=1 \
    run_bounded "$secs" "$HOME_BIN" test "$rel" >"$RUNLOG" 2>&1 </dev/null
  code=$?
  run_exit_code=$code
  if [[ $code -eq 124 ]]; then
    status=time_bound
  elif [[ $code -eq 125 ]]; then
    # The supervisor ended the run at its resource bound. This is incomplete
    # execution, not proof of a runtime out-of-memory defect.
    status=memory_bound
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
    # A nonzero exit alone proves failure, not a crash.
    status=fail
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

pass=0 fail=0 crash=0 time_bound=0 deps=0 memory_bound=0 defer=0 index=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  printf -v RUNLOG '%s.logs/%06d.log' "$OUT" "$index"
  index=$((index+1))
  run_one "$rel" "$TO"
  printf '%s\t%s\t%s\t%s\t%d\n' "$status" "$rel" "$sig" "$RUNLOG" "$run_exit_code" >> "$OUT"
  case "$status" in
    pass) pass=$((pass+1)) ;;
    fail) fail=$((fail+1)) ;;
    crash) crash=$((crash+1)) ;;
    time_bound) time_bound=$((time_bound+1)) ;;
    deps) deps=$((deps+1)) ;;
    memory_bound) memory_bound=$((memory_bound+1)) ;;
    defer) defer=$((defer+1)) ;;
  esac
# `*.test.*` also matches sidecars that are not runnable files — `__snapshots__`
# holds `<name>.test.ts.snap`, which the runner reports as a crash. Select the
# executable extensions instead.
done < <(find "$CORPUS/$SUB" \( -name "*.test.js" -o -name "*.test.jsx" -o -name "*.test.mjs" -o -name "*.test.cjs" -o -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.test.mts" -o -name "*.test.cts" \) | sort)
echo "SUB=$SUB pass=$pass fail=$fail crash=$crash time_bound=$time_bound deps=$deps memory_bound=$memory_bound defer=$defer total=$index"
if [[ "$index" -eq 0 || "$((fail+crash+time_bound+deps+memory_bound+defer))" -ne 0 ]]; then
  exit 1
fi
