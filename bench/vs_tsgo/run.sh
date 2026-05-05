#!/usr/bin/env bash
# bench/vs_tsgo/run.sh — corpus + benchmark driver.
#
# Per TS_PARITY_PLAN §0 Phase 0.6 / §6.4.
#
# Usage:
#   ./run.sh corpus     # materialize the pinned workloads
#   ./run.sh cold       # run cold typecheck benches across all workloads
#   ./run.sh watch      # run watch-rebuild benches
#   ./run.sh all        # corpus + cold + watch
#   ./run.sh report     # render the latest results into a Markdown table
#
# Phase 0.6 status: the runner is fully functional for tsc + tsgo; the
# `home` column is skipped until Phase 1 lands `home tsc`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS_DIR="$HERE/corpus"
RESULTS_DIR="$HERE/results/$(date -u +%Y%m%dT%H%M%SZ)"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "missing required command: $1"
}

cmd_corpus() {
  require_cmd git
  mkdir -p "$CORPUS_DIR"
  step "Materializing corpus into $CORPUS_DIR"
  # Phase 0.6 skeleton: real implementation reads SHAs from corpus.toml
  # and `git clone --depth 1 --branch <sha>` each. For now, we just
  # report what we *would* do so the harness wiring is verifiable
  # without burning bandwidth on every `./run.sh corpus`.
  python3 "$HERE/compare.py" --plan-corpus "$HERE/corpus.toml"
}

cmd_cold() {
  require_cmd hyperfine
  mkdir -p "$RESULTS_DIR"
  step "Running cold-typecheck suite into $RESULTS_DIR"

  for workload in typescript vscode twenty_crm playwright ts_toolbelt_consumer; do
    local wdir="$CORPUS_DIR/$workload"
    if [[ ! -d "$wdir" ]]; then
      printf '  \033[33mskip:\033[0m %s (not in corpus; run ./run.sh corpus)\n' "$workload"
      continue
    fi
    for compiler in tsc tsgo home; do
      if ! command -v "$compiler" >/dev/null 2>&1; then
        printf '  \033[33mskip:\033[0m %s/%s (binary not found)\n' "$workload" "$compiler"
        continue
      fi
      local out="$RESULTS_DIR/$workload-$compiler.json"
      step "$workload × $compiler — $out"
      hyperfine --warmup 1 --runs 5 \
        --export-json "$out" \
        --command-name "$compiler $workload" \
        "$compiler --noEmit -p $wdir" || true
    done
  done

  step "Done. Render with: ./run.sh report"
}

cmd_watch() {
  step "Watch-rebuild bench (Phase 0.6 placeholder)"
  printf 'Watch harness scaffolding lives at tests/watch/ and is\n'
  printf 'driven from there once Phase 5 wires the query DB into the\n'
  printf 'compiler driver. This subcommand is reserved.\n'
}

cmd_report() {
  require_cmd python3
  local latest
  latest="$(ls -1d "$HERE"/results/*/ 2>/dev/null | tail -1 || true)"
  if [[ -z "$latest" ]]; then
    err "no results directory found; run ./run.sh cold first"
  fi
  step "Rendering report from $latest"
  python3 "$HERE/compare.py" "$latest"
}

case "${1:-help}" in
  corpus)  cmd_corpus ;;
  cold)    cmd_cold ;;
  watch)   cmd_watch ;;
  report)  cmd_report ;;
  all)     cmd_corpus && cmd_cold && cmd_report ;;
  *)
    cat <<EOF
usage: $0 <command>

Commands:
  corpus    materialize the pinned workloads into corpus/
  cold      run cold-typecheck benches across all workloads
  watch     run watch-rebuild benches (reserved; Phase 5)
  report    render the latest results into a Markdown table
  all       corpus + cold + report

See bench/vs_tsgo/README.md for details.
EOF
    exit 1
    ;;
esac
