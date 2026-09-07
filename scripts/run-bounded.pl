#!/usr/bin/env perl
# Supervise one Home/Bun run: hold the machine lock, refuse to start when the
# host has no room, bound the run in wall clock and memory, and leave nothing
# behind.
#
# Usage: run-bounded.pl <seconds> <command> [args...]
# Exits: the child's own code; 128+N if it died on signal N; 124 wall-clock
#        bound; 125 memory bound; 121 could not get the machine lock;
#        122 refused admission; 120 usage error.
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
# 5. IT DOES NOT GATE ON SWAP.
#    macOS grows and shrinks the swapfile on demand, so `vm.swapusage` free
#    space is not headroom -- it is just how much of the current file is unused.
#    Gating on it refuses all work on a perfectly healthy machine.

use strict;
use warnings;
use Fcntl qw(:flock O_RDWR O_CREAT);

my $POLL          = 0.25;   # seconds between liveness/deadline checks
my $MEM_EVERY     = 4;      # measure memory every Nth poll (=> ~1 Hz)
my $MEM_FAIL_MAX  = 8;      # consecutive failed measurements tolerated (~8 s)
my $KILL_GRACE    = 3;      # seconds between TERM and KILL

# HOME_TEST_MAX_RSS_MB is the previous spelling; honoured so a caller that
# still sets it per-run is bounded rather than silently falling back to the
# default. The default lives here, not in the shell, so there is exactly one.
my $max_mb     = defined $ENV{HOME_RUN_MAX_MB}      ? $ENV{HOME_RUN_MAX_MB}
               : defined $ENV{HOME_TEST_MAX_RSS_MB} ? $ENV{HOME_TEST_MAX_RSS_MB}
               : 4096;
my $lock_wait  = defined $ENV{HOME_RUN_LOCK_WAIT}  ? $ENV{HOME_RUN_LOCK_WAIT}  : 900;
my $min_level  = defined $ENV{HOME_RUN_MIN_LEVEL}  ? $ENV{HOME_RUN_MIN_LEVEL}  : 20;
my $lock_path  = $ENV{HOME_RUN_LOCK} || "$ENV{HOME}/.cache/home-run.lock";
my $label      = $ENV{HOME_RUN_LABEL} || '';

for my $v ([qw(HOME_RUN_MAX_MB)], [qw(HOME_TEST_MAX_RSS_MB)], [qw(HOME_RUN_LOCK_WAIT)], [qw(HOME_RUN_MIN_LEVEL)]) {
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

sub sysctl_num {
    my ($name) = @_;
    my $out = `/usr/sbin/sysctl -n $name 2>/dev/null`;
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

{
    my ($level, $pressure) = host_state();
    my @refuse;
    push @refuse, "kernel pressure level $pressure (want 1=normal)"
        if defined $pressure && $pressure >= 2;
    push @refuse, "only ${level}% of RAM is neither wired nor compressed (want >= ${min_level}%)"
        if defined $level && $level < $min_level;
    # Deliberately NO swap term: see note 5 above.
    if (@refuse) {
        print STDERR "run-bounded: refusing to start -- " . join('; ', @refuse) . "\n";
        print STDERR "run-bounded: free memory on the host first, or raise HOME_RUN_MIN_LEVEL deliberately.\n";
        exit 122;
    }
}

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
    open(my $ps, '-|', 'ps', '-axo', 'pid=,ppid=,pgid=') or return ();
    my (%kids, @grp);
    while (<$ps>) {
        my ($p, $pp, $pg) = split;
        next unless defined $pg;
        push @{ $kids{$pp} }, $p;
        push @grp, $p if $pg == $root;
    }
    close($ps);
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

# Sum phys_footprint over the tree. Returns undef when it could not measure,
# which the caller treats as a failure to be counted -- never as zero.
sub tree_footprint_mb {
    my (@pids) = @_;
    return undef unless @pids;
    my @args = map { ('-p', $_) } @pids;
    open(my $fp, '-|', '/usr/bin/footprint', @args) or return undef;
    my $total = 0;
    my $found = 0;
    while (<$fp>) {
        # "name [pid]: 64-bit    Footprint: 1760 KB (16384 bytes per page)"
        next unless /Footprint:\s+([\d.]+)\s*([KMGT]?B)/;
        my ($n, $unit) = ($1, $2);
        my %mult = ('B' => 1/1048576, 'KB' => 1/1024, 'MB' => 1, 'GB' => 1024, 'TB' => 1048576);
        $total += $n * ($mult{$unit} || 0);
        $found++;
    }
    close($fp);
    return $found ? $total : undef;
}

sub reap_tree {
    my ($root) = @_;
    my @pids = tree_pids($root);
    kill('TERM', -$root);
    kill('TERM', $_) for @pids;
    my $deadline = time + $KILL_GRACE;
    while (time < $deadline) {
        return if waitpid($root, 1) == $root;
        select(undef, undef, undef, 0.1);
    }
    @pids = tree_pids($root);
    kill('KILL', -$root);
    kill('KILL', $_) for @pids;
    waitpid($root, 0);
}

# ----------------------------------------------------------------- the loop

my $deadline = time + $secs;
my $tick     = 0;
my $mem_fail = 0;
my $peak_mb  = 0;

$SIG{INT} = $SIG{TERM} = sub { reap_tree($pid); exit 130 };

while (1) {
    if (waitpid($pid, 1) == $pid) {
        my $status = $?;
        printf STDERR "run-bounded: peak footprint %d MB\n", $peak_mb if $peak_mb > 0;
        exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
    }

    if (time >= $deadline) {
        print STDERR "run-bounded: wall-clock bound of ${secs}s exceeded\n";
        reap_tree($pid);
        exit 124;
    }

    if ($max_mb > 0 && ++$tick % $MEM_EVERY == 0) {
        my $mb = tree_footprint_mb(tree_pids($pid));
        if (!defined $mb) {
            # Fail closed. Being unable to measure under load is itself the
            # signal the old guard threw away.
            if (++$mem_fail >= $MEM_FAIL_MAX) {
                print STDERR "run-bounded: could not measure memory $mem_fail times running; killing\n";
                reap_tree($pid);
                exit 125;
            }
        } else {
            $mem_fail = 0;
            $peak_mb = $mb if $mb > $peak_mb;
            if ($mb > $max_mb) {
                printf STDERR "run-bounded: footprint %d MB exceeded the %d MB ceiling\n", $mb, $max_mb;
                reap_tree($pid);
                exit 125;
            }
            # Back off when the HOST is in trouble even if this run is within
            # its own budget -- the machine is shared with other sessions.
            my (undef, $pressure) = host_state();
            if (defined $pressure && $pressure >= 4) {
                printf STDERR "run-bounded: host at critical memory pressure; killing this run (footprint %d MB)\n", $mb;
                reap_tree($pid);
                exit 125;
            }
        }
    }

    select(undef, undef, undef, $POLL);
}
