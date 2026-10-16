#!/usr/bin/env perl
# Supervise one Home/Bun run: hold the machine lock, refuse to start when the
# host has no room, bound the run in wall clock, memory and disk, and leave nothing
# behind.
#
# Usage: run-bounded.pl <seconds> <command> [args...]
# Exits: the child's own code; 128+N if it died on signal N; 124 wall-clock
#        bound; 125 memory bound; 121 could not get the machine lock;
#        122 refused memory admission; 123 disk bound; 120 usage error.
#
# WHY THIS EXISTS, and why each piece is the shape it is — this guard replaced
# one that failed twice and took the host down with it.
#
# 1. MEMORY IS MEASURED AS phys_footprint, NEVER AS RSS.
#    On macOS, RSS is `written - swapped_out`: every page the kernel compresses
#    is SUBTRACTED from it. The number therefore FALLS as a process pushes the
#    machine toward death, so an RSS ceiling is anti-correlated with the danger
#    it is meant to catch. The previous guard polled `ps -o rss` and read 1.4 MB
#    for a process holding gigabytes. `footprint(1)` reports the kernel ledger's
#    phys_footprint — total dirty memory, compressed pages included — which is
#    the quantity that actually predicts exhaustion.
#
# 2. THE WHOLE DESCENDANT TREE IS MEASURED AND KILLED, NOT ONE PROCESS GROUP.
#    A grandchild that calls setsid()/setpgrp() leaves the group, and the old
#    guard then neither counted its memory nor killed it. Membership here is the
#    transitive closure over ppid, unioned with the group, so re-grouping cannot
#    hide a process from either the ledger or the kill.
#
# 3. IT FAILS CLOSED.
#    The old poll did `my $kb = 0; if (open(...ps...)) { ... }` with no else, so
#    a failed fork left the total at zero and silently disarmed the ceiling --
#    and fork failure is exactly what happens under the pressure being guarded
#    against. Here, repeated failure to measure is itself a breach.
#
# 4. IT SERIALIZES.
#    Both incidents were a background corpus scan plus foreground runs launched
#    on top of it. No per-process ceiling can prevent that: four runs each
#    legally inside a 4 GB bound is 16 GB on a 16 GB machine. An exclusive
#    machine-wide lock makes the second run WAIT instead of stack.
#
# 5. THE HOST'S OWN VIEW IS THE AUTHORITY; THE PER-RUN CEILING IS A BACKSTOP.
#    Per-process phys_footprint can count pages shared between siblings more
#    than once. The kernel pressure check is authoritative; the tree sum is a
#    conservative runaway detector. Also, footprint prints a "Summary Footprint"
#    line for multiple processes: adding that to the individual headers counts
#    the whole tree twice. Only PID-bearing process headers enter the sum.
#
# 6. IT DOES NOT GATE ON SWAP.
#    macOS grows and shrinks the swapfile on demand, so `vm.swapusage` free
#    space is not headroom -- it is just how much of the current file is unused.
#    Gating on it refuses all work on a perfectly healthy machine.
#    Actual filesystem free space is different: compiler outputs and swap growth
#    can fill the volume even while the kernel reports available memory.

use strict;
use warnings;
use Fcntl qw(:flock O_RDWR O_CREAT);
use IO::Select;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;

my $HOST_STREAK   = 3;      # consecutive bad host samples before killing
my $POLL          = 0.25;   # seconds between liveness/deadline checks
my $MEM_EVERY     = 4;      # measure memory every Nth poll (=> ~1 Hz)
my $MEM_FAIL_MAX  = 8;      # consecutive failed measurements tolerated (~8 s)
my $KILL_GRACE    = 3;      # seconds between TERM and KILL

# HOME_TEST_MAX_RSS_MB is the previous spelling; honoured so a caller that
# still sets it per-run is bounded rather than silently falling back to the
# default. The default lives here, not in the shell, so there is exactly one.
# Loose on purpose: this is a runaway detector, not a budget. It over-counts
# shared pages (note 5), so a value near a real workload's true peak produces
# false kills. The host check below is what actually protects the machine.
my $max_mb     = defined $ENV{HOME_RUN_MAX_MB}      ? $ENV{HOME_RUN_MAX_MB}
               : defined $ENV{HOME_TEST_MAX_RSS_MB} ? $ENV{HOME_TEST_MAX_RSS_MB}
               : 12288;
# Kill when the kernel says this fraction of RAM is neither wired nor held by
# the compressor, sustained across HOST_STREAK samples. Streak, not a single
# reading, so a transient dip from another process cannot kill this run.
my $crit_level = defined $ENV{HOME_RUN_CRIT_LEVEL} ? $ENV{HOME_RUN_CRIT_LEVEL} : 12;
my $lock_wait  = defined $ENV{HOME_RUN_LOCK_WAIT}  ? $ENV{HOME_RUN_LOCK_WAIT}  : 900;
my $min_level  = defined $ENV{HOME_RUN_MIN_LEVEL}  ? $ENV{HOME_RUN_MIN_LEVEL}  : 20;
my $min_free_mb = defined $ENV{HOME_RUN_MIN_FREE_MB} ? $ENV{HOME_RUN_MIN_FREE_MB} : 1024;
my $crit_free_mb = defined $ENV{HOME_RUN_CRIT_FREE_MB} ? $ENV{HOME_RUN_CRIT_FREE_MB} : 512;
my $lock_path  = $ENV{HOME_RUN_LOCK} || "$ENV{HOME}/.cache/home-run.lock";
my $label      = $ENV{HOME_RUN_LABEL} || '';

for my $v ([qw(HOME_RUN_MAX_MB)], [qw(HOME_TEST_MAX_RSS_MB)], [qw(HOME_RUN_LOCK_WAIT)], [qw(HOME_RUN_MIN_LEVEL)], [qw(HOME_RUN_CRIT_LEVEL)], [qw(HOME_RUN_MIN_FREE_MB)], [qw(HOME_RUN_CRIT_FREE_MB)]) {
    my $name = $v->[0];
    next unless defined $ENV{$name};
    # A malformed value is an error, never a silent fallback to "unbounded":
    # the bound must not be disableable by typo.
    die "run-bounded: $name must be a non-negative integer, got '$ENV{$name}'\n"
        unless $ENV{$name} =~ /^\d+$/;
}

my $secs = shift @ARGV;
die "usage: run-bounded.pl <seconds> <command> [args...]\n"
    unless defined $secs && $secs =~ /^\d+$/ && @ARGV;

# ---------------------------------------------------------------- host state

# A system probe can stall too (ps/footprint did so during a compiler run).
# Use ordinary pipes, not open('-|'): closing a Perl process pipe waits for
# its child and can block even after the read deadline has expired.
my $run_deadline;
our $reaping = 0;
my @pending_probes;
my $probe_failure;

sub capture_probe {
    my (@command) = @_;
    my $allow_nonzero = ref($command[0]) eq "HASH" ? shift(@command)->{allow_nonzero} : 0;
    @pending_probes = grep { waitpid($_, WNOHANG) == 0 } @pending_probes;
    $probe_failure = "deadline exceeded: $command[0]";
    my $until = time + 2;
    $until = $run_deadline if !$reaping && defined($run_deadline) && $run_deadline < $until;
    return undef if time >= $until;
    pipe(my $reader, my $writer) or do { $probe_failure = "pipe failed: $!"; return undef };
    my $probe = fork();
    if (!defined $probe) { $probe_failure = "fork failed: $!"; close($reader); close($writer); return undef }
    if ($probe == 0) {
        setpgrp(0, 0);
        close($reader);
        open(STDOUT, '>&', $writer) or exit 127;
        open(STDERR, '>', '/dev/null') or exit 127;
        close($writer);
        $SIG{PIPE} = 'DEFAULT';
        exec { $command[0] } @command;
        exit 127;
    }
    close($writer);
    my $select = IO::Select->new($reader);
    my $output = '';
    my $finished = 0;
    while (time < $until) {
        my $remaining = $until - time;
        last if $remaining <= 0;
        next unless $select->can_read($remaining > 0.1 ? 0.1 : $remaining);
        my $count = sysread($reader, my $buffer, 65536);
        last unless defined $count;
        if ($count == 0) { $finished = 1; last }
        $output .= $buffer;
    }
    close($reader);
    if ($finished) {
        while (time < $until) {
            my $done = waitpid($probe, WNOHANG);
            if ($done == $probe) {
                my $status = $?;
                if ($status == 0 || ($allow_nonzero && !($status & 127))) { $probe_failure = undef; return $output }
                $probe_failure = "probe exited with status $status: $command[0]";
                return undef;
            }
            if ($done == -1) { $probe_failure = "waitpid failed: $command[0]: $!"; last }
            select(undef, undef, undef, 0.01);
        }
    }
    kill('KILL', -$probe);
    kill('KILL', $probe);
    push @pending_probes, $probe if waitpid($probe, WNOHANG) == 0;
    return undef;
}

sub disk_free_mb {
    # Measure both output and temporary volumes, including negative free space.
    local $ENV{LC_ALL} = 'C';
    my $out = capture_probe('/bin/df', '-Pk', '.', $ENV{TMPDIR} || '/tmp');
    return undef unless defined $out;
    my $lowest;
    for (split /\n/, $out) {
        next unless /^.+?\s+\d+\s+\d+\s+(-?\d+)\s+\d+%/;
        my $mb = $1 / 1024;
        $lowest = $mb if !defined $lowest || $mb < $lowest;
    }
    return $lowest;
}

sub sysctl_num {
    my ($name) = @_;
    my $out = capture_probe('/usr/sbin/sysctl', '-n', $name);
    return undef unless defined $out;
    chomp $out;
    return $out =~ /^-?\d+$/ ? $out + 0 : undef;
}

# kern.memorystatus_level is the kernel's own "percent of RAM that is neither
# wired nor held by the compressor" -- the same figure it uses to decide when to
# start killing things. vm_pressure_level is 1 normal / 2 warn / 4 critical.
sub host_state {
    return (sysctl_num('kern.memorystatus_level'),
            sysctl_num('kern.memorystatus_vm_pressure_level'));
}

# ------------------------------------------------------------------ the lock

sysopen(my $lock, $lock_path, O_RDWR | O_CREAT, 0644)
    or die "run-bounded: cannot open $lock_path: $!\n";

if (!flock($lock, LOCK_EX | LOCK_NB)) {
    my $holder = do { local $/; seek($lock, 0, 0); <$lock> } || '(unknown)';
    chomp $holder;
    print STDERR "run-bounded: waiting up to ${lock_wait}s for the machine lock, held by: $holder\n";
    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $lock_wait;
        $got = flock($lock, LOCK_EX);
        alarm 0;
        1;
    };
    alarm 0;
    if (!$got) {
        print STDERR "run-bounded: gave up waiting for the machine lock (held by: $holder)\n";
        exit 121;
    }
}
truncate($lock, 0); seek($lock, 0, 0);
print $lock "pid=$$ label=$label cmd=@ARGV\n";
$lock->flush if $lock->can('flush');

# ------------------------------------------------------------- admission

if ($min_free_mb > 0 || $crit_free_mb > 0) {
    my $free = disk_free_mb();
    if (!defined $free) {
        print STDERR "run-bounded: refusing to start -- cannot measure available disk space\n";
        exit 123;
    }
    if ($free < $min_free_mb) {
        printf STDERR "run-bounded: refusing to start -- only %d MB disk free (want >= %d MB)\n", $free, $min_free_mb;
        exit 123;
    }
}

{
    my ($level, $pressure) = host_state();
    my @refuse;
    # Only CRITICAL (4) blocks, never WARN (2). macOS sits at warn routinely
    # with a browser open; refusing there refused every run on a machine with
    # 48% of RAM free, which is a guard that has stopped being a guard.
    push @refuse, "kernel memory pressure is CRITICAL"
        if defined $pressure && $pressure >= 4;
    push @refuse, "only ${level}% of RAM is neither wired nor compressed (want >= ${min_level}%; raise HOME_RUN_MIN_LEVEL to override)"
        if defined $level && $level < $min_level;
    # Deliberately NO swap term: see note 6 above.
    if (@refuse) {
        print STDERR "run-bounded: refusing to start -- " . join('; ', @refuse) . "\n";
        exit 122;
    }
}

# The kernel exposes the same current phys_footprint through libproc. Unlike
# footprint(1), this query does not traverse each process's VM mappings.
# Build a source-addressed helper once; preserve the original probe when a
# host cannot compile it. Both paths keep the same deadline and failure limit.
sub prepare_kernel_probe {
    my ($name) = @_;
    return undef unless $^O eq 'darwin';
    my $source = File::Spec->rel2abs(dirname($0) . "/$name.c");
    return undef unless open(my $input, '<', $source);
    local $/; my $contents = <$input>; close($input);
    my $directory = "$ENV{HOME}/.cache/home-run";
    eval { make_path($directory) };
    my $binary = "$directory/$name-" . sha256_hex($contents);
    if (!-x $binary && -d $directory) {
        my $temporary = "$binary.$$";
        my $compiled = capture_probe('/usr/bin/clang', '-O2', '-Wall', '-Wextra', '-Werror', $source, '-o', $temporary);
        if (defined($compiled) && -x $temporary) { rename($temporary, $binary) }
        unlink($temporary) if -e $temporary;
    }
    return -x $binary ? $binary : undef;
}
my $kernel_footprint_probe = prepare_kernel_probe('phys-footprint');
my $kernel_process_probe = prepare_kernel_probe('process-snapshot');

# --------------------------------------------------------------- the child

my $pid = fork();
die "run-bounded: fork: $!\n" unless defined $pid;
if ($pid == 0) {
    setpgrp(0, 0);
    # A SIG_IGN disposition survives exec; the supervisor must not hand the
    # child an ignored SIGPIPE or stream/backpressure tests change behaviour.
    $SIG{PIPE} = 'DEFAULT';
    delete $ENV{HOME_RUN_LOCK};
    exec { $ARGV[0] } @ARGV;
    exit 127;
}

# ------------------------------------------------------------ process tree

# Transitive closure over ppid from the root, unioned with the root's process
# group. Either relation alone is escapable; together they are not.
sub tree_pids {
    my ($root) = @_;
    my $snapshot = defined($kernel_process_probe)
        ? capture_probe($kernel_process_probe)
        : capture_probe('ps', '-axo', 'pid=,ppid=,pgid=');
    return () unless defined $snapshot;
    my (%kids, @grp);
    for (split /\n/, $snapshot) {
        my ($p, $pp, $pg) = split;
        next unless defined $pg;
        push @{ $kids{$pp} }, $p;
        push @grp, $p if $pg == $root;
    }
    my (%seen, @out, @queue) = ();
    @queue = ($root, @grp);
    while (@queue) {
        my $p = shift @queue;
        next if $seen{$p}++;
        push @out, $p;
        push @queue, @{ $kids{$p} || [] };
    }
    return @out;
}

# Parse only a process header, never the aggregate or auxiliary totals.
sub process_footprint_record {
    my ($line) = @_;
    return unless $line =~ /^\s*.+\[(\d+)\]:[^\n]*\bFootprint:\s+([\d.]+)\s*([KMGT]?B)/;
    my ($pid, $n, $unit) = ($1, $2, $3);
    my %mult = ('B' => 1/1048576, 'KB' => 1/1024, 'MB' => 1, 'GB' => 1024, 'TB' => 1048576);
    return ($pid, $n * $mult{$unit});
}

sub process_footprint_mb {
    my ($pid, $mb) = process_footprint_record(@_);
    return $mb;
}

# Sum phys_footprint over the tree. Returns undef when it could not measure,
# which the caller treats as a failure to be counted -- never as zero.
my %last_footprint_by_pid;
sub tree_footprint_mb {
    my (@pids) = @_;
    %last_footprint_by_pid = ();
    if (!@pids) { $probe_failure ||= "empty process tree"; return undef }
    my @args = map { ('-p', $_) } @pids;
    # A pid that exits between the ps snapshot and this call makes footprint
    # print to stderr; that is expected churn in a live tree, not a problem, so
    # keep it off the caller's stream. It still contributes nothing to the sum,
    # and a sample where NOTHING could be read returns undef and is counted as a
    # measurement failure by the caller.
    # Keep the totals-only fallback when the kernel helper is unavailable.
    my $snapshot = defined($kernel_footprint_probe)
        ? capture_probe($kernel_footprint_probe, @pids)
        : capture_probe({allow_nonzero => 1}, '/usr/bin/footprint', '--noCategories', @args);
    return undef unless defined $snapshot;
    my $total = 0;
    my $found = 0;
    for (split /\n/, $snapshot) {
        my ($pid, $mb) = process_footprint_record($_);
        next unless defined $mb;
        $last_footprint_by_pid{$pid} = $mb;
        $total += $mb;
        $found++;
    }
    $probe_failure = "no process footprint records" unless $found;
    return $found ? $total : undef;
}

sub report_largest_tree_process {
    return unless %last_footprint_by_pid;
    my ($largest) = sort {
        $last_footprint_by_pid{$b} <=> $last_footprint_by_pid{$a}
    } keys %last_footprint_by_pid;
    printf STDERR "run-bounded: largest sampled tree process pid=%d footprint=%.1f MB (shared pages may be counted per process)\n",
        $largest, $last_footprint_by_pid{$largest};
}

# Every pid ever seen in the tree, mapped to its native start identity (or
# the legacy command-line identity when the native snapshot is unavailable). Membership must be remembered, not recomputed at kill time: a
# grandchild whose parent exits is reparented to launchd (ppid 1) and keeps its
# own process group, so by the time the kill runs it is a descendant of nothing
# and matches no group. Three such processes survived a run and sat holding
# 1.2 GB between them. The recorded command line is the identity check that
# makes killing a remembered pid safe against pid reuse.
my %seen_cmd;

sub note_tree {
    my ($root) = @_;
    my %live = map { $_ => 1 } tree_pids($root);
    return unless %live;
    my $snapshot = defined($kernel_process_probe)
        ? capture_probe($kernel_process_probe)
        : capture_probe('ps', '-axo', 'pid=,args=');
    return unless defined $snapshot;
    for (split /\n/, $snapshot) {
        chomp;
        my ($p, $args);
        if (defined($kernel_process_probe)) {
            next unless /^\s*(\d+)\s+\d+\s+\d+\s+(\d+:\d+)(?:\s+\d+)?$/;
            ($p, $args) = ($1, $2);
        } else {
            next unless /^\s*(\d+)\s+(.*)$/;
            ($p, $args) = ($1, $2);
        }
        $seen_cmd{$p} = $args if $live{$p} && !exists $seen_cmd{$p};
    }
}

# Remembered pids that are still alive AND still running the same command.
sub remembered_survivors {
    my @out;
    return @out unless %seen_cmd;
    my $snapshot = defined($kernel_process_probe)
        ? capture_probe($kernel_process_probe)
        : capture_probe('ps', '-axo', 'pid=,args=');
    return @out unless defined $snapshot;
    for (split /\n/, $snapshot) {
        chomp;
        my ($p, $args);
        if (defined($kernel_process_probe)) {
            next unless /^\s*(\d+)\s+\d+\s+\d+\s+(\d+:\d+)(?:\s+\d+)?$/;
            ($p, $args) = ($1, $2);
        } else {
            next unless /^\s*(\d+)\s+(.*)$/;
            ($p, $args) = ($1, $2);
        }
        next unless exists $seen_cmd{$p};
        # Same pid AND same birth identity (legacy: command line): not recycled.
        push @out, $p if $seen_cmd{$p} eq $args;
    }
    return @out;
}

sub reap_tree {
    my ($root) = @_;
    local $reaping = 1;
    note_tree($root);
    my @pids = tree_pids($root);
    kill('TERM', -$root);
    kill('TERM', $_) for @pids;
    my $deadline = time + $KILL_GRACE;
    while (time < $deadline) {
        if (waitpid($root, 1) == $root) { last }
        select(undef, undef, undef, 0.1);
    }
    @pids = tree_pids($root);
    kill('KILL', -$root);
    kill('KILL', $_) for @pids;
    waitpid($root, 0);

    # Anything that escaped the tree by being reparented before the kill.
    my @escaped = remembered_survivors();
    if (@escaped) {
        printf STDERR "run-bounded: killing %d escaped process(es): %s\n",
            scalar(@escaped), join(',', @escaped);
        kill('KILL', $_) for @escaped;
    }
}

# ----------------------------------------------------------------- the loop

my $deadline = time + $secs;
$run_deadline = $deadline;
my $tick       = 0;
my $mem_fail   = 0;
my $disk_fail  = 0;
my $peak_mb    = 0;
my $host_bad   = 0;
my $worst_lvl  = 100;

$SIG{INT} = $SIG{TERM} = sub { reap_tree($pid); exit 130 };

while (1) {
    if (waitpid($pid, 1) == $pid) {
        my $status = $?;
        # A clean exit is not proof the tree is empty: the child can leave
        # reparented grandchildren behind.
        my @escaped = remembered_survivors();
        if (@escaped) {
            printf STDERR "run-bounded: killing %d process(es) left behind: %s\n",
                scalar(@escaped), join(',', @escaped);
            kill('KILL', $_) for @escaped;
        }
        printf STDERR "run-bounded: peak tree footprint %d MB (over-counts shared pages); host low-water %d%%\n",
            $peak_mb, $worst_lvl if $peak_mb > 0;
        exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
    }

    if (time >= $deadline) {
        print STDERR "run-bounded: wall-clock bound of ${secs}s exceeded\n";
        reap_tree($pid);
        exit 124;
    }

    if (++$tick % $MEM_EVERY == 0 && $crit_free_mb > 0) {
        my $free = disk_free_mb();
        if (!defined $free) {
            if (++$disk_fail >= $MEM_FAIL_MAX) {
                print STDERR "run-bounded: could not measure disk space $disk_fail times running; killing\n";
                reap_tree($pid);
                exit 123;
            }
        } else {
            $disk_fail = 0;
            if ($free < $crit_free_mb) {
                printf STDERR "run-bounded: only %d MB disk free (critical floor %d MB); killing this run\n", $free, $crit_free_mb;
                reap_tree($pid);
                exit 123;
            }
        }
    }

    if ($max_mb > 0 && $tick % $MEM_EVERY == 0) {
        note_tree($pid);
        my $mb = tree_footprint_mb(tree_pids($pid));
        if (!defined $mb) {
            # Fail closed. Being unable to measure under load is itself the
            # signal the old guard threw away.
            print STDERR "run-bounded: memory probe failed: " . ($probe_failure || "no process footprint records") . "\n";
            if (++$mem_fail >= $MEM_FAIL_MAX) {
                print STDERR "run-bounded: could not measure memory $mem_fail times running; killing\n";
                reap_tree($pid);
                exit 125;
            }
        } else {
            $mem_fail = 0;
            $peak_mb = $mb if $mb > $peak_mb;

            # PRIMARY: the kernel's own view. Shared-page-correct, and it sees
            # the other sessions on this machine, which a per-run sum cannot.
            my ($level, $pressure) = host_state();
            $worst_lvl = $level if defined $level && $level < $worst_lvl;
            my $bad = (defined $level    && $level    < $crit_level)
                   || (defined $pressure && $pressure >= 4);
            if ($bad) {
                $host_bad++;
                if ($host_bad >= $HOST_STREAK) {
                    printf STDERR "run-bounded: host out of memory (%d%% free-and-uncompressed, pressure %d) across %d samples; killing this run (tree %d MB)\n",
                        (defined $level ? $level : -1), (defined $pressure ? $pressure : -1), $host_bad, $mb;
                    report_largest_tree_process();
                    reap_tree($pid);
                    exit 125;
                }
            } else {
                $host_bad = 0;
            }

            # SECONDARY: runaway detector only. Loose ceiling; see note 5.
            if ($mb > $max_mb) {
                printf STDERR "run-bounded: tree footprint %d MB exceeded the %d MB runaway ceiling (host was at %d%%)\n",
                    $mb, $max_mb, (defined $level ? $level : -1);
                report_largest_tree_process();
                reap_tree($pid);
                exit 125;
            }
        }
    }

    select(undef, undef, undef, $POLL);
}
