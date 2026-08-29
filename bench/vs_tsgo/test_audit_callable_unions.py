"""Coverage invariants for the callable-union correctness matrix."""

import unittest

import audit_callable_unions as unions


class CallableUnionAuditTests(unittest.TestCase):
    def test_all_families_orders_shapes_and_scopes_are_required(self):
        cases = unions.cases()
        self.assertEqual(256, len(cases))
        self.assertEqual(256, len({(case.family, case.name) for case in cases}))
        self.assertEqual(set(unions.FAMILIES), {case.family for case in cases})
        for family in unions.FAMILIES:
            selected = unions.cases(family)
            self.assertEqual(64, len(selected))
            self.assertEqual({family}, {case.family for case in selected})
            self.assertEqual({"decl-forward", "decl-reverse"}, {c.name.split("/")[0] for c in selected})
            self.assertEqual({"branch-forward", "branch-reverse"}, {c.name.split("/")[1] for c in selected})
            self.assertEqual(set(unions.SHAPES), {c.name.split("/")[2] for c in selected})
            self.assertEqual({"script", "module"}, {c.name.split("/")[3] for c in selected})

    def test_negative_only_appends_invalid_statements(self):
        cases = unions.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual((), positive.expected)
            self.assertEqual(1, len(negative.expected))
            self.assertEqual(positive.family, negative.family)
            self.assertEqual({"app.ts"}, set(positive.files))
            self.assertEqual({"app.ts"}, set(negative.files))
            self.assertTrue(negative.files["app.ts"].startswith(positive.files["app.ts"]))


if __name__ == "__main__":
    unittest.main()
