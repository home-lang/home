"""Fairness invariants for imported static-value consumer controls."""

import unittest

import audit_globals
import audit_static_values


class StaticValueAuditTests(unittest.TestCase):
    def test_all_import_and_consumer_families_are_retained(self):
        cases = audit_static_values.cases()
        self.assertEqual(68, len(cases))
        self.assertEqual(68, len({(case.family, case.name) for case in cases}))
        self.assertEqual({"named", "named-alias", "default", "namespace", "captured-namespace",
                          "destructured-namespace", "element-namespace", "namespace-default", "namespace-reexport",
                          "mixed-exports", "namespace-name-isolation", "named-shadow", "namespace-shadow",
                          "private-static-identity", "namespace-visibility", "type-only-import", "type-only-export"},
                         {case.family for case in cases})

    def test_negative_controls_only_append_invalid_uses(self):
        cases = audit_static_values.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertTrue(negative.expected)
            self.assertEqual(positive.files.keys(), negative.files.keys())
            self.assertEqual(audit_globals.project_config(positive), audit_globals.project_config(negative))
            for filename, source in positive.files.items():
                if filename.endswith("app.ts"):
                    self.assertTrue(negative.files[filename].startswith(source))
                    self.assertNotEqual(source, negative.files[filename])
                else:
                    self.assertEqual(source, negative.files[filename])

    def test_root_order_does_not_change_expectations(self):
        cases = audit_static_values.cases()
        for start in range(0, len(cases), 4):
            for before, after in zip(cases[start:start + 2], cases[start + 2:start + 4]):
                self.assertEqual(before.expected, after.expected)
                self.assertEqual(before.files["0-app.ts"], after.files["z-app.ts"])
                self.assertEqual({name: value for name, value in before.files.items() if name != "0-app.ts"},
                                 {name: value for name, value in after.files.items() if name != "z-app.ts"})


if __name__ == "__main__":
    unittest.main()
