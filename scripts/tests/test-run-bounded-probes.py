#!/usr/bin/env python3
"""A stalled system probe must not disable deadline enforcement or cleanup."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[2]
guard = root / 'scripts/run-bounded.pl'
# Preserve valid footprint headers when another PID disappears, but reject
# failed process snapshots and timed-out probes.
source = guard.read_text()
helper = source[source.index('my $run_deadline;'):source.index('sub disk_free_mb {')]
checks = r"""
my $bad = capture_probe('/bin/sh', '-c', 'printf partial; exit 1');
die 'accepted failed snapshot' if defined($bad);
my $partial = capture_probe({allow_nonzero => 1}, '/bin/sh', '-c', 'printf partial; exit 1');
die 'lost partial footprint output' unless defined($partial) && $partial eq 'partial';
my $start = time;
my $stalled = capture_probe('/bin/sleep', '60');
die 'accepted stalled probe' if defined($stalled);
die 'probe timeout unbounded' if time - $start > 5;
"""
subprocess.run(['perl', '-e', 'use strict; use warnings; use IO::Select; use POSIX qw(WNOHANG); use Time::HiRes qw(time);\n' + helper + checks], check=True, timeout=10)
with tempfile.TemporaryDirectory(prefix='bounded-probes-') as temporary:
    directory = Path(temporary)
    fallback_guard = directory / 'run-bounded.pl'
    fallback_guard.write_text(source)
    # No native helper sources beside this copy: exercise the legacy ps path.
    stub = directory / 'ps'
    probe_pids = directory / 'probes'
    stub.write_text('#!/bin/sh\necho "$$" >> "$PROBE_PIDS"\nexec /bin/sleep 60\n')
    stub.chmod(0o755)
    env = os.environ.copy()
    env.update(PATH=str(directory) + os.pathsep + env['PATH'], PROBE_PIDS=str(probe_pids),
               HOME_RUN_LOCK=str(directory / 'lock'), HOME_RUN_MIN_FREE_MB='1',
               HOME_RUN_CRIT_FREE_MB='1', HOME_RUN_MIN_LEVEL='0', HOME_RUN_MAX_MB='3840')
    marker = directory / 'child'
    program = ['/bin/sh', '-c', 'echo "$$" > "$1"; exec /bin/sleep 60', 'bounded-child', str(marker)]
    started = time.monotonic()
    log = directory / 'supervisor.log'
    with log.open('w') as stream:
        process = subprocess.Popen(['perl', str(fallback_guard), '3'] + program,
                                   env=env, cwd=root, stdout=stream, stderr=subprocess.STDOUT)
        try:
            status = process.wait(timeout=24)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
                own_pids = ([int(marker.read_text())] if marker.exists() else [])
                own_pids += [int(value) for value in probe_pids.read_text().splitlines()] if probe_pids.exists() else []
                for pid in own_pids:
                    try:
                        os.killpg(pid, 9)
                    except ProcessLookupError:
                        pass
    elapsed = time.monotonic() - started
    text = log.read_text()
    assert status == 124, (status, text)
    assert elapsed < 22, (elapsed, text)
    assert 'wall-clock bound' in text
    assert marker.exists()
    pids = [int(marker.read_text())] + [int(value) for value in probe_pids.read_text().splitlines()]
    for pid in pids:
        state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True, timeout=5)
        assert not state.stdout.strip() or state.stdout.strip().startswith('Z'), (pid, state.stdout)
    positive_log = directory / 'positive.log'
    with positive_log.open('w') as stream:
        positive_status = subprocess.run(['perl', str(fallback_guard), '5', '/bin/echo', 'short-child'],
                                         env=env, cwd=root, stdout=stream, stderr=subprocess.STDOUT,
                                         timeout=15).returncode
    assert positive_status == 0 and 'short-child' in positive_log.read_text()
    print(json.dumps({'stalled_ps_exit': status, 'elapsed_seconds': round(elapsed, 3),
                      'child_and_probe_cleanup': True, 'positive_exit': positive_status}))
