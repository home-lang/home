"""Report formatting regressions; measurements are never filtered or changed."""

import json
import hashlib
import io
from contextlib import redirect_stdout
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

import compare


class ComparisonTests(unittest.TestCase):
    def test_jsdoc_comparisons_require_the_new_validation_protocol(self):
        for schema in (None, 1, 2, 3, 6):
            self.assertIn("Provisional", compare.format_workload_comparison("checkjs_jsdoc", 1, 2, schema))
        self.assertEqual("**2.00× faster**", compare.format_workload_comparison("checkjs_jsdoc", 1, 2, 4))
        self.assertEqual("**2.00× faster**", compare.format_workload_comparison("reexport_graph", 1, 2, 4))
        self.assertEqual("**2.00× faster**", compare.format_workload_comparison("variadic_tuples", 1, 2, 4))
        for workload in ("checkjs_jsdoc", "reexport_graph", "variadic_tuples"):
            self.assertEqual("**2.00× faster**", compare.format_workload_comparison(workload, 1, 2, 5))

    def test_nullsafe_comparisons_require_schema_five_inferred_local_controls(self):
        for schema in (None, 1, 2, 3, 4, 6):
            self.assertIn("Provisional", compare.format_workload_comparison("null_safe_access", 1, 2, schema))
        self.assertEqual("**2.00× faster**", compare.format_workload_comparison("null_safe_access", 1, 2, 5))

    def test_exact_tie_is_not_a_win(self):
        self.assertEqual("1.00× (near tie)", compare.format_comparison(100, 100))

    def test_rounded_ties_are_symmetric(self):
        for home, competitor in [(100, 100.4), (100.4, 100)]:
            with self.subTest(home=home, competitor=competitor):
                self.assertEqual("1.00× (near tie)", compare.format_comparison(home, competitor))

    def test_lower_median_keeps_direction(self):
        self.assertEqual("**2.00× faster**", compare.format_comparison(100, 200))

    def test_higher_median_keeps_direction(self):
        self.assertEqual("2.00× slower", compare.format_comparison(200, 100))

    def test_summary_uses_the_median_without_filtering_samples(self):
        summary = compare.summarize_times([0.1, 0.2, 9.9])
        self.assertEqual({"median": 0.2, "samples": 3}, summary)
        self.assertEqual("200.0 ms", compare.format_time(summary))

    def test_summary_rejects_missing_or_invalid_samples(self):
        for times in ([], [0], [-1], [float("nan")], [True]):
            with self.subTest(times=times), self.assertRaisesRegex(ValueError, "finite positive"):
                compare.summarize_times(times)

    def test_two_decimal_boundary_is_symmetric(self):
        for home, competitor in [(100, 100.49), (100.49, 100)]:
            self.assertEqual("1.00× (near tie)", compare.format_comparison(home, competitor))
        self.assertEqual("**1.01× faster**", compare.format_comparison(100, 100.51))
        self.assertEqual("1.01× slower", compare.format_comparison(100.51, 100))

    def test_legacy_and_verified_provenance_are_distinguished(self):
        self.assertIn("legacy result", compare.provenance_notice({}))
        self.assertIn("verified unchanged", compare.provenance_notice({"provenance": {"status": "verified"}}))

    def test_host_and_tool_versions_are_rendered(self):
        metadata = {
            "host": {
                "os": "TestOS",
                "os_release": "1.2",
                "architecture": "arm64",
                "cpu_model": "Test CPU",
                "machine_model": "Test Machine",
                "logical_cores": 10,
            },
            "provenance": {"before": {"tools": {"hyperfine": {"version": "hyperfine 1.20.0"}}}},
        }
        self.assertEqual("Test CPU / Test Machine; 10 logical cores; TestOS 1.2 (arm64)", compare.host_notice(metadata))
        self.assertEqual("Measurement tools: hyperfine `hyperfine 1.20.0`.", compare.tools_notice(metadata))


class InterleavedIntegrityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.metadata = {"schedule": "round-robin interleaved", "runs": 3, "workloads": ["example"],
                         "compilers": {name: name for name in ("tsc", "tsgo", "home")}}
        self.rounds = []
        names = list(self.metadata["compilers"])
        for index in range(3):
            order = names[index:] + names[:index]
            results = [{"command": f"{name} example", "times": [0.1], "exit_codes": [0]} for name in order]
            self.rounds.append(results)
            self.write_round(index, results)

    def write_round(self, index, results):
        (self.directory / f"example-round-{index:03d}.json").write_text(json.dumps({"results": results}), encoding="utf-8")

    def test_complete_rotating_rounds_are_accepted(self):
        compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_schema_two_requires_complete_host_metadata(self):
        self.metadata["schema"] = 2
        with self.assertRaisesRegex(ValueError, "host metadata is incomplete"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)
        self.metadata["host"] = {
            "os": "TestOS",
            "os_release": "1.0",
            "architecture": "arm64",
            "cpu_model": "Test CPU",
            "logical_cores": 8,
        }
        compare.validate_interleaved_rounds(self.directory, self.metadata)
        self.metadata["host"]["logical_cores"] = 0
        with self.assertRaisesRegex(ValueError, "core count is invalid"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_verified_unchanged_provenance_is_accepted(self):
        snapshot = {"schema": 1, "compilers": {"home": {"sha256": "same"}}}
        self.metadata["provenance"] = {"status": "verified", "before": snapshot, "after": snapshot}
        compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_incomplete_or_changed_provenance_is_not_reportable(self):
        for status in ("measuring", "incomplete", "changed"):
            self.metadata["provenance"] = {"status": status, "before": {}, "after": {}}
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "not verified"):
                compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_mismatched_verified_provenance_is_not_reportable(self):
        self.metadata["provenance"] = {"status": "verified", "before": {"hash": "a"}, "after": {"hash": "b"}}
        with self.assertRaisesRegex(ValueError, "changed during measurement"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_missing_round_is_not_a_smaller_successful_report(self):
        (self.directory / "example-round-002.json").unlink()
        with self.assertRaisesRegex(ValueError, "1 missing"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_extra_round_is_not_silently_averaged(self):
        self.write_round(3, self.rounds[0])
        with self.assertRaisesRegex(ValueError, "1 extra"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_partial_json_is_rejected(self):
        (self.directory / "example-round-000.json").write_text("{", encoding="utf-8")
        with self.assertRaises(ValueError):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_wrong_order_or_duplicate_compiler_is_rejected(self):
        for results in (list(reversed(self.rounds[0])), [self.rounds[0][0]] * 3):
            self.write_round(0, results)
            with self.assertRaisesRegex(ValueError, "compiler coverage/order"):
                compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_invalid_and_failed_samples_are_rejected(self):
        for times, exits in (([], [0]), ([0.1, 0.2], [0]), ([0.1], [1]), ([float("nan")], [0]), ([-1], [0]), ([True], [0])):
            results = [dict(result) for result in self.rounds[0]]
            results[0].update(times=times, exit_codes=exits)
            self.write_round(0, results)
            with self.assertRaisesRegex(ValueError, "invalid or unsuccessful sample"):
                compare.validate_interleaved_rounds(self.directory, self.metadata)

    def extra_compiler_rounds(self):
        self.metadata.update(schema=3, runs=5, validation_schema=3, host={
            "os": "TestOS", "os_release": "1.0", "architecture": "arm64",
            "cpu_model": "Test CPU", "logical_cores": 8,
        })
        self.metadata["compilers"].update(tsc_rs="Version 7.1.0-dev", bun_canary="1.4.3-canary")
        snapshot = {"compilers": {
            name: {"command": [name], "executable": {"sha256": "a" * 64, "size": 100}}
            for name in self.metadata["compilers"]
        }}
        self.metadata["provenance"] = {"status": "verified", "before": snapshot, "after": snapshot}
        names = list(self.metadata["compilers"])
        records = [{"compiler": name, "workload": "example", "kind": "positive", "passed": True,
                    "command": [name, "--noEmit", "-p", "/project/example/tsconfig.json"], "exit_code": 0,
                    "stdout": "", "stderr": "", "positive_output": "silent", "expected_codes": None, "codes": []}
                   for name in names]
        admission = {"schema": 1, "passed": True, "before": snapshot, "after": snapshot, "records": records}
        raw = (json.dumps(admission) + "\n").encode()
        (self.directory / "admission.jsonl").write_bytes(raw)
        self.metadata["admission"] = {"path": "admission.jsonl", "sha256": hashlib.sha256(raw).hexdigest(), "records": len(records)}
        for index in range(5):
            order = names[index:] + names[:index]
            self.write_round(index, [
                {"command": f"{name} example", "times": [0.05 if name == "tsc_rs" else 0.1], "exit_codes": [0]}
                for name in order
            ])

    def test_five_compilers_keep_complete_rotating_coverage(self):
        self.extra_compiler_rounds()
        compare.validate_interleaved_rounds(self.directory, self.metadata)
        path = self.directory / "example-round-003.json"
        data = json.loads(path.read_text())
        data["results"] = data["results"][:-1]
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "compiler coverage/order"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_extra_compilers_require_their_own_verified_executables(self):
        self.extra_compiler_rounds()
        self.metadata["schema"] = 2
        with self.assertRaisesRegex(ValueError, "schema 3"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)
        self.metadata["schema"] = 3
        del self.metadata["provenance"]["before"]["compilers"]["tsc_rs"]
        with self.assertRaisesRegex(ValueError, "provenance is incomplete"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_extra_compiler_report_uses_every_competitor_and_every_sample(self):
        self.extra_compiler_rounds()
        (self.directory / "metadata.json").write_text(json.dumps(self.metadata))
        output = io.StringIO()
        with patch("sys.argv", ["compare.py", str(self.directory)]), redirect_stdout(output):
            self.assertEqual(0, compare.main())
        table = output.getvalue()
        self.assertIn("tsc_rs median | bun_canary median", table)
        self.assertIn("tsc_rs `Version 7.1.0-dev`", table)
        self.assertIn("| `example` | 100.0 ms | 100.0 ms | 100.0 ms | 50.0 ms | 100.0 ms | 2.00× slower |", table)

    def test_extra_compiler_failure_cannot_be_hidden_from_the_report(self):
        self.extra_compiler_rounds()
        path = self.directory / "example-round-004.json"
        data = json.loads(path.read_text())
        next(row for row in data["results"] if row["command"] == "bun_canary example")["exit_codes"] = [1]
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "invalid or unsuccessful sample"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_extra_compilers_cannot_use_legacy_unverified_schedules(self):
        self.extra_compiler_rounds()
        self.metadata["schedule"] = "sequential"
        with self.assertRaisesRegex(ValueError, "round-robin interleaved"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_extra_compiler_hashes_must_describe_real_executables(self):
        self.extra_compiler_rounds()
        self.metadata["provenance"]["before"]["compilers"]["tsc_rs"]["executable"]["sha256"] = "unknown"
        with self.assertRaisesRegex(ValueError, "executable provenance is incomplete"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_retained_admission_cannot_be_removed_or_changed(self):
        self.extra_compiler_rounds()
        (self.directory / "admission.jsonl").write_text("{}\n")
        with self.assertRaisesRegex(ValueError, "admission evidence hash"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def jsdoc_admission(self):
        self.extra_compiler_rounds()
        self.metadata["validation_schema"] = 4
        path = self.directory / "admission.jsonl"
        admission = json.loads(path.read_text())
        negatives = []
        codes = sorted(["2322"] * 9 + ["2339"] * 3 + ["2345"] * 3)
        for record in admission["records"]:
            record["workload"] = "checkjs_jsdoc"
            negative = dict(record, kind="negative", exit_code=1,
                            stdout="".join(f"error TS{code}: expected\n" for code in codes),
                            expected_codes=codes, codes=codes)
            negatives.append(negative)
        admission["records"].extend(negatives)
        self.write_admission(admission)
        return admission

    def write_admission(self, admission):
        raw = json.dumps(admission).encode()
        (self.directory / "admission.jsonl").write_bytes(raw)
        self.metadata["admission"].update(sha256=hashlib.sha256(raw).hexdigest(), records=len(admission["records"]))

    def test_jsdoc_schema_four_requires_all_negative_records(self):
        admission = self.jsdoc_admission()
        names = list(self.metadata["compilers"])
        compare.validate_admission(self.directory, self.metadata, names, ["checkjs_jsdoc"])
        admission["records"] = [row for row in admission["records"] if row["kind"] != "negative"]
        self.write_admission(admission)
        with self.assertRaisesRegex(ValueError, "coverage is incomplete"):
            compare.validate_admission(self.directory, self.metadata, names, ["checkjs_jsdoc"])

    def nullsafe_admission(self):
        admission = self.jsdoc_admission()
        self.metadata["validation_schema"] = 5
        codes = sorted(["2322"] * 18 + ["2339", "2345", "2493"] * 3)
        for record in admission["records"]:
            record["workload"] = "null_safe_access"
            if record["kind"] == "negative":
                record.update(expected_codes=codes, codes=codes,
                              stdout="".join(f"error TS{code}: expected\n" for code in codes))
        self.write_admission(admission)
        return admission

    def test_schema_five_requires_every_nullsafe_negative_record(self):
        admission = self.nullsafe_admission()
        names = list(self.metadata["compilers"])
        compare.validate_admission(self.directory, self.metadata, names, ["null_safe_access"])
        admission["records"] = [record for record in admission["records"] if record["kind"] != "negative"]
        self.write_admission(admission)
        with self.assertRaisesRegex(ValueError, "coverage is incomplete"):
            compare.validate_admission(self.directory, self.metadata, names, ["null_safe_access"])

    def test_schema_five_rejects_weakened_nullsafe_error_contract(self):
        admission = self.nullsafe_admission()
        negative = next(record for record in admission["records"] if record["kind"] == "negative")
        negative.update(expected_codes=["2322"], codes=["2322"], stdout="error TS2322: expected\n")
        self.write_admission(admission)
        with self.assertRaisesRegex(ValueError, "null-safe negative contract changed"):
            compare.validate_admission(self.directory, self.metadata, list(self.metadata["compilers"]), ["null_safe_access"])

    def test_schema_five_retains_the_complete_jsdoc_contract(self):
        admission = self.jsdoc_admission()
        self.metadata["validation_schema"] = 5
        names = list(self.metadata["compilers"])
        compare.validate_admission(self.directory, self.metadata, names, ["checkjs_jsdoc"])
        negative = next(record for record in admission["records"] if record["kind"] == "negative")
        negative.update(expected_codes=["2322"], codes=["2322"], stdout="error TS2322: expected\n")
        self.write_admission(admission)
        with self.assertRaisesRegex(ValueError, "JSDoc negative contract changed"):
            compare.validate_admission(self.directory, self.metadata, names, ["checkjs_jsdoc"])

    def test_legacy_schema_four_nullsafe_admission_remains_readable(self):
        self.extra_compiler_rounds()
        self.metadata["validation_schema"] = 4
        path = self.directory / "admission.jsonl"
        admission = json.loads(path.read_text())
        for record in admission["records"]:
            record["workload"] = "null_safe_access"
        self.write_admission(admission)
        compare.validate_admission(self.directory, self.metadata, list(self.metadata["compilers"]), ["null_safe_access"])

    def test_schema_five_cannot_use_a_legacy_schedule(self):
        self.metadata.update(validation_schema=5, schedule="sequential")
        with self.assertRaisesRegex(ValueError, "protocol 5 requires round-robin"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_three_compiler_schema_five_requires_retained_admission(self):
        self.extra_compiler_rounds()
        self.metadata["validation_schema"] = 5
        self.metadata["compilers"] = {name: name for name in ("tsc", "tsgo", "home")}
        del self.metadata["admission"]
        with self.assertRaisesRegex(ValueError, "retained admission evidence"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_jsdoc_schema_four_rejects_weakened_error_contract(self):
        admission = self.jsdoc_admission()
        negative = next(row for row in admission["records"] if row["kind"] == "negative")
        negative.update(expected_codes=["2322"], codes=["2322"], stdout="error TS2322: expected\n")
        self.write_admission(admission)
        with self.assertRaisesRegex(ValueError, "JSDoc negative contract changed"):
            compare.validate_admission(self.directory, self.metadata, list(self.metadata["compilers"]), ["checkjs_jsdoc"])

    def test_three_compiler_schema_four_also_requires_retained_admission(self):
        self.extra_compiler_rounds()
        self.metadata["validation_schema"] = 4
        self.metadata["compilers"] = {name: name for name in ("tsc", "tsgo", "home")}
        del self.metadata["admission"]
        with self.assertRaisesRegex(ValueError, "retained admission evidence"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_base_compilers_cannot_claim_new_gate_with_legacy_schedule(self):
        self.metadata.update(validation_schema=4, schedule="sequential")
        with self.assertRaisesRegex(ValueError, "protocol 4 requires round-robin"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_admission_claims_must_match_the_retained_process_output(self):
        self.extra_compiler_rounds()
        path = self.directory / "admission.jsonl"
        admission = json.loads(path.read_text())
        admission["records"][0]["stderr"] = "error TS2322: unexpected\n"
        raw = json.dumps(admission).encode()
        path.write_bytes(raw)
        self.metadata["admission"]["sha256"] = hashlib.sha256(raw).hexdigest()
        with self.assertRaisesRegex(ValueError, "diagnostics differ"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)

    def test_admission_must_use_the_same_measured_command(self):
        self.extra_compiler_rounds()
        path = self.directory / "admission.jsonl"
        admission = json.loads(path.read_text())
        admission["records"][0]["command"].insert(1, "--skipChecks")
        raw = json.dumps(admission).encode()
        path.write_bytes(raw)
        self.metadata["admission"]["sha256"] = hashlib.sha256(raw).hexdigest()
        with self.assertRaisesRegex(ValueError, "command differs"):
            compare.validate_interleaved_rounds(self.directory, self.metadata)


if __name__ == "__main__":
    unittest.main()
