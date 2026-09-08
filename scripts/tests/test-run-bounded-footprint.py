#!/usr/bin/env python3
"""Check the supervisor's parser against real footprint report structure."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[2]
source = (root / 'scripts/run-bounded.pl').read_text()
match = re.search(r'^sub process_footprint_mb \{.*?^\}', source, re.M | re.S)
assert match, 'supervisor parser not found'
# The first two headers and summary were captured from a real two-process
# footprint probe. Auxiliary and aggregate lines must not add memory again.
checks = r'''
my @headers = (
    "zsh [62879]: 64-bit    Footprint: 1856 KB (16384 bytes per page)",
    "sleep [62881]: 64-bit    Footprint: 1104 KB (16384 bytes per page)",
);
my $sum = 0;
$sum += process_footprint_mb($_) for @headers;
die "process total changed: $sum" unless $sum == 2.890625;
for my $line ("Summary Footprint: 2881 KB", "    phys_footprint: 1856 KB", "    phys_footprint_peak: 1840 KB", "Footprint: 99 GB") {
    die "counted non-process total: $line" if defined process_footprint_mb($line);
}
for my $case (["0 B", 0], ["1048576 B", 1], ["512 KB", 0.5], ["12.5 MB", 12.5], ["1.5 GB", 1536], ["0.5 TB", 524288]) {
    my ($input, $expected) = @$case;
    my $actual = process_footprint_mb("process with spaces [123]: 64-bit    Footprint: $input");
    die "unit conversion failed: $input" unless defined($actual) && $actual == $expected;
}
print "footprint parser: process headers counted once; summary/auxiliary totals ignored\n";
'''
subprocess.run(['perl', '-e', 'use strict; use warnings;\n' + match[0] + '\n' + checks], check=True)
