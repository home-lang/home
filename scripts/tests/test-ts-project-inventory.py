#!/usr/bin/env python3
"""Hermetic coverage controls for the local-project replacement inventory."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
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

    def test_keeps_git_projects_with_dependency_or_cache_names(self):
        self.write("pantry/.git/HEAD", "ref: refs/heads/main\n")
        self.manifest("pantry/package.json", {"typecheck": "tsc --noEmit"})
        self.write("pantry/tsconfig.json", "{}")
        self.write("nested/.cache/.git", "gitdir: /some/worktree\n")
        self.manifest("nested/.cache/package.json", {"typecheck": "tsc --noEmit"})
        self.manifest("actual/pantry/package.json", {"typecheck": "tsc"})
        report = MODULE.inventory(self.root)
        self.assertEqual(report["counts"]["manifests_with_check_scripts"], 2)
        self.assertEqual(report["counts"]["configs"], 1)
        self.assertEqual(report["included_pruned_name_projects"], ["nested/.cache", "pantry"])
        self.assertFalse(report["replacement_verified"])

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

    def test_project_scope_keeps_config_only_and_invalid_manifest_projects(self):
        for name in ("scripted", "config-only", "invalid"):
            self.write(name + "/.git/HEAD", "ref: refs/heads/main\n")
        self.manifest("scripted/package.json", {"check": "tsc --noEmit"})
        self.write("scripted/tests/fixtures/tsconfig.json", "{}")
        self.manifest("config-only/package.json", {"start": "bun app.ts"})
        self.write("config-only/tsconfig.json", "{}")
        self.write("invalid/package.json", "<<<<<<< unresolved merge\n")
        scope = MODULE.project_scope(MODULE.inventory(self.root))
        self.assertEqual(scope["summary"]["manifest_script_git_groups"], 1)
        self.assertEqual(scope["summary"]["total_canonical_git_groups"], 3)
        self.assertEqual(scope["summary"]["additional_config_only_git_groups"], 1)
        self.assertEqual(scope["summary"]["additional_error_only_git_groups"], 1)
        self.assertEqual(scope["summary"]["unresolved_ownership_records"], 0)
        self.assertEqual(scope["errors"], [])
        self.assertFalse(scope["all_project_replacement_verified"])
        self.assertTrue(all(not group["replacement_verified"] for group in scope["groups"].values()))

    def test_project_scope_groups_worktrees_by_common_git_directory(self):
        self.write("main/.git/HEAD", "ref: refs/heads/main\n")
        self.write("main/.git/worktrees/linked/commondir", "../..\n")
        self.write("linked/.git", "gitdir: ../main/.git/worktrees/linked\n")
        self.write("main/tsconfig.json", "{}")
        self.write("linked/tsconfig.json", "{}")
        scope = MODULE.project_scope(MODULE.inventory(self.root))
        self.assertEqual(scope["summary"]["total_canonical_git_groups"], 1)
        group = next(iter(scope["groups"].values()))
        self.assertEqual(group["checkouts"], ["linked", "main"])
        self.assertEqual(group["counts"], {"config": 2})
        self.assertEqual(scope["errors"], [])

    def test_project_scope_retains_unversioned_sources(self):
        self.write("tsconfig.json", "{}")
        scope = MODULE.project_scope(MODULE.inventory(self.root))
        self.assertEqual(scope["summary"]["total_canonical_git_groups"], 0)
        self.assertEqual(scope["summary"]["unresolved_ownership_records"], 1)
        self.assertEqual(scope["sources"][0]["path"], "tsconfig.json")
        self.assertFalse(scope["all_project_replacement_verified"])

    def test_project_scope_reports_changed_and_deleted_inputs(self):
        changed = self.write("tsconfig.json", "{}")
        removed = self.manifest("package.json", {"check": "tsc"})
        report = MODULE.inventory(self.root)
        changed.write_text('{"compilerOptions":{"strict":true}}')
        removed.unlink()
        scope = MODULE.project_scope(report)
        self.assertEqual(scope["changed_inputs"], ["tsconfig.json"])
        self.assertEqual(scope["summary"]["input_hash_drift"], 1)
        self.assertEqual(scope["summary"]["scope_errors"], 1)
        self.assertEqual(len(scope["sources"]), 2)
        self.assertFalse(scope["all_project_replacement_verified"])

    def test_project_scope_does_not_attribute_a_broken_worktree_to_its_parent(self):
        self.write(".git/HEAD", "ref: refs/heads/main\n")
        self.write("nested/.git", "gitdir: ../missing\n")
        self.write("nested/tsconfig.json", "{}")
        scope = MODULE.project_scope(MODULE.inventory(self.root))
        self.assertEqual(scope["summary"]["total_canonical_git_groups"], 0)
        self.assertEqual(scope["summary"]["scope_errors"], 1)
        self.assertIsNone(scope["sources"][0]["owner"])

    def test_project_scope_stays_inside_inventory_root(self):
        self.write("project/.git/HEAD", "ref: refs/heads/main\n")
        self.write("project/tsconfig.json", "{}")
        report = MODULE.inventory(self.root / "project")
        report["configs"].append({"path": "../outside/tsconfig.json", "sha256": "unused"})
        scope = MODULE.project_scope(report)
        self.assertEqual(scope["summary"]["source_records"], 2)
        self.assertEqual(scope["summary"]["scope_errors"], 1)
        self.assertIsNone(scope["sources"][-1]["owner"])

    def test_project_scope_rejects_empty_common_directory_metadata(self):
        self.write("main/.git/worktrees/linked/commondir", "\n")
        self.write("linked/.git", "gitdir: ../main/.git/worktrees/linked\n")
        self.write("linked/tsconfig.json", "{}")
        scope = MODULE.project_scope(MODULE.inventory(self.root))
        self.assertEqual(scope["summary"]["total_canonical_git_groups"], 0)
        self.assertEqual(scope["summary"]["scope_errors"], 1)
        self.assertIsNone(scope["sources"][0]["owner"])

    def test_scope_cli_retains_reports_on_manifest_errors(self):
        self.write(".git/HEAD", "ref: refs/heads/main\n")
        self.write("tsconfig.json", "{}")
        inventory = self.root / "inventory.json"
        scope_path = self.root / "scope.json"
        command = [sys.executable, str(SCRIPT), "--root", str(self.root),
                   "--output", str(inventory), "--scope-output", str(scope_path)]
        clean = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertEqual(json.loads(scope_path.read_text())["summary"]["additional_config_only_git_groups"], 1)
        self.write("package.json", "<<<<<<< unresolved merge\n")
        invalid = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(invalid.returncode, 1, invalid.stderr)
        self.assertEqual(json.loads(inventory.read_text())["counts"]["errors"], 1)
        scope = json.loads(scope_path.read_text())
        self.assertEqual(scope["summary"]["total_canonical_git_groups"], 1)
        self.assertEqual(next(iter(scope["groups"].values()))["counts"], {"config": 1, "inventory-error": 1})
        self.assertFalse(scope["all_project_replacement_verified"])


if __name__ == "__main__":
    unittest.main()
