"""Prevent recursive-generic coverage or negative-control weakening."""

import unittest

import audit_globals
import audit_recursive_generics


class RecursiveGenericAuditTests(unittest.TestCase):
    def test_families_and_placements_are_retained(self):
        cases = audit_recursive_generics.cases()
        self.assertEqual(192, len(cases))
        self.assertEqual(192, len({(case.family, case.name) for case in cases}))
        self.assertEqual({"fixed-depth-8", "growing-array-depth-1", "growing-array-depth-4",
                          "growing-array-depth-12", "growing-object-depth-4", "mutual-growing-depth-4",
                          "flipped-parameters", "recursive-return", "recursive-array-member",
                          "recursive-optional-union", "recursive-indexed-access", "recursive-keyof",
                          "recursive-inference", "recursive-destructuring", "finite-structural-target",
                          "distinct-recursive-origins"}, {case.family for case in cases})
        self.assertEqual({"local", "named", "namespace"}, {case.name.split("/")[0] for case in cases})

    def test_negative_controls_only_append_invalid_uses(self):
        cases = audit_recursive_generics.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertEqual(("2322",), negative.expected)
            self.assertEqual(positive.files.keys(), negative.files.keys())
            self.assertEqual(audit_globals.project_config(positive), audit_globals.project_config(negative))
            for filename, source in positive.files.items():
                if filename.endswith("app.ts"):
                    self.assertTrue(negative.files[filename].startswith(source))
                    self.assertNotEqual(source, negative.files[filename])
                else:
                    self.assertEqual(source, negative.files[filename])

    def test_root_order_preserves_inputs_and_expectations(self):
        cases = audit_recursive_generics.cases()
        for start in range(0, len(cases), 4):
            for before, after in zip(cases[start:start + 2], cases[start + 2:start + 4]):
                self.assertEqual(before.expected, after.expected)
                self.assertEqual(before.files["0-app.ts"], after.files["z-app.ts"])
                self.assertEqual(before.files["a-owner.ts"], after.files["a-owner.ts"])


if __name__ == "__main__":
    unittest.main()
