"""Guard static require coverage, explicit roots, and decoy controls."""

import json
import unittest

import audit_commonjs_discovery
import audit_globals


class CommonJsDiscoveryAuditTests(unittest.TestCase):
    def test_forms_roots_and_controls(self):
        cases = audit_commonjs_discovery.cases()
        self.assertEqual(44, len(cases))
        self.assertEqual(44, len({(case.family, case.name) for case in cases}))
        self.assertEqual(11, len({case.family for case in cases}))
        for case in cases:
            config = json.loads(audit_globals.project_config(case))
            self.assertTrue(config["compilerOptions"]["allowJs"])
            self.assertTrue(config["compilerOptions"]["checkJs"])
            self.assertNotIn("include", config)
            if case.name.startswith("entry-only"):
                self.assertEqual(["src/lib.d.ts", "src/entry.js"], config["files"])
            else:
                self.assertEqual(["src/lib.d.ts"] + ["src/" + name for name in sorted(case.files)], config["files"])

    def test_negative_only_appends_to_leaf(self):
        cases = audit_commonjs_discovery.cases()
        for positive, negative in zip(cases[::2], cases[1::2]):
            self.assertEqual(positive.files.keys(), negative.files.keys())
            self.assertEqual(audit_globals.project_config(positive), audit_globals.project_config(negative))
            for path, source in positive.files.items():
                if path == "leaf.js":
                    self.assertTrue(negative.files[path].startswith(source))
                    self.assertNotEqual(source, negative.files[path])
                else:
                    self.assertEqual(source, negative.files[path])

    def test_decoys_do_not_admit_unreachable_errors(self):
        for case in audit_commonjs_discovery.cases():
            if case.family in {"comment", "string", "dynamic", "property", "multiple-arguments"}:
                if case.name == "entry-only/negative":
                    self.assertEqual((), case.expected)
                elif case.name == "all-files/negative":
                    self.assertEqual(("2322",), case.expected)


if __name__ == "__main__":
    unittest.main()
