#!/usr/bin/env python3
"""Copy pinned root installation inputs and complete workspaces for Bun's suite.

Read Git objects, never generated/modified files from the upstream checkout.
The test/ corpus itself is maintained by sync-bun-tests.sh. This tool does not
install packages or claim setup/execution success.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bun-repo', type=Path, default=Path.home() / 'Code/bun')
    parser.add_argument('--check', action='store_true', help='verify every pinned input without modifying files')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    destination = root / 'packages/runtime/test'
    pin = (destination / 'test/UPSTREAM_SHA.txt').read_text().strip()

    def git(*command):
        return subprocess.check_output(['git', '-C', str(args.bun_repo), *command])

    # The pin, rather than the checkout's current HEAD, is authoritative.
    revision = git('rev-parse', '--verify', pin + '^{commit}').decode().strip()
    if revision != pin:
        raise ValueError('corpus pin must be a full commit id')
    package_bytes = git('show', f'{pin}:package.json')
    package = json.loads(package_bytes)
    workspaces = package['workspaces']
    if not isinstance(workspaces, list):
        raise ValueError('unsupported workspace declaration; audit the new pin')
    prefixes = []
    for workspace in workspaces:
        path = PurePosixPath(workspace)
        if path.is_absolute() or '..' in path.parts or any(c in workspace for c in '*?['):
            raise ValueError('workspace requires explicit expansion audit: ' + workspace)
        prefixes.append(str(path) + '/')
    tree = git('ls-tree', '-rz', pin).split(b'\0')
    root_inputs = {'package.json', 'bun.lock', 'bun.lockb', 'bunfig.toml',
                   'bunfig.node-test.toml', 'tsconfig.json', '.npmrc'}
    entries = []
    for row in tree:
        if not row:
            continue
        metadata, raw_path = row.split(b'\t', 1)
        path = raw_path.decode()
        if path not in root_inputs and not any(path.startswith(p) for p in prefixes):
            continue
        mode, kind, object_id = metadata.decode().split()
        if kind != 'blob' or mode not in ('100644', '100755'):
            raise ValueError('unsupported setup entry requires audit: ' + path)
        entries.append((path, mode, object_id))
    paths = {entry[0] for entry in entries}
    for required in ['package.json', 'bunfig.toml', 'bunfig.node-test.toml', *[p + 'package.json' for p in prefixes]]:
        if required not in paths:
            raise ValueError('missing required setup input: ' + required)
    if not paths.intersection({'bun.lock', 'bun.lockb'}):
        raise ValueError('missing pinned lockfile')
    # Extra root install/config inputs can change the graph despite matching
    # hashes for the copied files. Report them; never delete local source.
    for name in sorted(root_inputs - paths):
        target = destination / name
        if target.exists() or target.is_symlink():
            raise ValueError('unexpected root setup input absent from pin: ' + name)
    # Read and validate every object before updating the mirror.
    payloads = [(path, mode, oid, git('cat-file', 'blob', oid)) for path, mode, oid in entries]
    records = []
    for path, mode, oid, data in payloads:
        target = destination / path
        if target.is_symlink():
            raise ValueError('setup input must be a regular source file: ' + path)
        if args.check:
            if not target.is_file() or target.read_bytes() != data:
                raise ValueError('setup input differs from pin: ' + path)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o755 if mode == '100755' else 0o644)
        records.append(dict(path=path, mode=mode, git_blob=oid, bytes=len(data),
                            sha256=hashlib.sha256(data).hexdigest()))
    manifest = dict(bun_pin=pin, scope='pinned root installation inputs and complete declared workspaces',
                    installation_performed=False, workspaces=workspaces, files=records)
    manifest_path = destination / 'BUN_SETUP_FILES.json'
    if args.check:
        if json.loads(manifest_path.read_text()) != manifest:
            raise ValueError('setup provenance manifest differs from pinned inputs')
    else:
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    action = 'Verified' if args.check else 'Mirrored'
    print(f'{action} {len(records)} pinned setup files and {len(workspaces)} complete workspaces; no install executed')


if __name__ == '__main__':
    main()
