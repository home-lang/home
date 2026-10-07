"""Report formatting regressions; measurements are never filtered or changed."""

import json
import tempfile
import unittest
from pathlib import Path

import compare


class ComparisonTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
