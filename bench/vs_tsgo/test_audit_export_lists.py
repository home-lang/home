"""Guard export-list audit coverage and identical appended-only controls."""

import unittest

import audit_export_lists
import audit_globals


class ExportListAuditTests(unittest.TestCase):
    def test_declarations_placements_orders_and_controls(self):
        cases = audit_export_lists.cases()
        self.assertEqual(96, len(cases))
        self.assertEqual(96, len({(case.family, case.name) for case in cases}))
        self.assertEqual({"const", "let", "var", "declare-var"}, {case.family for case in cases})
        self.assertEqual({"named", "namespace", "barrel-named", "barrel-namespace"},
                         {case.name.split("/")[0] for case in cases})

    def test_each_negative_only_appends_to_the_same_program(self):
        cases = audit_export_lists.cases()
        for start in range(0, len(cases), 3):
            positive = cases[start]
            self.assertEqual((), positive.expected)
            for negative in cases[start + 1:start + 3]:
                self.assertEqual(1, len(negative.expected))
                self.assertEqual(positive.files.keys(), negative.files.keys())
                self.assertEqual(audit_globals.project_config(positive), audit_globals.project_config(negative))
                for path, source in positive.files.items():
                    if path.endswith("app.ts"):
                        self.assertTrue(negative.files[path].startswith(source))
                        self.assertNotEqual(source, negative.files[path])
                    else:
                        self.assertEqual(source, negative.files[path])

    def test_root_order_preserves_source_and_expected_errors(self):
        cases = audit_export_lists.cases()
        for start in range(0, len(cases), 6):
            for before, after in zip(cases[start:start + 3], cases[start + 3:start + 6]):
                self.assertEqual(before.expected, after.expected)
                self.assertEqual(before.files["0-app.ts"], after.files["z-app.ts"])


if __name__ == "__main__":
    unittest.main()
