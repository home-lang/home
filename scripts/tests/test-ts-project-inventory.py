#!/usr/bin/env python3
"""Hermetic coverage controls for the local-project replacement inventory."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "ts-project-inventory.py"
SPEC = importlib.util.spec_from_file_location("ts_project_inventory", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, filename, content):
        path = self.root / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def manifest(self, filename, scripts):
        return self.write(filename, json.dumps({"scripts": scripts}))

    def test_keeps_frameworks_fixtures_and_nested_packages(self):
        self.manifest("package.json", {"typecheck": "bun x --bun tsc --noEmit -p storage/framework/tsconfig.framework.json --pretty false"})
        config = self.write("storage/framework/tsconfig.framework.json", "{}")
        self.write("tests/fixtures/tsconfig.json", "{}")
        self.write("build/tsconfig.json", "{}")
        self.manifest("packages/core/package.json", {"build": "tsc --declaration --emitDeclarationOnly"})
        report = MODULE.inventory(self.root)
        self.assertEqual(report["counts"]["manifests_with_check_scripts"], 2)
        self.assertEqual(report["counts"]["configs"], 3)
        self.assertEqual(report["counts"]["tsc_segments"], 2)
        self.assertFalse(report["replacement_verified"])
        self.assertTrue(next(row for row in report["configs"] if row["path"] == str(config.relative_to(self.root)))["sha256"])

    def test_prunes_dependencies_and_task_outputs_but_records_symlinks(self):
        for name in MODULE.PRUNED_NAMES:
            self.manifest(name + "/package.json", {"typecheck": "tsc"})
            self.write(name + "/tsconfig.json", "{}")
        self.manifest("actual/package.json", {"typecheck": "tsc"})
        (self.root / "linked-project").symlink_to(self.root / "actual", target_is_directory=True)
        report = MODULE.inventory(self.root)
        self.assertEqual(report["counts"]["manifests_with_check_scripts"], 1)
        self.assertEqual(report["symlink_directories"], ["linked-project"])
        self.assertEqual(report["counts"]["configs"], 0)

    def test_retains_indirect_wrappers_and_shell_context_for_review(self):
        self.manifest("package.json", {
            "typecheck": "sh scripts/typecheck.sh",
            "typecheck:scoped": "(cd packages/core && bun tsc --noEmit)",
            "typecheck:variable": 'bun tsc -p "$PROJECT"',
            "typecheck:message": "echo tsc",
        })
        report = MODULE.inventory(self.root)
        self.assertEqual(report["counts"]["unresolved_scripts"], 4)
        self.assertFalse(report["replacement_verified"])
        self.assertTrue(all(row["requires_review"] for row in report["manifests"][0]["entrypoints"]))

    def test_distinguishes_compiler_tokens_and_retains_js_shims(self):
        self.manifest("package.json", {"build": "vue-tsc && tsc-alias && node node_modules/typescript/lib/tsc.js", "check": "tsc --noEmit"})
        entries = MODULE.inventory(self.root)["manifests"][0]["entrypoints"]
        self.assertEqual([row["name"] for row in entries], ["build", "check"])
        self.assertEqual(entries[0]["requires_review"], ["indirect checker or wrapper"])
        self.assertEqual(entries[1]["compiler_segments"], [{"prefix": [], "args": ["--noEmit"]}])

    def test_preserves_multiple_commands_and_quoted_projects(self):
        self.manifest("package.json", {"check": 'bun build src.ts && bunx --bun tsc --noEmit -p "config with spaces.json" && tsc --noEmit -p second.json'})
        entry = MODULE.inventory(self.root)["manifests"][0]["entrypoints"][0]
        self.assertEqual(len(entry["compiler_segments"]), 2)
        self.assertEqual(entry["compiler_segments"][0]["args"], ["--noEmit", "-p", "config with spaces.json"])
        self.assertFalse(entry["requires_review"])

    def test_invalid_manifests_and_shell_scripts_cannot_count_as_success(self):
        self.write("broken/package.json", "not json")
        self.manifest("other/package.json", {"typecheck": "tsc 'unterminated"})
        report = MODULE.inventory(self.root)
        self.assertEqual(report["counts"]["errors"], 1)
        self.assertEqual(report["counts"]["unresolved_scripts"], 1)
        self.assertFalse(report["replacement_verified"])


if __name__ == "__main__":
    unittest.main()
