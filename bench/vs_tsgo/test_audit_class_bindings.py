"""Fairness invariants for source-owned class binding controls."""

import unittest

import audit_class_bindings
import audit_globals


class ClassBindingAuditTests(unittest.TestCase):
    def test_families_are_retained(self):
        cases = audit_class_bindings.cases()
        self.assertEqual(52, len(cases))
        self.assertEqual(52, len({(case.family, case.name) for case in cases}))
        self.assertEqual({"local-alias", "named-barrel", "star-barrel", "cyclic-barrel", "default-alias",
                          "same-file-alias", "static-instance-domain", "comment-members", "keyword-members",
                          "explicit-shadow", "namespace-visibility", "type-only-export", "type-only-import"},
                         {case.family for case in cases})

    def test_only_invalid_uses_differ_between_controls(self):
        cases = audit_class_bindings.cases()
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

    def test_root_order_preserves_source_and_expected_errors(self):
        cases = audit_class_bindings.cases()
        for start in range(0, len(cases), 4):
            for before, after in zip(cases[start:start + 2], cases[start + 2:start + 4]):
                self.assertEqual(before.expected, after.expected)
                self.assertEqual(before.files["0-app.ts"], after.files["z-app.ts"])
                self.assertEqual({name: value for name, value in before.files.items() if name != "0-app.ts"},
                                 {name: value for name, value in after.files.items() if name != "z-app.ts"})


if __name__ == "__main__":
    unittest.main()
