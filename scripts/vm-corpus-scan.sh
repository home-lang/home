#!/usr/bin/env bash
# Scan the Bun corpus through the native full-VM path, categorizing each file as
# pass / fail / crash / hang / deps / oom. Writes a TSV to the given out-file.
#
# Every run is bounded in BOTH time and memory (see scripts/home-bin.sh):
# macOS honours no `ulimit` memory cap, so without the resident-set watchdog a
# single runaway file can exhaust the machine.
#
# Usage: vm-corpus-scan.sh <subdir-under-corpus> <out.tsv> [timeout-secs]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/home-bin.sh
source "$ROOT/scripts/home-bin.sh"
resolve_home_bin "$ROOT" || { echo "vm-corpus-scan: no Home binary in $ROOT/zig-out/bin" >&2; exit 1; }
CORPUS="$ROOT/packages/runtime/test/bun-corpus"
SUB="${1:-js/node/path}"
OUT="${2:-/tmp/vm-scan.tsv}"
TO="${3:-15}"

cd "$ROOT"
: > "$OUT"
RUNLOG="$(mktemp -t home-vm-scan.XXXXXX)"
trap 'rm -f "$RUNLOG"' EXIT
pass=0 fail=0 crash=0 hang=0 deps=0 oom=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  # Write to a file rather than capturing through a pipe. A test that leaves a
  # server or installer running keeps the pipe's write end open, so command
  # substitution blocks for that grandchild even after the bound has killed the
  # file's own process group — the scan then wedges on one file forever instead
  # of recording a hang and moving on. Closing stdin stops a child from waiting
  # on a terminal that is not there.
  # Bun's own test launcher exports this before starting a Debug executable.
  # Setting it only from preload.ts is too late for env-omitted child processes:
  # both Home and the pinned Bun control inherit their original process env.
  BUN_DEBUG_QUIET_LOGS=1 HOME_NATIVE_VM=1 HOME_CORPUS_FULL_VM=1 run_bounded "$TO" "$HOME_BIN" test "$rel" >"$RUNLOG" 2>&1 </dev/null
  code=$?
  if [[ $code -eq 124 ]]; then
    status=hang; hang=$((hang+1))
  elif [[ $code -eq 125 ]]; then
    # Killed at the resident-set ceiling rather than finishing. Reported on its
    # own so a memory blow-up is never silently filed as a crash.
    status=oom; oom=$((oom+1))
  elif [[ $code -ge 128 ]]; then
    status=crash; crash=$((crash+1))
  elif grep -qE '^\(fail\)' "$RUNLOG"; then
    status=fail; fail=$((fail+1))
  elif grep -qE "Cannot find package '|Could not resolve: \"|ENOENT while resolving package '|bun install failed with exit code" "$RUNLOG"; then
    # An unresolved npm dependency aborts the file before any test runs. That is
    # the corpus provisioning gap (#618), not a defect in the runtime, and
    # counting it as a crash overstates the crash surface.
    status=deps; deps=$((deps+1))
  elif [[ $code -eq 0 ]]; then
    status=pass; pass=$((pass+1))
  else
    # nonzero exit, no parsed (fail) line — abort/crash before tests ran
    status=crash; crash=$((crash+1))
  fi
  # capture a one-line crash signature. For panics/segfaults, prefer the first
  # in-tree (home) stack frame — far more actionable than "Segmentation".
  if [[ "$status" == "crash" ]]; then
    sig=$(grep -m1 -oE '[a-zA-Z0-9_./-]+\.zig:[0-9]+:[0-9]+: 0x[0-9a-f]+ in [^ ]+ \(home\)' "$RUNLOG" | sed -E 's/: 0x[0-9a-f]+ in / /; s#packages/runtime/src/##' | cut -c1-110)
    [[ -z "$sig" ]] && sig=$(grep -m1 -oE 'panic: .*|reached unreachable|Segmentation' "$RUNLOG" | cut -c1-110)
  else
    sig=$(grep -m1 -oE 'panic: .*|error: .*|TODOError: [^@]*' "$RUNLOG" | tr '\t' ' ' | cut -c1-110)
  fi
  printf '%s\t%s\t%s\n' "$status" "$rel" "$sig" >> "$OUT"
# `*.test.*` also matches sidecars that are not runnable files — `__snapshots__`
# holds `<name>.test.ts.snap`, which the runner reports as a crash. Select the
# executable extensions instead.
done < <(find "$CORPUS/$SUB" \( -name "*.test.js" -o -name "*.test.jsx" -o -name "*.test.mjs" -o -name "*.test.cjs" -o -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.test.mts" -o -name "*.test.cts" \) | sort)
echo "SUB=$SUB pass=$pass fail=$fail crash=$crash hang=$hang deps=$deps oom=$oom total=$((pass+fail+crash+hang+deps+oom))"
