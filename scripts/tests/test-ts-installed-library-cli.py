#!/usr/bin/env python3
"""Verify project-installed compiler libraries and a retained negative diagnostic."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    reference = args.reference.resolve()
    package = reference.parent.parent
    if not (package / 'package.json').is_file():
        raise SystemExit('Reference must be the installed typescript/bin/tsc entry point')
    summary = {'observations': [], 'failures': []}
    reference_graphs = {}
    for default in (False, True):
        for negative in (False, True):
            for engine, exe in [('native', reference), ('home', args.home.resolve())]:
                case = f'{"default" if default else "explicit"}/{"negative" if negative else "positive"}/{engine}'
                directory = root / case
                (directory / 'node_modules').mkdir(parents=True)
                (directory / 'node_modules/typescript').symlink_to(package, target_is_directory=True)
                source = 'declare const init: RequestInit;\nconst method: string | undefined = init.method;\n'
                if negative:
                    source += 'const wrong: number = init.method;\n'
                (directory / 'main.ts').write_text(source)
                options = dict(strict=True, noEmit=True, skipLibCheck=True, target='ESNext', types=[])
                if not default:
                    options['lib'] = ['ES2023', 'DOM']
                (directory / 'tsconfig.json').write_text(json.dumps(dict(compilerOptions=options, files=['main.ts'])))
                paths = [directory / 'main.ts', directory / 'tsconfig.json']
                hashes = {str(p.relative_to(directory)): digest(p) for p in paths}
                run = subprocess.run([str(exe), '--project', 'tsconfig.json', '--pretty', 'false'], cwd=directory, capture_output=True, text=True, timeout=90)
                output = run.stdout + run.stderr
                codes = re.findall(r'error TS(\d+):', output)
                graph = subprocess.run([str(exe), '--project', 'tsconfig.json', '--listFilesOnly', '--pretty', 'false'], cwd=directory, capture_output=True, text=True, timeout=90)
                graph_files = [str((directory / line).resolve()) for line in graph.stdout.splitlines() if (directory / line).is_file()]
                dom = [p for p in graph_files if Path(p).name == 'lib.dom.d.ts']
                library_hashes = {p: digest(Path(p)) for p in graph_files if p != str(directory / 'main.ts')}
                graph_key = (default, negative)
                if engine == 'native':
                    reference_graphs[graph_key] = library_hashes
                same_libraries = library_hashes == reference_graphs[graph_key]
                unchanged_libraries = all(digest(Path(p)) == h for p, h in library_hashes.items())
                passed = (run.returncode == int(negative) and codes == (['2322'] if negative else [])
                          and graph.returncode == 0 and len(dom) == 1 and same_libraries and unchanged_libraries
                          and hashes == {str(p.relative_to(directory)): digest(p) for p in paths})
                summary['observations'].append(dict(case=case, passed=passed, exit=run.returncode, stdout=run.stdout, stderr=run.stderr, graph=graph_files, graph_stderr=graph.stderr, input_hashes=hashes, library_hashes=library_hashes, same_libraries=same_libraries))
                if not passed:
                    summary['failures'].append(case)
                (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    if summary['failures']:
        raise SystemExit('Failed: ' + ', '.join(summary['failures']))
    print(f"All {len(summary['observations'])} installed library observations passed")


if __name__ == '__main__':
    main()
