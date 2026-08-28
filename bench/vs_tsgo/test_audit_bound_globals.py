"""Keep ownership discovery controls paired, ordered and semantically strict."""

import json
import unittest

from audit_bound_globals import cases
from audit_globals import project_config


class BoundGlobalAuditTests(unittest.TestCase):
    def test_cases_keep_type_rejections_and_both_orders(self):
        all_cases = cases()
        self.assertEqual(56, len(all_cases))
        self.assertEqual(56, len({case.name for case in all_cases}))
        self.assertEqual(12, sum(case.expected == ("2322",) for case in all_cases))
        for case in all_cases:
            roots = json.loads(project_config(case))["files"]
            before = "/before/" in case.name
            sibling = "a-definitions.ts" if before else "z-definitions.ts"
            self.assertEqual(before, roots.index("src/" + sibling) < roots.index("src/app.ts"))
            positive = next(other for other in all_cases if other.name == case.name.rsplit("/", 1)[0] + "/positive")
            self.assertEqual(positive.files[sibling], case.files[sibling])
            self.assertTrue(case.files["app.ts"].startswith(positive.files["app.ts"]))
            if not case.name.endswith("/positive"):
                self.assertTrue(case.expected)


if __name__ == "__main__":
    unittest.main()
