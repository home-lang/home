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

# Resident-set ceiling for a bounded run, in MB, covering the whole process
# group. Set to 0 to disable.
#
# This is not belt-and-braces: macOS honours neither `ulimit -v` nor `ulimit -d`,
# so without an explicit poller a runaway corpus file has NO memory ceiling at
# all. Some upstream tests legitimately allocate hundreds of MB (a >512 MB
# string-decoder buffer, multi-GB leak probes), and a debug build inflates that
# further, so one bad file can exhaust the machine and take the session with it.
: "${HOME_TEST_MAX_RSS_MB:=4096}"

# Run a command with a wall-clock bound and a memory bound, using timeout's exit
# conventions: 124 when the time bound is hit, 128+signal when it dies on one,
# else its own code. 125 is added for "exceeded the resident-set ceiling".
#
# coreutils `timeout` is not present on macOS, which is the only platform the
# native runtime currently supports — without a fallback every bounded run exits
# 127 and is misread as a crash. Perl ships with the base system, so use it to
# fork into its own process group and supervise: a bare kill of the direct child
# leaves spawned test servers holding their ports, and only the group's summed
# RSS reflects a test that forks its work into children.
if command -v gtimeout >/dev/null 2>&1 && [ "${HOME_TEST_MAX_RSS_MB:-0}" = "0" ]; then
    run_bounded() { gtimeout "$@"; }
elif command -v timeout >/dev/null 2>&1 && [ "${HOME_TEST_MAX_RSS_MB:-0}" = "0" ]; then
    run_bounded() { timeout "$@"; }
else
    run_bounded() {
        HOME_TEST_MAX_RSS_MB="${HOME_TEST_MAX_RSS_MB:-4096}" perl -e '
            my $secs = shift @ARGV;
            my $max_mb = $ENV{HOME_TEST_MAX_RSS_MB} || 0;
            my $pid = fork();
            die "fork: $!" unless defined $pid;
            if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
            my $deadline = time + $secs;
            while (1) {
                my $reaped = waitpid($pid, 1);   # WNOHANG
                if ($reaped == $pid) {
                    my $status = $?;
                    exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
                }
                if (time >= $deadline) {
                    kill("KILL", -$pid); waitpid($pid, 0); exit 124;
                }
                if ($max_mb > 0) {
                    my $kb = 0;
                    if (open(my $ps, "-|", "ps", "-axo", "pgid=,rss=")) {
                        while (<$ps>) {
                            my ($g, $r) = split;
                            $kb += $r if defined $r && defined $g && $g eq $pid;
                        }
                        close($ps);
                    }
                    if ($kb > $max_mb * 1024) {
                        kill("KILL", -$pid); waitpid($pid, 0); exit 125;
                    }
                }
                select(undef, undef, undef, 0.25);
            }
        ' "$@"
    }
fi
