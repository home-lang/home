#!/usr/bin/env bash
# Scan the Bun corpus through the native full-VM path, categorizing each file as
# pass / fail / crash / hang. Writes a TSV to the given out-file.
#
# Usage: vm-corpus-scan.sh <subdir-under-corpus> <out.tsv> [timeout-secs]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_BIN="$ROOT/zig-out/bin/home"
CORPUS="$ROOT/packages/runtime/test/bun-corpus"
SUB="${1:-js/node/path}"
OUT="${2:-/tmp/vm-scan.tsv}"
TO="${3:-15}"

cd "$ROOT"
: > "$OUT"
pass=0 fail=0 crash=0 hang=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  log=$(HOME_NATIVE_VM=1 HOME_CORPUS_FULL_VM=1 timeout "$TO" "$HOME_BIN" test "$rel" 2>&1)
  code=$?
  if [[ $code -eq 124 ]]; then
    status=hang; hang=$((hang+1))
  elif [[ $code -ge 128 ]]; then
    status=crash; crash=$((crash+1))
  elif echo "$log" | grep -qE '^\(fail\)'; then
    status=fail; fail=$((fail+1))
  elif [[ $code -eq 0 ]]; then
    status=pass; pass=$((pass+1))
  else
    # nonzero exit, no parsed (fail) line — abort/crash before tests ran
    status=crash; crash=$((crash+1))
  fi
  # capture a one-line crash signature. For panics/segfaults, prefer the first
  # in-tree (home) stack frame — far more actionable than "Segmentation".
  if [[ "$status" == "crash" ]]; then
    sig=$(echo "$log" | grep -oE '[a-zA-Z0-9_./-]+\.zig:[0-9]+:[0-9]+: 0x[0-9a-f]+ in [^ ]+ \(home\)' | head -1 | sed -E 's/: 0x[0-9a-f]+ in / /; s#packages/runtime/src/##' | cut -c1-110)
    [[ -z "$sig" ]] && sig=$(echo "$log" | grep -oE 'panic: .*|reached unreachable|Segmentation' | head -1 | cut -c1-110)
  else
    sig=$(echo "$log" | grep -oE 'panic: .*|error: .*|TODOError: [^@]*' | head -1 | tr '\t' ' ' | cut -c1-110)
  fi
  printf '%s\t%s\t%s\n' "$status" "$rel" "$sig" >> "$OUT"
done < <(find "$CORPUS/$SUB" -name "*.test.*" | sort)
echo "SUB=$SUB pass=$pass fail=$fail crash=$crash hang=$hang total=$((pass+fail+crash+hang))"
