#!/usr/bin/env python3
"""Compare production launch rules with pinned Bun CI over the discovery inventory.

Run under scripts/run-bounded.pl. This checks rule selection, not corpus passes.
The output directory must be new; all compiler/control outputs are retained.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', required=True)
    parser.add_argument('--node', default='node')
    parser.add_argument('--bun-source', type=Path, default=Path.home() / 'Code/bun')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('discovery', ROOT / 'scripts/audit-bun-corpus-discovery.py')
    discovery = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(discovery)
    inventory = discovery.audit(args.zig, args.node, args.bun_source, True)
    (out / 'discovery.json').write_text(json.dumps(inventory, indent=2) + '\n')
    comparison = inventory['comparison']
    assert not comparison['home_only'] and not comparison['upstream_only']
    assert not comparison['native_mode_differences']
    reference = subprocess.check_output(['git', '-C', str(args.bun_source), 'show', f'{discovery.PIN}:scripts/runner.node.mjs'])
    (out / 'runner.node.mjs').write_bytes(reference)
    source = reference.decode()
    rules = '\n'.join(discovery.section(source, f'function {name}(', '\n}') + '\n}'
                      for name in ['getTestTimeout', 'getNodeParallelTestTimeout'])
    entries = inventory['upstream_entries']
    (out / 'entries.json').write_text(json.dumps(entries) + '\n')
    control = '''import { readFileSync } from 'node:fs';
const testTimeout = 180000, integrationTimeout = 300000;
let isCI = true, options = {};
''' + rules + '''
const entries = JSON.parse(readFileSync(new URL('./entries.json', import.meta.url)));
const result = [];
for (const context of [
  {is_ci:true, asan:false, asan_step:false},
  {is_ci:true, asan:true, asan_step:false},
  {is_ci:true, asan:true, asan_step:true},
  {is_ci:false, asan:false, asan_step:false},
]) {
  isCI = context.is_ci;
  options = {step: context.asan_step ? 'test-asan-linux' : 'test-linux'};
  for (const entry of entries) {
    const node = entry.node_test, test = entry.mode === 'test';
    const timeout = getTestTimeout('test/' + entry.path);
    result.push({
      file: {relative_path:entry.path, node_test:node, test_runner:test, is_ci:isCI, asan_step:context.asan_step},
      executable: context.asan ? '/bin/home-asan' : '/bin/home',
      expected: {
        file_timeout_ms: node ? getNodeParallelTestTimeout('test/' + entry.path) : test ? timeout * (context.asan ? 2 : 1) : 30000,
        test_timeout_ms: !node && test ? Math.ceil(timeout / 2) * (context.asan ? 3 : 1) : null,
        node_test:node,
        validate_runtime:context.asan || !isCI,
        no_orphans:context.asan && !node,
      }
    });
  }
}
console.log(JSON.stringify(result));
'''
    (out / 'control.mjs').write_text(control)
    predicted = subprocess.run([args.node, str(out / 'control.mjs')], capture_output=True, check=True)
    (out / 'control.stderr.log').write_bytes(predicted.stderr)
    (out / 'expected.json').write_bytes(predicted.stdout)
    rows = json.loads(predicted.stdout)
    production = ROOT / 'packages/home_test/src/corpus_launch.zig'
    shutil.copyfile(production, out / 'corpus_launch.zig')
    (out / 'audit.zig').write_text('''const std = @import("std");
const launch = @import("corpus_launch.zig");
test "production launch rules match pinned runner across the full inventory" {
    const Row = struct { file: launch.File, executable: []const u8, expected: launch.Profile };
    const rows = try std.json.parseFromSlice([]Row, std.testing.allocator, @embedFile("expected.json"), .{});
    defer rows.deinit();
    for (rows.value, 0..) |row, index| {
        const actual = launch.profile(row.file, row.executable);
        std.testing.expectEqualDeep(row.expected, actual) catch |err| {
            std.debug.print("LAUNCH_MISMATCH row={d} path={s} executable={s} ci={} asan_step={}\\n", .{index, row.file.relative_path, row.executable, row.file.is_ci, row.file.asan_step});
            return err;
        };
    }
    std.debug.print("LAUNCH_AUDIT {d} rule selections matched\\n", .{rows.value.len});
}
''')
    result = subprocess.run([args.zig, 'test', str(out / 'audit.zig'), '-O', 'ReleaseFast'], capture_output=True)
    (out / 'audit.stdout.log').write_bytes(result.stdout)
    (out / 'audit.stderr.log').write_bytes(result.stderr)
    report = {
        'status': 'Launch-rule comparison only; no corpus file/test passes claimed.',
        'bun_pin': discovery.PIN,
        'upstream_runner_sha256': sha(reference),
        'production_launch_sha256': sha(production.read_bytes()),
        'discovered_files': len(entries),
        'contexts': 4,
        'rule_selections': len(rows),
        'file_timeout_distribution': dict(Counter(row['expected']['file_timeout_ms'] for row in rows)),
        'exit_code': result.returncode,
        'files': {p.name: sha(p.read_bytes()) for p in sorted(out.iterdir()) if p.is_file()},
    }
    (out / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
