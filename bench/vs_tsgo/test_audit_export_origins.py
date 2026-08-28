"""Same-origin acceptance must retain genuine conflict and missing-name checks."""

import unittest

import audit_export_origins


class ExportOriginAuditTests(unittest.TestCase):
    def test_pairs_only_append_invalid_uses_to_identical_projects(self):
        cases = audit_export_origins.cases()
        self.assertEqual(32, len(cases))
        self.assertEqual({"1361", "2305", "2308"}, {code for case in cases for code in case.expected})
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual(positive.roots, negative.roots)
            self.assertEqual((), positive.expected)
            self.assertTrue(negative.expected)
            self.assertEqual(positive.files.keys(), negative.files.keys())
            for path, source in positive.files.items():
                if path == "entry.ts":
                    self.assertTrue(negative.files[path].startswith(source))
                    self.assertNotEqual(source, negative.files[path])
                else:
                    self.assertEqual(source, negative.files[path])


if __name__ == "__main__":
    unittest.main()
