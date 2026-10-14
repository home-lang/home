#!/usr/bin/env python3
"""Exercise corpus corruption and exclusion-policy rejection in a real Git tree."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[1] / 'audit-bun-corpus-integrity.py'
spec = importlib.util.spec_from_file_location('corpus_integrity', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='home-corpus-integrity-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'bun'
        self.source.mkdir()
        self.git('init', '-q')
        fixture = self.source / 'test'
        fixture.mkdir()
        (fixture / 'original.test.js').write_text('assert.equal(realOperation(), 42);\n')
        (fixture / 'data.txt').write_bytes(b'exact fixture\0bytes\n')
        (fixture / 'run.sh').write_text('#!/bin/sh\nexit 0\n')
        (fixture / 'run.sh').chmod(0o755)
        (fixture / 'link').symlink_to('data.txt')
        expectations = b'# upstream\ntest/original.test.js [ FAIL ]\n'
        (fixture / 'expectations.txt').write_bytes(expectations)
        self.git('add', 'test')
        self.git('-c', 'user.name=Chris Breuer', '-c', 'user.email=chrisbreuer93@gmail.com',
                 'commit', '-qm', 'test: fixture tree')
        pin = self.git('rev-parse', 'HEAD').strip()
        self.mirror = self.root / 'home/packages/runtime/test/test'
        self.mirror.mkdir(parents=True)
        for name in ['original.test.js', 'data.txt', 'run.sh', 'expectations.txt']:
            (self.mirror / name).write_bytes((fixture / name).read_bytes())
        (self.mirror / 'run.sh').chmod(0o755)
        (self.mirror / 'link').symlink_to('data.txt')
        self.names = sorted(path.name for path in fixture.iterdir())
        (self.mirror / 'BUN_TRACKED_FILES.txt').write_text('\n'.join(self.names) + '\n')
        (self.mirror / 'UPSTREAM_SHA.txt').write_text(pin + '\n')
        (self.mirror / 'UPSTREAM_EXPECTATIONS.txt').write_bytes(expectations)
        self.original_root = module.ROOT
        module.ROOT = self.root / 'home'
        self.addCleanup(setattr, module, 'ROOT', self.original_root)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.source), *args], text=True)

    def audit(self):
        return module.audit(self.source, 'git')

    def test_exact_tree_and_removed_exclusion(self):
        self.assertTrue(self.audit()['valid'])
        (self.mirror / 'expectations.txt').write_text('# upstream\n')
        result = self.audit()
        self.assertTrue(result['valid'])
        self.assertEqual(result['removed_expectations'], ['test/original.test.js [ FAIL ]'])

    def test_modified_assertion_and_fixture_are_rejected(self):
        for name in ['original.test.js', 'data.txt']:
            with self.subTest(name=name):
                path = self.mirror / name
                original = path.read_bytes()
                path.write_bytes(b'changed\n')
                self.assertFalse(self.audit()['valid'])
                path.write_bytes(original)

    def test_symlink_target_and_executable_mode_are_rejected(self):
        link = self.mirror / 'link'
        link.unlink()
        link.symlink_to('original.test.js')
        self.assertFalse(self.audit()['valid'])
        link.unlink()
        link.symlink_to('data.txt')
        if os.name != 'nt':
            (self.mirror / 'run.sh').chmod(0o644)
            self.assertFalse(self.audit()['valid'])

    def test_added_exclusion_and_altered_reference_are_rejected(self):
        (self.mirror / 'expectations.txt').write_text('# upstream\ntest/new.test.js [ SKIP ]\n')
        self.assertFalse(self.audit()['valid'])
        (self.mirror / 'expectations.txt').write_bytes((self.source / 'test/expectations.txt').read_bytes())
        (self.mirror / 'UPSTREAM_EXPECTATIONS.txt').write_text('changed\n')
        self.assertFalse(self.audit()['valid'])

    def test_missing_and_duplicate_manifest_entries_are_rejected(self):
        manifest = self.mirror / 'BUN_TRACKED_FILES.txt'
        manifest.write_text('\n'.join(self.names[1:]) + '\n')
        self.assertFalse(self.audit()['valid'])
        manifest.write_text('\n'.join(self.names + [self.names[0]]) + '\n')
        self.assertFalse(self.audit()['valid'])

    def test_assertion_revision_cannot_be_declared_as_fixture_maintenance(self):
        manifest = self.mirror.parent / 'HOME_FIXTURE_REVISIONS.json'
        manifest.write_text(json.dumps({'upstream': (self.mirror / 'UPSTREAM_SHA.txt').read_text().strip(),
                                        'revisions': [{'path': 'original.test.js'}]}))
        with self.assertRaises(ValueError):
            self.audit()


if __name__ == '__main__':
    unittest.main()
