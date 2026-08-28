"""Keep nominal controls paired, root-order independent, and comprehensive."""

import json
import unittest

import audit_globals
import audit_nominal_origins


class NominalOriginAuditTests(unittest.TestCase):
    def test_all_families_remain_in_default(self):
        cases = audit_nominal_origins.cases()
        self.assertEqual(52, len(cases))
        self.assertEqual(52, len({(case.family, case.name) for case in cases}))
        self.assertEqual({
            "private-direct", "private-static", "private-nested", "private-array", "private-function",
            "private-generic", "private-alias", "private-public-surface", "public-structural", "private-keyof",
            "protected-direct", "private-inherited", "protected-inherited",
        }, {case.family for case in cases})
        for family in {case.family for case in cases}:
            self.assertEqual(4, len(audit_nominal_origins.cases(family)))

    def test_pairs_only_append_invalid_uses_to_identical_projects(self):
        cases = audit_nominal_origins.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertTrue(negative.expected)
            self.assertEqual(positive.files.keys(), negative.files.keys())
            self.assertEqual(audit_globals.project_config(positive), audit_globals.project_config(negative))
            for filename, source in positive.files.items():
                if filename.endswith("app.ts"):
                    self.assertTrue(source.startswith(audit_nominal_origins.IMPORTS))
                    self.assertTrue(negative.files[filename].startswith(source))
                    self.assertNotEqual(source, negative.files[filename])
                else:
                    self.assertEqual(source, negative.files[filename])

    def test_root_order_changes_neither_source_nor_expectations(self):
        cases = audit_nominal_origins.cases()
        for start in range(0, len(cases), 4):
            for before, after in zip(cases[start:start + 2], cases[start + 2:start + 4]):
                self.assertEqual(before.expected, after.expected)
                self.assertEqual(before.files["0-app.ts"], after.files["z-app.ts"])
                self.assertEqual({name: source for name, source in before.files.items() if name != "0-app.ts"},
                                 {name: source for name, source in after.files.items() if name != "z-app.ts"})
                before_config = json.loads(audit_globals.project_config(before))
                after_config = json.loads(audit_globals.project_config(after))
                self.assertEqual(before_config["compilerOptions"], after_config["compilerOptions"])
                self.assertLess(before_config["files"].index("src/0-app.ts"), before_config["files"].index("src/a-first.ts"))
                self.assertGreater(after_config["files"].index("src/z-app.ts"), after_config["files"].index("src/b-second.ts"))


if __name__ == "__main__":
    unittest.main()
