#!/usr/bin/env python3
"""Compare exact Home routing predicates with pinned Bun CI discovery, without running tests.

Example:
  python3 scripts/audit-bun-corpus-discovery.py --zig /path/to/zig --output audit.json

Requires Zig and Node. Extracted functions run in temporary standalone programs;
Bun's CI runner module is never imported or executed. Results describe discovery
before platform expectations, filtering, sharding, integration and vendor setup.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PIN = (ROOT / "packages/runtime/test/test/UPSTREAM_SHA.txt").read_text().strip()


def run(args):
    return subprocess.run(args, check=True, text=True, capture_output=True, cwd=ROOT)


def section(source, start, end):
    offset = source.index(start)
    return source[offset:source.index(end, offset)]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def audit(zig, node, bun_source):
    runner_bytes = (ROOT / "packages/home_test/src/corpus_runner.zig").read_bytes()
    runner = runner_bytes.decode()
    corpus = (ROOT / "packages/home_test/src/corpus.zig").read_text()
    mirror = ROOT / "packages/runtime/test/test"
    manifest = (mirror / "BUN_TRACKED_FILES.txt").read_bytes()
    upstream = run(["git", "-C", str(bun_source), "show", f"{PIN}:scripts/runner.node.mjs"]).stdout
    zig_source = '\n'.join([
        'const std = @import("std");',
        section(runner, 'const stream_iter_corpus_prefix', '\n'),
        section(corpus, 'pub fn isTestFile', 'pub fn countPath'),
        section(runner, 'fn isNativeStreamIteratorCorpusFile', 'fn parseNativeCorpusFlags'),
        section(runner, 'const NativeCorpusMode', 'fn buildNativeCorpusArgs'),
        r'''
test "audit exact production corpus routing" {
    var lines = std.mem.splitScalar(u8, @embedFile("manifest.txt"), '\n');
    while (lines.next()) |raw| {
        const path = std.mem.trimEnd(u8, raw, "\r");
        if (path.len == 0 or !isTestFile(std.fs.path.basename(path))) continue;
        const native = isNativeHomeCorpusFile(path);
        std.debug.print("ROUTE\t{s}\t{s}\t{s}\t{s}\n", .{
            path, if (native) "native" else "bootstrap",
            if (native) @tagName(nativeCorpusMode(path)) else "adapter",
            nativeCorpusDisabledReason(path) orelse "",
        });
    }
}
''',
    ])
    functions = []
    for name in ('isJavaScript', 'isNodeTest', 'isClusterTest', 'isTest', 'isTestStrict', 'isHidden', 'getTests'):
        functions.append(section(upstream, f'function {name}(', '\n}') + '\n}')
    modes = section(upstream, '            let runWithBunTest =', '            const env =')
    node_source = '''
import {basename, dirname, join, sep} from "node:path";
import {readdirSync, readFileSync} from "node:fs";
const isCI = false, isMacOS = process.platform === "darwin", isX64 = process.arch === "x64";
''' + '\n'.join(functions) + '\nconst root = ' + json.dumps(str(mirror)) + ';\n' + r'''
const tracked = new Set(readFileSync(join(root, "BUN_TRACKED_FILES.txt"), "utf8").trim().split(/\r?\n/));
const discovered = getTests(root);
const rows = discovered.filter(path => tracked.has(path.replaceAll(sep, "/"))).map(testPath => {
    let mode = "test";
    if (isNodeTest(testPath)) {
        const title = "test/" + testPath.replaceAll(sep, "/");
        const testContent = readFileSync(join(root, testPath), "utf8");
''' + modes + '''
        mode = subcommand;
    }
    return {path: testPath.replaceAll(sep, "/"), mode};
});
console.log(JSON.stringify({context: {isCI, isMacOS, isX64}, rows,
    untracked: discovered.filter(path => !tracked.has(path.replaceAll(sep, "/")))}));
'''
    with tempfile.TemporaryDirectory(prefix='home-corpus-discovery-') as temp:
        work = Path(temp)
        (work / 'manifest.txt').write_bytes(manifest)
        (work / 'audit.zig').write_text(zig_source)
        (work / 'audit.mjs').write_text(node_source)
        result = run([zig, 'test', str(work / 'audit.zig'), '-O', 'ReleaseFast'])
        rows = []
        for line in (result.stdout + result.stderr).splitlines():
            if 'ROUTE\t' in line:
                rows.append(line.split('ROUTE\t', 1)[1].split('\t'))
        if not rows or any(len(row) != 4 for row in rows):
            raise RuntimeError('Missing or malformed routing audit output')
        native = {row[0]: row[1:] for row in rows}
        if len(native) != len(rows):
            raise RuntimeError('Duplicate Home discovery paths')
        discovered = json.loads(run([node, str(work / 'audit.mjs')]).stdout)
    upstream_modes = {row['path']: row['mode'] for row in discovered['rows']}
    counts = Counter(f'{row[1]}/{row[2]}' for row in rows)
    mode_names = {'script': 'run', 'test_runner': 'test'}
    return {
        'status': 'Discovery and routing only; no test execution or implemented-feature claim.',
        'bun_pin': PIN,
        'home_git_head': run(['git', 'rev-parse', 'HEAD']).stdout.strip(),
        'home_corpus_runner_sha256': sha256(runner_bytes),
        'tracked_manifest_sha256': sha256(manifest),
        'upstream_ci_runner_sha256': sha256(upstream.encode()),
        'context': discovered['context'],
        'stage': 'Before expectations, filters, sharding, integration setup and vendor selection',
        'home_route_counts': dict(counts),
        'comparison': {
            'upstream_tracked_discovered': len(upstream_modes),
            'home_classified': len(native),
            'home_only': sorted(native.keys() - upstream_modes.keys()),
            'upstream_only': sorted(upstream_modes.keys() - native.keys()),
            'native_mode_differences': [
                {'path': path, 'home': native[path][1], 'upstream': upstream_modes[path]}
                for path in sorted(native.keys() & upstream_modes.keys())
                if native[path][0] == 'native' and mode_names[native[path][1]] != upstream_modes[path]
            ],
            'untracked_upstream_discovery_count': len(discovered['untracked']),
        },
        'untracked_upstream_discovery': discovered['untracked'],
        'disabled_native_files': [row for row in rows if row[1] == 'native' and row[3]],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--node', default='node')
    parser.add_argument('--bun-source', type=Path, default=Path.home() / 'Code/bun')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = json.dumps(audit(args.zig, args.node, args.bun_source), indent=2) + '\n'
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end='')


if __name__ == '__main__':
    main()
