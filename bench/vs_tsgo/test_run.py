"""Benchmark preflight regressions; run with unittest discovery in this directory."""

import unittest
import subprocess
from unittest import mock

import run


class CompilerVersionTests(unittest.TestCase):
    def setUp(self):
        self.commands = {name: [name] for name in ("tsc", "tsgo", "home")}
        self.pinned = {"compilers": {"tsc": {"version": "6.0.3"}, "tsgo": {"version": "7.0.2"}}}
        self.versions = {"tsc": "Version 6.0.3", "tsgo": "Version 7.0.2", "home": "home-tsc 0.1.0"}

    def verify(self):
        with mock.patch.object(run, "manifest", return_value=self.pinned), mock.patch.object(
            run, "version_output", side_effect=lambda command: self.versions[command[0]]
        ):
            return run.verified_compiler_versions(self.commands)

    def test_exact_pins_preserve_reported_versions(self):
        self.assertEqual(self.versions, self.verify())

    def test_old_native_dev_build_is_rejected(self):
        self.versions["tsgo"] = "Version 7.0.0-dev.20260707.2"
        with self.assertRaisesRegex(SystemExit, "tsgo version mismatch"):
            self.verify()

    def test_wrong_javascript_version_is_rejected(self):
        self.versions["tsc"] = "Version 6.0.2"
        with self.assertRaisesRegex(SystemExit, "tsc version mismatch"):
            self.verify()

    def test_version_suffix_cannot_match_a_stable_pin(self):
        self.versions["tsgo"] = "Version 7.0.2-dev.1"
        with self.assertRaisesRegex(SystemExit, "tsgo version mismatch"):
            self.verify()

    def test_mismatch_stops_before_results_or_validation(self):
        with mock.patch.object(run.shutil, "which", return_value="hyperfine"), mock.patch.object(
            run, "CORPUS"
        ) as corpus, mock.patch.object(run, "compiler_commands", return_value=self.commands), mock.patch.object(
            run, "verified_compiler_versions", side_effect=SystemExit("version mismatch")
        ), mock.patch.object(run, "RESULTS") as results, mock.patch.object(run, "validate") as validate:
            corpus.is_dir.return_value = True
            with self.assertRaisesRegex(SystemExit, "version mismatch"):
                run.cmd_cold(30, 3)
            self.assertEqual([], results.mock_calls)
            validate.assert_not_called()


class WorkloadSelectionTests(unittest.TestCase):
    def setUp(self):
        self.config = {"workloads": {"first": {}, "second": {}}}

    def select(self, requested):
        with mock.patch.object(run, "manifest", return_value=self.config):
            return run.selected_workloads(requested)

    def test_default_preserves_full_manifest_order(self):
        self.assertEqual(["first", "second"], self.select(None))

    def test_subset_preserves_requested_order(self):
        self.assertEqual(["second", "first"], self.select(["second", "first"]))
        self.assertEqual(["second"], self.select(["second"]))

    def test_empty_selection_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, "at least one"):
            self.select([])

    def test_duplicate_selection_cannot_overwrite_rounds(self):
        with self.assertRaisesRegex(SystemExit, "duplicate"):
            self.select(["first", "first"])

    def test_unknown_selection_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, "unknown workload: missing"):
            self.select(["missing"])

    def test_invalid_selection_stops_before_results_or_validation(self):
        with mock.patch.object(run, "manifest", return_value=self.config), mock.patch.object(
            run, "RESULTS"
        ) as results, mock.patch.object(run, "validate") as validate, mock.patch.object(
            run, "compiler_commands"
        ) as commands:
            with self.assertRaisesRegex(SystemExit, "duplicate"):
                run.cmd_cold(30, 3, ["first", "first"])
            self.assertEqual([], results.mock_calls)
            validate.assert_not_called()
            commands.assert_not_called()


class RecursiveGenericWorkloadTests(unittest.TestCase):
    def setUp(self):
        config = {"generated": {"recursive_generic_families": 256}}
        patcher = mock.patch.object(run, "manifest", return_value=config)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_generator_retains_distinct_arguments_and_concrete_uses(self):
        with mock.patch.object(run, "write") as write:
            run.generate_recursive_generics(run.Path("project"), 3)
        sources = {str(call.args[0]): call.args[1] for call in write.call_args_list}
        self.assertIn("next: Link<T[]>", sources["project/src/owner.ts"])
        consumer = sources["project/src/recursive-generics.ts"]
        for index in range(3):
            self.assertIn(f"readonly tag{index}: string", consumer)
            self.assertIn(f"Box<Payload{index}>", consumer)
            self.assertIn(f"Payload{index}[][][][] = selected{index}", consumer)
            self.assertIn(f"selected{index}[0][0][0][0].id", consumer)
        self.assertEqual(3, consumer.count(".value.next.next.next.next.item"))
        with self.assertRaises(ValueError):
            run.generate_recursive_generics(run.Path("project"), 0)

    def test_negative_controls_append_to_copy_and_cover_first_middle_last(self):
        complete = "error TS2322: wrong\n" * 6 + "error TS2339: missing\n" * 3
        with mock.patch.object(run.shutil, "copytree") as copy, mock.patch.object(
            run.Path, "read_text", return_value="original source\n"
        ), mock.patch.object(run, "write") as write, mock.patch.object(
            run.subprocess, "run", return_value=subprocess.CompletedProcess([], 2, complete, "")
        ):
            run.validate_recursive_generic_negatives({"home": ["home"]})
            self.assertEqual(run.CORPUS / "recursive_generics", copy.call_args.args[0])
            self.assertNotEqual(run.CORPUS / "recursive_generics/src/recursive-generics.ts", write.call_args.args[0])
            self.assertTrue(write.call_args.args[1].startswith("original source\n"))
            for index in (0, 128, 255):
                self.assertIn(f"selected{index}[0][0][0][0].id", write.call_args.args[1])
                self.assertIn(f"selected{index}[0][0][0][0].missing", write.call_args.args[1])

    def test_negative_controls_reject_partial_errors_acceptance_and_crashes(self):
        complete = "error TS2322: wrong\n" * 6 + "error TS2339: missing\n" * 3
        for code, output in ((0, ""), (0, complete), (1, "error TS2322: wrong\n"), (-11, complete), (3, complete)):
            with mock.patch.object(run.shutil, "copytree"), mock.patch.object(run.Path, "read_text", return_value="source\n"), mock.patch.object(
                run, "write"
            ), mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")):
                with self.assertRaisesRegex(SystemExit, "failed recursive_generics negative controls"):
                    run.validate_recursive_generic_negatives({"home": ["home"]})

    def test_positive_workload_requires_negative_admission(self):
        commands = {"home": ["home"]}
        with mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), mock.patch.object(
            run, "validate_recursive_generic_negatives"
        ) as negatives:
            run.validate(commands, "recursive_generics")
            negatives.assert_called_once_with(commands)

class AdmissionTests(unittest.TestCase):
    def test_legacy_graph_report_does_not_claim_an_unvalidated_win(self):
        import compare
        for workload in ("import_graph", "reexport_graph"):
            self.assertEqual("Ineligible (graph types unvalidated)", compare.format_workload_comparison(workload, 1, 2))
            self.assertEqual("**2.00× faster**", compare.format_workload_comparison(workload, 1, 2, 2))
            self.assertEqual("**2.00× faster**", compare.format_workload_comparison(workload, 1, 2, 3))
        self.assertEqual("**2.00× faster**", compare.format_workload_comparison("startup", 1, 2))

    def test_legacy_tuple_results_require_the_tuple_admission_schema(self):
        import compare
        for schema in (None, 1, 2):
            self.assertEqual("Provisional (tuple controls unvalidated)",
                             compare.format_workload_comparison("variadic_tuples", 1, 2, schema))
        self.assertEqual("**2.00× faster**", compare.format_workload_comparison("variadic_tuples", 1, 2, 3))

    def test_tuple_controls_append_to_a_copy_and_require_all_diagnostics(self):
        diagnostics = "error TS2322: wrong\n" * 5 + "error TS2493: bounds\nerror TS2540: readonly\n"
        with mock.patch.object(run.shutil, "copytree") as copy, mock.patch.object(
            run.Path, "read_text", return_value="original source\n"
        ), mock.patch.object(run, "write") as write, mock.patch.object(
            run.subprocess, "run", return_value=subprocess.CompletedProcess([], 2, diagnostics, "")
        ):
            run.validate_variadic_tuple_negatives({"home": ["home"]})
            self.assertEqual(run.CORPUS / "variadic_tuples", copy.call_args.args[0])
            self.assertNotEqual(run.CORPUS / "variadic_tuples/src/variadic-tuples.ts", write.call_args.args[0])
            self.assertTrue(write.call_args.args[1].startswith("original source\n"))
            for expression in ("combined0[0]", "Head<Tuple0>", "tail0[0]", "captured0[1]", "tupleResult0.result[2]", "combined0[5]"):
                self.assertIn(expression, write.call_args.args[1])

    def test_tuple_controls_reject_partial_errors_silent_acceptance_and_crashes(self):
        complete = "error TS2322: wrong\n" * 5 + "error TS2493: bounds\nerror TS2540: readonly\n"
        for code, output in ((0, ""), (0, complete), (1, "error TS2322: wrong\n" * 5), (-11, complete), (3, complete)):
            with mock.patch.object(run.shutil, "copytree"), mock.patch.object(run.Path, "read_text", return_value="source"), mock.patch.object(
                run, "write"
            ), mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")):
                with self.assertRaisesRegex(SystemExit, "failed variadic_tuples negative controls"):
                    run.validate_variadic_tuple_negatives({"home": ["home"]})

    def test_positive_tuple_workload_is_followed_by_negative_admission(self):
        commands = {"home": ["home"]}
        with mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), mock.patch.object(
            run, "validate_variadic_tuple_negatives"
        ) as negatives:
            run.validate(commands, "variadic_tuples")
            negatives.assert_called_once_with(commands)

    def test_later_failure_stops_before_any_measurement_or_results(self):
        with mock.patch.object(run, "selected_workloads", return_value=["first", "second"]), mock.patch.object(
            run.shutil, "which", return_value="hyperfine"
        ), mock.patch.object(run, "CORPUS"), mock.patch.object(run, "compiler_commands", return_value={}), mock.patch.object(
            run, "verified_compiler_versions", return_value={}
        ), mock.patch.object(run, "validate", side_effect=[None, SystemExit("admission failed")]) as validate, mock.patch.object(
            run, "RESULTS"
        ) as results, mock.patch.object(run.subprocess, "run") as process:
            with self.assertRaisesRegex(SystemExit, "admission failed"):
                run.cmd_cold(30, 3)
            self.assertEqual([mock.call({}, "first"), mock.call({}, "second")], validate.call_args_list)
            self.assertEqual([], results.mock_calls)
            process.assert_not_called()

    def test_graph_controls_append_to_a_copy_and_require_both_diagnostics(self):
        for workload in ("import_graph", "reexport_graph"):
            with mock.patch.object(run.shutil, "copytree") as copy, mock.patch.object(
                run.Path, "read_text", return_value="original source\n"
            ), mock.patch.object(run, "write") as write, mock.patch.object(
                run.subprocess, "run", return_value=subprocess.CompletedProcess([], 2, "error TS2339: missing\nerror TS2322: wrong\n", "")
            ):
                run.validate_graph_negatives({"home": ["home"]}, workload)
                self.assertEqual(run.CORPUS / workload, copy.call_args.args[0])
                self.assertNotEqual(run.CORPUS / workload / "src/index.ts", write.call_args.args[0])
                self.assertTrue(write.call_args.args[1].startswith("original source\n"))

    def test_graph_controls_reject_silent_acceptance_missing_errors_and_crashes(self):
        for code, output in ((0, ""), (1, "error TS2322: wrong\n"), (-11, "error TS2322: wrong\nerror TS2339: missing\n")):
            with mock.patch.object(run.shutil, "copytree"), mock.patch.object(run.Path, "read_text", return_value="source"), mock.patch.object(
                run, "write"
            ), mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")):
                with self.assertRaisesRegex(SystemExit, "failed import_graph negative controls"):
                    run.validate_graph_negatives({"home": ["home"]}, "import_graph")


if __name__ == "__main__":
    unittest.main()
