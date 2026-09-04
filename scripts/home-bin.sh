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

# Run a command with a wall-clock bound, using timeout's exit conventions:
# 124 when the bound is hit, 128+signal when it dies on one, else its own code.
#
# coreutils `timeout` is not present on macOS, which is the only platform the
# native runtime currently supports — without a fallback every bounded run exits
# 127 and is misread as a crash. Perl ships with the base system, so use it to
# fork into its own process group and kill the whole group on the alarm; a bare
# kill of the direct child leaves spawned test servers holding their ports.
if command -v timeout >/dev/null 2>&1; then
    run_bounded() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
    run_bounded() { gtimeout "$@"; }
else
    run_bounded() {
        perl -e '
            my $secs = shift @ARGV;
            my $pid = fork();
            die "fork: $!" unless defined $pid;
            if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
            $SIG{ALRM} = sub { kill("KILL", -$pid); waitpid($pid, 0); exit 124; };
            alarm $secs;
            waitpid($pid, 0);
            my $status = $?;
            alarm 0;
            exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
        ' "$@"
    }
fi
