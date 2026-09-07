#!/usr/bin/env bash
# Shared helpers for scripts that exercise a built Home binary.
#
# Sourced, not executed. Provides:
#   resolve_home_bin   -> sets HOME_BIN to the binary to test
#   run_bounded SECS … -> runs a command under a wall-clock bound

# Pick the binary to test. An explicit HOME_BIN always wins; otherwise take the
# NEWEST build present rather than a fixed release-before-debug order. A build
# tree accumulates binaries from different Bun artifact generations, and the
# older one silently reports failures that belong to the artifacts it was linked
# against, not to the code under test — a stale release binary beside a fresh
# debug build turns a green run into a wall of unrelated module-resolution
# errors.
resolve_home_bin() {
    if [[ -n "${HOME_BIN:-}" ]]; then
        [[ -x "$HOME_BIN" ]] || { echo "home-bin: HOME_BIN=$HOME_BIN is not executable" >&2; return 1; }
        return 0
    fi
    local root="$1" cand
    HOME_BIN=""
    for cand in "$root/zig-out/bin/home" "$root/zig-out/bin/home.exe" "$root/zig-out/bin/home-debug"; do
        [[ -x "$cand" ]] || continue
        if [[ -z "$HOME_BIN" || "$cand" -nt "$HOME_BIN" ]]; then HOME_BIN="$cand"; fi
    done
    [[ -n "$HOME_BIN" ]]
}

# Memory ceiling for a bounded run, in MB, covering the run's whole process
# tree. This is phys_footprint (the kernel ledger's dirty-memory total), NOT
# resident-set size -- see the long note at the top of scripts/run-bounded.pl
# for why RSS is the wrong quantity on macOS and how it took the host down
# twice. HOME_TEST_MAX_RSS_MB is still honoured as the old spelling.
# Deliberately NOT defaulted or exported here. The supervisor owns the default,
# so a caller that sets the ceiling per-run (the corpus scanner's escalated
# re-run, say) is not shadowed by a value this file exported at source time --
# which would have silently discarded every per-run ceiling.

# Run a command under the machine lock with a wall-clock and a memory bound,
# using timeout's exit conventions: 124 on the time bound, 128+signal when it
# dies on one, else its own code. Additionally 125 for the memory bound, 121
# when the machine lock could not be taken, and 122 when the host had no room
# to start.
#
# There is deliberately no unguarded branch. The previous version fell back to
# coreutils `timeout` whenever the memory cap was zero, which meant the one
# knob that looked like "no memory limit" also silently removed the process-tree
# cleanup and the machine lock. Every path goes through the supervisor.
# Resolve this file's own directory at source time. Callers source it from
# both bash and zsh, and zsh does not set BASH_SOURCE -- getting this wrong
# silently pointed every bounded run at a nonexistent supervisor, which is a
# guard that is not there at all. The eval keeps zsh-only syntax away from
# bash's parser; the final check makes a bad resolution loud instead of latent.
if [ -n "${BASH_SOURCE:-}" ]; then
    HOME_BIN_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "${ZSH_VERSION:-}" ]; then
    HOME_BIN_SH_DIR="$(cd "$(dirname "$(eval 'print -r -- ${(%):-%x}')")" && pwd)"
else
    HOME_BIN_SH_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
if [ ! -f "$HOME_BIN_SH_DIR/run-bounded.pl" ]; then
    _root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$_root" ] && [ -f "$_root/scripts/run-bounded.pl" ]; then
        HOME_BIN_SH_DIR="$_root/scripts"
    else
        echo "home-bin: cannot locate run-bounded.pl (looked in $HOME_BIN_SH_DIR)" >&2
        return 1 2>/dev/null || exit 1
    fi
fi

run_bounded() {
    perl "$HOME_BIN_SH_DIR/run-bounded.pl" "$@"
}
