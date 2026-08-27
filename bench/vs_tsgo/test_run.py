"""Benchmark preflight regressions; run with unittest discovery in this directory."""

import unittest
from unittest import mock

import run


class CompilerVersionTests(unittest.TestCase):
    def setUp(self):
        self.commands = {name: [name] for name in ("tsc", "tsgo", "home")}
        self.pinned = {"compilers": {"tsc": {"version": "6.0.3"}, "tsgo": {"version": "7.0.2"}}}
        self.versions = {"tsc": "Version 6.0.3", "tsgo": "Version 7.0.2", "home": "home-tsc 0.1.0"}

    def verify(self):
        with mock.patch.object(run, "manifest", return_value=self.pinned), mock.patch.object(
            run, "version_output", side_effect=lambda command: self.versions[command[0]]
        ):
            return run.verified_compiler_versions(self.commands)

    def test_exact_pins_preserve_reported_versions(self):
        self.assertEqual(self.versions, self.verify())

    def test_old_native_dev_build_is_rejected(self):
        self.versions["tsgo"] = "Version 7.0.0-dev.20260707.2"
        with self.assertRaisesRegex(SystemExit, "tsgo version mismatch"):
            self.verify()

    def test_wrong_javascript_version_is_rejected(self):
        self.versions["tsc"] = "Version 6.0.2"
        with self.assertRaisesRegex(SystemExit, "tsc version mismatch"):
            self.verify()

    def test_version_suffix_cannot_match_a_stable_pin(self):
        self.versions["tsgo"] = "Version 7.0.2-dev.1"
        with self.assertRaisesRegex(SystemExit, "tsgo version mismatch"):
            self.verify()

    def test_mismatch_stops_before_results_or_validation(self):
        with mock.patch.object(run.shutil, "which", return_value="hyperfine"), mock.patch.object(
            run, "CORPUS"
        ) as corpus, mock.patch.object(run, "compiler_commands", return_value=self.commands), mock.patch.object(
            run, "verified_compiler_versions", side_effect=SystemExit("version mismatch")
        ), mock.patch.object(run, "RESULTS") as results, mock.patch.object(run, "validate") as validate:
            corpus.is_dir.return_value = True
            with self.assertRaisesRegex(SystemExit, "version mismatch"):
                run.cmd_cold(30, 3)
            self.assertEqual([], results.mock_calls)
            validate.assert_not_called()


class WorkloadSelectionTests(unittest.TestCase):
    def setUp(self):
        self.config = {"workloads": {"first": {}, "second": {}}}

    def select(self, requested):
        with mock.patch.object(run, "manifest", return_value=self.config):
            return run.selected_workloads(requested)

    def test_default_preserves_full_manifest_order(self):
        self.assertEqual(["first", "second"], self.select(None))

    def test_subset_preserves_requested_order(self):
        self.assertEqual(["second", "first"], self.select(["second", "first"]))
        self.assertEqual(["second"], self.select(["second"]))

    def test_empty_selection_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, "at least one"):
            self.select([])

    def test_duplicate_selection_cannot_overwrite_rounds(self):
        with self.assertRaisesRegex(SystemExit, "duplicate"):
            self.select(["first", "first"])

    def test_unknown_selection_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, "unknown workload: missing"):
            self.select(["missing"])

    def test_invalid_selection_stops_before_results_or_validation(self):
        with mock.patch.object(run, "manifest", return_value=self.config), mock.patch.object(
            run, "RESULTS"
        ) as results, mock.patch.object(run, "validate") as validate, mock.patch.object(
            run, "compiler_commands"
        ) as commands:
            with self.assertRaisesRegex(SystemExit, "duplicate"):
                run.cmd_cold(30, 3, ["first", "first"])
            self.assertEqual([], results.mock_calls)
            validate.assert_not_called()
            commands.assert_not_called()


if __name__ == "__main__":
    unittest.main()
