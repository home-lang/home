"""Guard real JS roots, shared flags and appended-only CommonJS negatives."""

import json
import unittest

import audit_commonjs
import audit_globals


class CommonJsAuditTests(unittest.TestCase):
    def test_roots_and_checking_options(self):
        cases = audit_commonjs.cases()
        self.assertEqual(66, len(cases))
        self.assertEqual(66, len({(case.family, case.name) for case in cases}))
        self.assertEqual(11, len({case.family for case in cases}))
        for case in cases:
            config = json.loads(audit_globals.project_config(case))
            self.assertTrue(config["compilerOptions"]["allowJs"])
            self.assertTrue(config["compilerOptions"]["checkJs"])
            self.assertEqual(["src/lib.d.ts"] + ["src/" + name for name in sorted(case.files)], config["files"])
            self.assertNotIn("include", config)

    def test_controls_only_append_to_identical_programs(self):
        cases = audit_commonjs.cases()
        for start in range(0, len(cases), 3):
            positive = cases[start]
            self.assertEqual((), positive.expected)
            for negative in cases[start + 1:start + 3]:
                self.assertEqual(1, len(negative.expected))
                self.assertEqual(audit_globals.project_config(positive), audit_globals.project_config(negative))
                self.assertEqual(positive.files.keys(), negative.files.keys())
                for path, source in positive.files.items():
                    self.assertTrue(negative.files[path].startswith(source))
                    if path == "owner.js":
                        self.assertEqual(source, negative.files[path])
                    else:
                        self.assertNotEqual(source, negative.files[path])

    def test_root_order_preserves_contents_and_diagnostics(self):
        cases = audit_commonjs.cases()
        for start in range(0, len(cases), 6):
            for before, after in zip(cases[start:start + 3], cases[start + 3:start + 6]):
                self.assertEqual(before.files["0-app.js"], after.files["z-app.js"])
                self.assertEqual(before.files["owner.js"], after.files["owner.js"])
                self.assertEqual(before.expected, after.expected)


if __name__ == "__main__":
    unittest.main()
