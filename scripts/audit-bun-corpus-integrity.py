#!/usr/bin/env python3
"""Audit pinned blobs, adopted upstream TLS fixtures and removal-only expectations."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def audit(source, git):
    mirror = ROOT / 'packages/runtime/test/test'
    pin = (mirror / 'UPSTREAM_SHA.txt').read_text().strip()
    revision_path = mirror.parent / 'HOME_FIXTURE_REVISIONS.json'
    revision_manifest = json.loads(revision_path.read_text()) if revision_path.exists() else {'upstream': pin, 'revisions': []}
    if revision_manifest['upstream'] != pin:
        raise ValueError('fixture revision manifest targets a different pin')
    allowed = {'js/node/http/fixtures/openssl_localhost.' + suffix for suffix in ('crt', 'key')}
    allowed.add('js/node/http/fixtures/openssl_localhost_ca.pem')
    revisions = {}
    for row in revision_manifest['revisions']:
        if row['path'] not in allowed or row['path'] in revisions:
            raise ValueError('only explicitly adopted upstream TLS fixture revisions are permitted')
        revisions[row['path']] = row
    tree = subprocess.check_output([git, '-C', str(source), 'ls-tree', '-rz', pin, 'test/'])
    entries, errors, removed = [], [], []
    byte_count = 0
    for record in tree.split(b'\0'):
        if not record:
            continue
        meta, raw_name = record.split(b'\t', 1)
        mode, kind, expected = meta.split()
        name = os.fsdecode(raw_name)[5:]
        entries.append(name)
        path = mirror / name
        if kind != b'blob':
            errors.append({'path': name, 'reason': 'upstream entry is not a blob'})
            continue
        try:
            if mode == b'120000':
                data = os.fsencode(os.readlink(path))
                size = len(data)
                actual = hashlib.sha1(b'blob ' + str(size).encode() + b'\0' + data).hexdigest()
            else:
                if path.is_symlink():
                    raise ValueError('regular upstream blob replaced by a symlink')
                size = path.stat().st_size
                digest = hashlib.sha1(b'blob ' + str(size).encode() + b'\0')
                with path.open('rb') as stream:
                    while chunk := stream.read(1024 * 1024):
                        digest.update(chunk)
                actual = digest.hexdigest()
                executable = bool(path.stat().st_mode & 0o111)
                if os.name != 'nt' and executable != (mode == b'100755'):
                    errors.append({'path': name, 'reason': 'executable mode differs from pin'})
            byte_count += size
            if name == 'expectations.txt':
                reference = (mirror / 'UPSTREAM_EXPECTATIONS.txt').read_bytes()
                reference_blob = hashlib.sha1(b'blob ' + str(len(reference)).encode() + b'\0' + reference).hexdigest()
                if reference_blob != expected.decode():
                    raise ValueError('upstream expectation reference differs from pin')
                original = Counter(reference.splitlines(keepends=True))
                current = Counter(path.read_bytes().splitlines(keepends=True))
                if current - original:
                    raise ValueError('Home expectations contain added or modified lines')
                removed = [line.decode().rstrip('\r\n') for line in (original - current).elements()]
            elif name in revisions:
                revision = revisions[name]
                if revision['upstream_blob'] != expected.decode() or revision['maintained_blob'] != actual:
                    raise ValueError('fixture does not match the adopted revision or pinned baseline')
            elif actual != expected.decode():
                errors.append({'path': name, 'reason': 'blob differs from pin',
                               'expected': expected.decode(), 'actual': actual})
        except (OSError, ValueError) as error:
            errors.append({'path': name, 'reason': str(error)})

    tracked = (mirror / 'BUN_TRACKED_FILES.txt').read_text().splitlines()
    if set(revisions) - set(entries):
        errors.append({'path': 'HOME_FIXTURE_REVISIONS.json', 'reason': 'revision is absent from pinned inventory'})
    missing, extra = sorted(set(entries) - set(tracked)), sorted(set(tracked) - set(entries))
    if len(tracked) != len(set(tracked)):
        errors.append({'path': 'BUN_TRACKED_FILES.txt', 'reason': 'duplicate inventory entries'})
    return {'pin': pin, 'entries': len(entries), 'bytes': byte_count,
            'errors': errors, 'manifest_missing': missing, 'manifest_extra': extra,
            'removed_expectations': removed,
            'fixture_revisions': list(revisions.values()),
            'valid': not (errors or missing or extra)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path.home() / 'Code/bun')
    parser.add_argument('--git', default='git')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = audit(args.source, args.git)
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
