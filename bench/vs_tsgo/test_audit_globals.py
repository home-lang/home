"""Unit tests for the untimed global-declaration admission audit."""

import json
import subprocess
import unittest
from unittest import mock

import audit_globals


class GlobalAuditTests(unittest.TestCase):
    def test_default_keeps_unresolved_cross_file_cases(self):
        cases = audit_globals.cases()
        self.assertEqual(60, len(cases))
        self.assertEqual(24, len(audit_globals.cases("same-file")))
        self.assertEqual(36, len(audit_globals.cases("cross-file")))
        self.assertEqual({"same-file", "cross-file"}, {case.family for case in cases})
        self.assertEqual(60, len({(case.family, case.name) for case in cases}))

    def test_cross_file_cases_cover_both_root_orders(self):
        cases = audit_globals.cases("cross-file")
        before = [case for case in cases if "/before/" in case.name]
        after = [case for case in cases if "/after/" in case.name]
        self.assertEqual(18, len(before))
        self.assertEqual(18, len(after))
        later_by_name = {case.name.replace("/after/", "/before/"): case for case in after}
        for earlier in before:
            later = later_by_name[earlier.name]
            self.assertEqual(earlier.expected, later.expected)
            self.assertEqual(earlier.files["app.ts"], later.files["app.ts"])
            before_roots = json.loads(audit_globals.project_config(earlier))["files"]
            after_roots = json.loads(audit_globals.project_config(later))["files"]
            self.assertTrue(all(
                before_roots.index(f"src/{name}") < before_roots.index("src/app.ts")
                for name in earlier.files if name != "app.ts"
            ))
            self.assertTrue(all(
                after_roots.index(f"src/{name}") > after_roots.index("src/app.ts")
                for name in later.files if name != "app.ts"
            ))

    def test_pairs_keep_declarations_and_require_negative_diagnostics(self):
        cases = audit_globals.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertTrue(negative.expected)
            self.assertEqual(positive.files.keys(), negative.files.keys())
            for filename in positive.files:
                if filename != "app.ts":
                    self.assertEqual(positive.files[filename], negative.files[filename])

    def test_diagnostic_multisets_and_exit_status_are_required(self):
        result = subprocess.CompletedProcess([], 2, "error TS2345: bad\nerror TS2322: bad\n", "")
        self.assertTrue(audit_globals.diagnostics_match(result, ("2322", "2345")))
        self.assertFalse(audit_globals.diagnostics_match(result, ("2322",)))
        result.returncode = 0
        self.assertFalse(audit_globals.diagnostics_match(result, ("2322", "2345")))
        result.returncode = -11
        self.assertFalse(audit_globals.diagnostics_match(result, ("2322", "2345")))
        result.returncode = 0
        self.assertFalse(audit_globals.diagnostics_match(result, ()))
        result.stdout = ""
        self.assertTrue(audit_globals.diagnostics_match(result, ()))

    def test_version_mismatch_stops_before_project_creation(self):
        with mock.patch.object(audit_globals.bench, "compiler_commands", return_value={}), mock.patch.object(
            audit_globals.bench, "verified_compiler_versions", side_effect=SystemExit("version mismatch")
        ), mock.patch.object(audit_globals.tempfile, "TemporaryDirectory") as temporary:
            with self.assertRaisesRegex(SystemExit, "version mismatch"):
                audit_globals.audit(audit_globals.cases())
            temporary.assert_not_called()


if __name__ == "__main__":
    unittest.main()
