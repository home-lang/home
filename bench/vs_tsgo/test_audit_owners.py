"""Fairness/coverage tests for the imported-owner audit; compiler tests are CLI."""

import json
import unittest

import audit_globals
import audit_owners


class OwnerAuditTests(unittest.TestCase):
    def test_all_owner_families_remain_in_default(self):
        cases = audit_owners.cases()
        self.assertEqual(20, len(cases))
        self.assertEqual(20, len({(case.family, case.name) for case in cases}))
        self.assertEqual({"generic", "predicate", "private-origin", "rest", "readonly"}, {case.family for case in cases})
        for family in {case.family for case in cases}:
            self.assertEqual(4, len(audit_owners.cases(family)))

    def test_pairs_change_only_appended_invalid_statements(self):
        cases = audit_owners.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertTrue(negative.expected)
            self.assertEqual(positive.files.keys(), negative.files.keys())
            for filename in positive.files:
                if filename.endswith("app.ts"):
                    self.assertTrue(negative.files[filename].startswith(positive.files[filename]))
                    self.assertNotEqual(positive.files[filename], negative.files[filename])
                else:
                    self.assertEqual(positive.files[filename], negative.files[filename])

    def test_root_order_changes_neither_inputs_nor_expectations(self):
        cases = audit_owners.cases()
        for start in range(0, len(cases), 4):
            for before, after in zip(cases[start:start + 2], cases[start + 2:start + 4]):
                self.assertEqual(before.expected, after.expected)
                self.assertEqual(before.files["0-app.ts"], after.files["z-app.ts"])
                for filename in ("a-first.ts", "b-second.ts"):
                    self.assertEqual(before.files[filename], after.files[filename])
                before_roots = json.loads(audit_globals.project_config(before))["files"]
                after_roots = json.loads(audit_globals.project_config(after))["files"]
                self.assertLess(before_roots.index("src/0-app.ts"), before_roots.index("src/a-first.ts"))
                self.assertGreater(after_roots.index("src/z-app.ts"), after_roots.index("src/b-second.ts"))

    def test_shared_config_and_both_real_imports_are_kept(self):
        for case in audit_owners.cases():
            config = json.loads(audit_globals.project_config(case))
            self.assertTrue(config["compilerOptions"]["strict"])
            self.assertTrue(config["compilerOptions"]["noEmit"])
            self.assertTrue(config["compilerOptions"]["noLib"])
            self.assertEqual(4, len(config["files"]))
            app = next(source for filename, source in case.files.items() if filename.endswith("app.ts"))
            self.assertTrue(app.startswith(audit_owners.IMPORTS))


if __name__ == "__main__":
    unittest.main()
