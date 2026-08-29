"""Keep the factory audit's semantic contracts and appended-only controls."""

import unittest

import audit_globals
import audit_graph_types


class GraphTypeAuditTests(unittest.TestCase):
    def test_all_families_placements_and_orders_remain(self):
        cases = audit_graph_types.cases()
        self.assertEqual(240, len(cases))
        self.assertEqual(240, len({(case.family, case.name) for case in cases}))
        self.assertEqual({"annotated-interface", "inferred-factory-return", "missing-member", "readonly-result",
                          "explicit-call-argument", "constraint", "required-arity", "ordinary-argument",
                          "dependent-default", "rest-argument", "captured-factory", "owner-name-collision"},
                         {case.family for case in cases})
        self.assertEqual({"local", "named", "namespace", "barrel-named", "barrel-namespace"},
                         {case.name.split("/")[0] for case in cases})

    def test_negatives_only_append_to_the_same_positive_program(self):
        cases = audit_graph_types.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertEqual(1, len(negative.expected))
            self.assertEqual(positive.files.keys(), negative.files.keys())
            self.assertEqual(audit_globals.project_config(positive), audit_globals.project_config(negative))
            for name, source in positive.files.items():
                if name.endswith("app.ts"):
                    self.assertTrue(negative.files[name].startswith(source))
                    self.assertNotEqual(source, negative.files[name])
                else:
                    self.assertEqual(source, negative.files[name])

    def test_root_order_does_not_change_sources_or_expected_diagnostics(self):
        cases = audit_graph_types.cases()
        for start in range(0, len(cases), 4):
            for before, after in zip(cases[start:start + 2], cases[start + 2:start + 4]):
                self.assertEqual(before.expected, after.expected)
                self.assertEqual(before.files["0-app.ts"], after.files["z-app.ts"])
                self.assertEqual(before.files["a-owner.ts"], after.files["a-owner.ts"])


if __name__ == "__main__":
    unittest.main()
