#!/usr/bin/env python3
"""Check declaration emission with native consumers and complete output audits.

Run under scripts/run-bounded.pl. Minimal globals keep skipLibCheck disabled
without mixing this declaration contract with standard-library conformance.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess

GLOBALS = '\n'.join(
    f'interface {name} {{}}'
    for name in (
        'Array<T>', 'Boolean', 'CallableFunction', 'Function', 'IArguments',
        'NewableFunction', 'Number', 'Object', 'RegExp', 'String',
    )
)
FILES = {
    'globals.d.ts': GLOBALS,
    'owner.ts': '''export interface Token<out T extends string|number=string>{readonly value:T}
export interface Child<T extends string|number=string> extends Token<T>{}
export namespace Inner {
  export interface Item<T=string>{value:T}
  export function nested(path:string):string{return path;}
}
export function take(path:string):string{return path;}''',
    'entry.ts': '''export type Alias=import("./owner").Token<number>;
export type Nested=import("./owner").Inner.Item;
export type Module=typeof import("./owner");
export type Take=typeof import("./owner").take;
export class Guard{get():import("./owner").Token{return {value:"ok"};}}
export type Constrained<T extends string=string>=import("./owner").Token<T>;
export type Inherited=import("./owner").Child;
export class Generic<T extends string=string>{echo<U extends T>(value:U):U{return value;}}
export function identity<const T extends string>(value:T):T{return value;}
export type Callback=<T extends string>(value:T)=>T;''',
}
IMPORTS = '''import {identity} from "./entry";
import type {Alias,Nested,Module,Take,Guard,Constrained,Inherited,Generic,Callback} from "./entry";
'''
POSITIVE = IMPORTS + '''declare const alias:Alias;const value:number=alias.value;
declare const nested:Nested;const text:string=nested.value;
declare const module:Module;module.take("ok");module.Inner.nested("ok");
declare const take:Take;take("ok");
declare const guard:Guard;const result:string=guard.get().value;
const constrained:Constrained={value:"ok"};
declare const generic:Generic;generic.echo("ok");
identity("ok");declare const callback:Callback;callback("ok");
declare const inherited:Inherited;const parent:string=inherited.value;'''
NEGATIVE = IMPORTS + '''declare const alias:Alias;const value:string=alias.value;
declare const nested:Nested;const text:number=nested.value;
declare const module:Module;module.take(1);module.Inner.nested(1);
declare const take:Take;take(1);
declare const guard:Guard;const result:number=guard.get().value;
type Invalid=Constrained<number>;
declare const generic:Generic;generic.echo(1);
identity(1);declare const callback:Callback;callback(1);
declare const inherited:Inherited;const parent:number=inherited.value;'''
OPTIONS = {
    'strict': True, 'skipLibCheck': False, 'types': [], 'noLib': True,
    'target': 'ESNext', 'module': 'ESNext', 'moduleResolution': 'Bundler',
}
DIAGNOSTIC = re.compile(r'([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def project_files(directory):
    return {
        str(path.relative_to(directory)): digest(path)
        for path in directory.rglob('*')
        if 'node_modules' not in path.relative_to(directory).parts
        and path.is_file() and not path.is_symlink()
    }


def prepare(directory, package, files, options):
    directory.mkdir(parents=True)
    (directory / 'node_modules').mkdir()
    (directory / 'node_modules/typescript').symlink_to(package, target_is_directory=True)
    for name, source in files.items():
        (directory / name).write_text(source + '\n')
    (directory / 'tsconfig.json').write_text(json.dumps({
        'compilerOptions': options, 'files': list(files),
    }, indent=2) + '\n')


def run(executable, directory, engine, phase):
    before = project_files(directory)
    result = subprocess.run(
        [str(executable), '--project', 'tsconfig.json', '--pretty', 'false'],
        cwd=directory, capture_output=True, text=True, timeout=90,
    )
    output = result.stdout + result.stderr
    return {
        'engine': engine, 'phase': phase, 'exit': result.returncode,
        'diagnostics': sorted(
            (Path(path).name, int(line), int(column), int(code))
            for path, line, column, code in DIAGNOSTIC.findall(output)
        ),
        'diagnostic_count': len(re.findall(r'error TS\d+:', output)),
        'stdout': result.stdout, 'stderr': result.stderr,
        'inputs': before, 'files_after': project_files(directory),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('home', 'reference', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    reference = args.reference.resolve()
    package = reference.parent.parent
    if not (package / 'package.json').is_file():
        raise SystemExit('Reference must be installed typescript/bin/tsc')
    compilers = {'reference': reference, 'home': args.home.resolve()}
    report = {
        'compiler_hashes': {name: digest(path) for name, path in compilers.items()},
        'observations': [], 'failures': [], 'passed': False,
    }

    def save():
        (root / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')

    for engine, executable in compilers.items():
        directory = root / engine
        prepare(directory, package, FILES, {
            **OPTIONS, 'declaration': True, 'emitDeclarationOnly': True, 'outDir': 'out',
        })
        row = run(executable, directory, engine, 'emit')
        report['observations'].append(row)
        outputs = [directory / 'out' / name for name in ('entry.d.ts', 'owner.d.ts')]
        present = all(path.is_file() for path in outputs)
        allowed = set(row['inputs']) | {'out/entry.d.ts', 'out/owner.d.ts'}
        row['unchanged'] = all(
            row['files_after'].get(path) == value for path, value in row['inputs'].items()
        )
        if row['exit'] or not present or not row['unchanged'] or set(row['files_after']) != allowed:
            report['failures'].append(engine + '-emit')
        if present:
            row['outputs'] = {path.name: digest(path) for path in outputs}
            if outputs[0].read_text().count('import("./owner")') != 7:
                report['failures'].append(engine + '-module-identities')
            for mode, source, codes in (
                ('positive', POSITIVE, []),
                ('negative', NEGATIVE, [2322] * 4 + [2345] * 6 + [2344]),
            ):
                consumer = directory / mode
                prepare(consumer, package, {
                    'consumer.ts': source, 'globals.d.ts': GLOBALS,
                }, {**OPTIONS, 'noEmit': True})
                for path in outputs:
                    shutil.copy2(path, consumer / path.name)
                checked = run(reference, consumer, engine, mode)
                checked['unchanged'] = checked['inputs'] == checked['files_after']
                report['observations'].append(checked)
                if (checked['exit'] != int(bool(codes))
                        or sorted(item[3] for item in checked['diagnostics']) != sorted(codes)
                        or checked['diagnostic_count'] != len(codes)
                        or not checked['unchanged']):
                    report['failures'].append(engine + '-' + mode)
        save()
    for phase in ('positive', 'negative'):
        rows = [row for row in report['observations'] if row['phase'] == phase]
        if len(rows) != 2 or rows[0]['diagnostics'] != rows[1]['diagnostics']:
            report['failures'].append(phase + '-locations')
    report['passed'] = not report['failures']
    save()
    if not report['passed']:
        raise SystemExit('Failed: ' + ', '.join(report['failures']))
    print('All six declaration emit and native consumer observations passed')


if __name__ == '__main__':
    main()
