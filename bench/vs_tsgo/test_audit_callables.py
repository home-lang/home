"""Structural checks for the shared positive/negative callable audit."""

import unittest

import audit_callables


class CallableAuditTests(unittest.TestCase):
    def test_all_families_scopes_and_orders_remain_in_default(self):
        cases = audit_callables.cases()
        self.assertEqual(56, len(cases))
        self.assertEqual(set(audit_callables.FAMILIES), {case.family for case in cases})
        self.assertEqual(56, len({(case.family, case.name) for case in cases}))
        for family in audit_callables.FAMILIES:
            selected = audit_callables.cases(family)
            self.assertEqual(8, len(selected))
            self.assertEqual({family}, {case.family for case in selected})
            self.assertEqual({"forward", "reverse"}, {case.name.split("/")[0] for case in selected})
            self.assertEqual({"script", "module"}, {case.name.split("/")[1] for case in selected})

    def test_negative_only_appends_invalid_statements(self):
        cases = audit_callables.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertEqual(1, len(negative.expected))
            self.assertEqual(positive.family, negative.family)
            self.assertTrue(negative.files["app.ts"].startswith(positive.files["app.ts"]))
            self.assertEqual({"app.ts"}, set(positive.files))
            self.assertEqual({"app.ts"}, set(negative.files))


if __name__ == "__main__":
    unittest.main()
