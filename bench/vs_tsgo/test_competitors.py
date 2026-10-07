"""Pinned extra compilers use the same admission semantics and retain raw output."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import tarfile
from unittest.mock import patch

import competitors
import run
import compare


class OutputPolicyTests(unittest.TestCase):
    def test_silent_policy_retains_existing_contract(self):
        self.assertTrue(competitors.successful_output("", ""))
        for output in ("\n", "✓ No type errors in 1 file [1.00ms]\n", "warning"):
            self.assertFalse(competitors.successful_output(output, ""))

    def test_complete_checked_file_status_is_accepted_on_one_stream(self):
        for output in ("✓ No type errors in 1 file [6.19ms]\n", "✓ No type errors in 256 files [9.50ms]\n",
                       "✓ No type errors in 1,024 files [1.25s]\r\n"):
            self.assertTrue(competitors.successful_output(output, "", "checked-files"))
            self.assertTrue(competitors.successful_output("", output, "checked-files"))
            self.assertFalse(competitors.successful_output(output, output, "checked-files"))

    def test_unknown_incomplete_or_diagnostic_output_is_never_discarded(self):
        status = "✓ No type errors in 1 file [1.00ms]\n"
        for output in ("", "✓ No type errors in 0 files [1.00ms]\n", "✓ No type errors\n", status + status,
                       "note: missing dependency\n" + status, "error TS2322: wrong\n" + status,
                       "source.ts: const message = 'No type errors';\n", status + "unexpected\n"):
            self.assertFalse(competitors.successful_output(output, "", "checked-files"))

    def test_status_policy_never_changes_negative_controls_or_hides_failures(self):
        trace = []
        output = "source.ts(1,1): error TS2322: wrong\nFound 1 error, checked 1 file [1ms]\n"
        for exit_code in (0, 1, 2, 3, -11):
            with patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], exit_code, "", output)):
                _, passed = run.admission_process("extra", ["extra"], "example", expected_codes=["2322"], trace=trace)
            self.assertEqual(exit_code in (1, 2), passed)
            self.assertEqual(output, trace[-1]["stderr"])
            self.assertEqual(exit_code, trace[-1]["exit_code"])


class RegistryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.payload = self.root / "native"
        self.payload.mkdir()
        self.binary = self.payload / "checker"
        self.binary.write_bytes(b"pinned compiler")
        (self.payload / "lib.d.ts").write_text("interface Value {}\n")
        self.path = self.root / "compilers.json"
        self.entry = {
            "name": "extra", "command": ["native/checker", "check", "--all"],
            "version_command": ["native/checker", "--revision"], "expected_version": "1.2.3+exact",
            "repository": "https://example.com/compiler", "revision": "a" * 40,
            "executable_sha256": competitors.sha256(self.binary),
            "payloads": [{"path": "native", "sha256": competitors.inventory_hash(competitors.payload_inventory(self.payload))}],
            "positive_output": "checked-files",
        }

    def load(self):
        self.path.write_text(json.dumps({"schema": 1, "compilers": [self.entry]}))
        return competitors.load_profiles(self.path)["extra"]

    def test_relative_paths_and_all_command_arguments_are_retained(self):
        profile = self.load()
        self.assertEqual((str(self.binary.resolve()), "check", "--all"), profile.command)
        self.assertEqual((str(self.binary.resolve()), "--revision"), profile.version_command)
        provenance = profile.provenance(run.artifact_provenance)
        self.assertEqual({"checker", "lib.d.ts"}, set(provenance["payloads"][0]["files"]))
        self.assertEqual(self.entry["executable_sha256"], provenance["executable"]["sha256"])

    def test_payload_addition_removal_or_edit_breaks_the_pin(self):
        profile = self.load()
        library = self.payload / "lib.d.ts"
        for mutation in ("edit", "delete", "add"):
            library.write_text("interface Value {}\n")
            added = self.payload / "new.d.ts"
            added.unlink(missing_ok=True)
            if mutation == "edit": library.write_text("type Value = any;\n")
            if mutation == "delete": library.unlink()
            if mutation == "add": added.write_text("interface Other {}\n")
            with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, "payload inventory"):
                profile.provenance(run.artifact_provenance)

    def test_executable_and_manifest_changes_are_rejected(self):
        profile = self.load()
        self.binary.write_bytes(b"different compiler")
        with self.assertRaisesRegex(ValueError, "executable hash"):
            profile.provenance(run.artifact_provenance)
        self.binary.write_bytes(b"pinned compiler")
        self.path.write_text(self.path.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "manifest changed"):
            profile.provenance(run.artifact_provenance)

    def test_reserved_names_unknown_fields_and_ambiguous_commands_fail(self):
        for key, value in (("name", "home"), ("name", "bad name"), ("revision", "main"),
                           ("executable_sha256", "unknown"), ("positive_output", "ignore"),
                           ("command", []), ("command", "native/checker"), ("payloads", [])):
            original = self.entry[key]
            self.entry[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError): self.load()
            self.entry[key] = original
        self.entry["skip_errors"] = True
        with self.assertRaisesRegex(ValueError, "unknown fields"): self.load()

    def test_version_probe_cannot_query_another_executable(self):
        other = self.payload / "other"
        other.write_bytes(b"other")
        self.entry["version_command"] = ["native/other", "--version"]
        with self.assertRaisesRegex(ValueError, "same executable"): self.load()

    def test_manifest_schema_and_duplicate_fields_are_unambiguous(self):
        self.path.write_text('{"schema":1,"schema":1,"compilers":[]}')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            competitors.load_profiles(self.path)
        self.path.write_text(json.dumps({"schema": True, "compilers": [self.entry]}))
        with self.assertRaisesRegex(ValueError, "schema 1"):
            competitors.load_profiles(self.path)

    def test_native_tsgo_is_measured_directly_and_additions_cannot_replace_it(self):
        tools = self.root / "tools"
        launcher = tools / "node_modules/.bin/tsc"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("javascript launcher")
        with patch.object(run, "TSC_TOOLS", tools), patch.object(run, "native_tsgo_payload", return_value=self.binary), patch.dict(
            run.os.environ, {"HOME_TSC": str(self.binary)}
        ):
            commands = run.compiler_commands()
            self.assertEqual([str(self.binary)], commands["tsgo"])
            with self.assertRaisesRegex(SystemExit, "cannot replace"):
                run.compiler_commands({"tsgo": self.load()})

    def test_exact_version_probe_is_checked_in_addition_to_required_ts_pins(self):
        profile = self.load()
        commands = {"tsc": ["tsc"], "tsgo": ["tsgo"], "home": ["home"], "extra": list(profile.command)}
        with patch.object(run, "version_output", side_effect=["Version 6.0.3", "Version 7.0.2", "Home 0.1.0"]), patch.object(
            run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, profile.expected_version, "")
        ) as probe:
            versions = run.verified_compiler_versions(commands, {"extra": profile})
        self.assertEqual(profile.expected_version, versions["extra"])
        probe.assert_called_once_with(list(profile.version_command), check=True, capture_output=True, text=True)
        with patch.object(run, "version_output", return_value="unused"), patch.object(
            run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "wrong version", "")
        ), self.assertRaisesRegex(SystemExit, "extra version mismatch"):
            run.verified_compiler_versions(commands, {"extra": profile})

    def test_status_adapter_preserves_positive_raw_output(self):
        profile = self.load()
        trace = []
        output = "✓ No type errors in 1 file [3.14ms]\n"
        with patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", output)):
            run.validate({"extra": list(profile.command)}, "startup", profiles={"extra": profile}, trace=trace)
        self.assertTrue(trace[0]["passed"])
        self.assertEqual(output, trace[0]["stderr"])
        self.assertEqual("positive", trace[0]["kind"])

    def pipeline(self, *, failure=False):
        profile = self.load()
        commands = {"tsc": ["tsc"], "tsgo": ["tsgo"], "home": ["home"], "extra": list(profile.command)}
        snapshot = {"compilers": {name: {
            "command": command, "executable": {"sha256": "a" * 64, "size": 100},
            "positive_output": "checked-files" if name == "extra" else "silent",
        } for name, command in commands.items()}}
        corpus = self.root / "corpus"
        corpus.mkdir()
        results = self.root / "results"
        host = {"os": "TestOS", "os_release": "1", "architecture": "arm64", "cpu_model": "Test CPU", "logical_cores": 4}
        def process(argv, **kwargs):
            if argv[0] == "hyperfine":
                path = Path(argv[argv.index("--export-json") + 1])
                names = [argv[index + 1] for index, value in enumerate(argv) if value == "--command-name"]
                path.write_text(json.dumps({"results": [{"command": name, "times": [0.1], "exit_codes": [0]} for name in names]}))
                return subprocess.CompletedProcess(argv, 0, "", "")
            output = "✓ No type errors in 1 file [1.00ms]\n" if argv[0] == profile.command[0] else ""
            code = 3 if failure and output else 0
            return subprocess.CompletedProcess(argv, code, "", output)
        with patch.object(run, "CORPUS", corpus), patch.object(run, "RESULTS", results), patch.object(
            run, "selected_workloads", return_value=["example"]
        ), patch.object(run.shutil, "which", return_value="hyperfine"), patch.object(
            run, "compiler_commands", return_value=commands
        ), patch.object(run, "verified_compiler_versions", return_value={name: name for name in commands}), patch.object(
            run, "benchmark_provenance", return_value=snapshot
        ), patch.object(run, "host_metadata", return_value=host), patch.object(run.subprocess, "run", side_effect=process):
            if failure:
                with self.assertRaisesRegex(SystemExit, "extra failed validation"):
                    run.cmd_cold(4, 0, competitor_manifest=self.path)
                log = json.loads(next((results / "admission").glob("*.json")).read_text())
                self.assertFalse(log["passed"])
                self.assertEqual(3, log["records"][-1]["exit_code"])
                self.assertIn("No type errors", log["records"][-1]["stderr"])
                self.assertEqual([], list(results.rglob("*-round-*.json")))
                return None
            return run.cmd_cold(4, 0, competitor_manifest=self.path)

    def test_extended_measurement_retains_raw_admission_and_packages_a_valid_archive(self):
        result = self.pipeline()
        metadata = json.loads((result / "metadata.json").read_text())
        compare.validate_interleaved_rounds(result, metadata)
        self.assertEqual(3, metadata["schema"])
        admission = json.loads((result / "admission.jsonl").read_text())
        self.assertEqual(4, len(admission["records"]))
        self.assertIn("No type errors", admission["records"][-1]["stderr"])
        archive_path = self.root / "evidence.tar.gz"
        run.cmd_evidence(result, archive_path)
        restored = self.root / "restored"
        with tarfile.open(archive_path) as archive:
            archive.extractall(restored)
        published = next(restored.iterdir())
        public_metadata = json.loads((published / "metadata.json").read_text())
        compare.validate_interleaved_rounds(published, public_metadata)
        self.assertEqual((result / "example-round-000.json").read_bytes(), (published / "example-round-000.json").read_bytes())

    def test_failed_extra_compiler_keeps_its_output_and_never_starts_timing(self):
        self.pipeline(failure=True)


if __name__ == "__main__":
    unittest.main()
