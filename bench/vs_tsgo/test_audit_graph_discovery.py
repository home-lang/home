"""Discovery controls must not mask missing files with an all-files root set."""

import json
import unittest

import audit_globals
import audit_graph_discovery


class GraphDiscoveryAuditTests(unittest.TestCase):
    def test_all_export_forms_root_modes_and_controls_remain_present(self):
        cases = audit_graph_discovery.cases()
        self.assertEqual(28, len(cases))
        self.assertEqual(28, len({(case.family, case.name) for case in cases}))
        self.assertEqual({"import", "named", "star", "namespace", "type-only", "cycle", "diamond"},
                         {case.family for case in cases})
        for entry_positive, entry_negative, all_positive, all_negative in zip(
            cases[::4], cases[1::4], cases[2::4], cases[3::4],
        ):
            self.assertEqual(entry_positive.files, all_positive.files)
            self.assertEqual(entry_negative.files, all_negative.files)
            for positive, negative in ((entry_positive, entry_negative), (all_positive, all_negative)):
                self.assertEqual((), positive.expected)
                self.assertEqual(("2322",), negative.expected)
                self.assertEqual(positive.files.keys(), negative.files.keys())
                for path, source in positive.files.items():
                    if path == "leaf.ts":
                        self.assertEqual(source + "export const invalid: string = answer;\n", negative.files[path])
                    else:
                        self.assertEqual(source, negative.files[path])

    def test_entry_only_does_not_silently_include_the_leaf(self):
        for case in audit_graph_discovery.cases():
            config = json.loads(audit_globals.project_config(case))
            self.assertNotIn("include", config)
            if case.name.startswith("entry-only/"):
                self.assertEqual(["src/lib.d.ts", "src/entry.ts"], config["files"])
            else:
                self.assertEqual(["src/lib.d.ts"] + [f"src/{name}" for name in sorted(case.files)], config["files"])


if __name__ == "__main__":
    unittest.main()
