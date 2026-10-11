"""Simulated timers establish immutable no-repeat execution before real use."""
import copy
import hashlib
import json
import io
import shutil
from pathlib import Path
import tempfile
import unittest
import tarfile
from unittest import mock
from types import SimpleNamespace

import resume
import run
import compare
import test_checkpoint


class ResumeTests(unittest.TestCase):
    write_round = test_checkpoint.CheckpointTests.write_round

    def setUp(self):
        test_checkpoint.CheckpointTests.setUp(self)
        self.write_round(0)
        self.write_round(1, 1)
        self.original = self.directory
        self.output = self.directory / "continued"
        (self.original / "metadata.json").write_text(json.dumps(self.metadata))
        self.host = self.metadata["host"]
        self.commands = {name: self.provenance["compilers"][name]["command"] for name in self.names}
        self.calls = []
        self.plan = resume.initialize(self.original, self.output, self.provenance, self.host)

    def timer(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[0] != "hyperfine":
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        target = Path(argv[argv.index("--export-json") + 1])
        names = [argv[index + 1] for index, value in enumerate(argv) if value == "--command-name"]
        target.write_text(json.dumps({"results": [{"command": name, "times": [0.2], "exit_codes": [0]} for name in names]}))
        return SimpleNamespace(returncode=0)

    def execute(self, process=None):
        return resume.execute_workload(self.output, "example", self.commands, Path("/corpus"),
                                       lambda: self.provenance, lambda: self.host, process or self.timer)

    def test_recorded_prefix_is_not_executed_and_originals_stay_unchanged(self):
        before = {path.name: path.read_bytes() for path in self.original.iterdir() if path.is_file()}
        result = self.execute()
        self.assertEqual("complete", result["status"])
        self.assertEqual(2, len(self.calls))
        first = [argv[index + 1] for argv in self.calls[:1] for index, value in enumerate(argv) if value == "--command-name"]
        self.assertEqual(["home example", "extra example", "tsc example"], first)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.original.iterdir() if path.is_file()})
        resume.finalize(self.output, self.provenance, self.host)
        self.assertEqual("verified", json.loads((self.output / "metadata.json").read_text())["provenance"]["status"])

    def test_complete_or_failed_phase_cannot_be_repeated(self):
        self.execute()
        count = len(self.calls)
        with self.assertRaisesRegex(ValueError, "already attempted"):
            self.execute()
        self.assertEqual(count, len(self.calls))

    def test_changed_artifacts_prevent_any_execution(self):
        current = copy.deepcopy(self.provenance)
        current["compilers"]["home"]["executable"]["sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "changed before"):
            resume.execute_workload(self.output, "example", self.commands, Path("/corpus"),
                                    lambda: current, lambda: self.host, self.timer)
        self.assertFalse(self.calls)

    def test_invalid_timer_sample_is_retained_and_cannot_be_retried(self):
        def invalid(argv, **kwargs):
            result = self.timer(argv, **kwargs)
            target = Path(argv[argv.index("--export-json") + 1])
            data = json.loads(target.read_text())
            data["results"][0]["exit_codes"] = [1]
            target.write_text(json.dumps(data))
            return result
        with self.assertRaisesRegex(ValueError, "sample failed"):
            self.execute(invalid)
        raw = self.output / "lineage" / "segments" / "example-round-001.json"
        self.assertEqual([1], json.loads(raw.read_text())["results"][0]["exit_codes"])
        self.assertFalse((self.output / "example-round-001.json").exists())
        with self.assertRaisesRegex(ValueError, "already attempted"):
            self.execute()

    def test_mutated_plan_prevents_execution(self):
        path = self.output / "lineage" / "plan.json"
        data = json.loads(path.read_text())
        data["unrecorded_slots"][0]["compiler_order"].append("tsgo")
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "plan or retained"):
            self.execute()
        self.assertFalse(self.calls)

    def test_initialization_refuses_existing_destination_and_changed_host(self):
        with self.assertRaisesRegex(ValueError, "already exists"):
            resume.initialize(self.original, self.output, self.provenance, self.host)
        changed = dict(self.host, cpu_model="Different")
        with self.assertRaisesRegex(ValueError, "host changed"):
            resume.initialize(self.original, self.directory / "other", self.provenance, changed)

    def test_missing_phase_cannot_be_finalized(self):
        with self.assertRaises(FileNotFoundError):
            resume.finalize(self.output, self.provenance, self.host)
        self.assertEqual("measuring", json.loads((self.output / "metadata.json").read_text())["provenance"]["status"])

    def test_untouched_workload_runs_original_warmup_count_then_only_missing_rounds(self):
        source = self.directory / "empty-checkpoint"
        source.mkdir()
        shutil.copy2(self.original / "admission.jsonl", source / "admission.jsonl")
        shutil.copy2(self.original / "metadata.json", source / "metadata.json")
        output = self.directory / "empty-continued"
        resume.initialize(source, output, self.provenance, self.host)
        resume.execute_workload(output, "example", self.commands, Path("/corpus"),
                                lambda: self.provenance, lambda: self.host, self.timer)
        self.assertEqual(12, sum(argv[0] != "hyperfine" for argv in self.calls))
        self.assertEqual(3, sum(argv[0] == "hyperfine" for argv in self.calls))
        self.assertEqual(12, len(list((output / "lineage" / "warmups").rglob("*.json"))))
        resume.finalize(output, self.provenance, self.host)

    def test_initialization_rejects_symlinked_metadata(self):
        source = self.directory / "linked-checkpoint"
        source.mkdir()
        (source / "metadata.json").symlink_to(self.original / "metadata.json")
        with self.assertRaisesRegex(ValueError, "real owned"):
            resume.initialize(source, self.directory / "not-created", self.provenance, self.host)


class ContinuationPublicationTests(unittest.TestCase):
    write_round = ResumeTests.write_round
    timer = ResumeTests.timer
    execute = ResumeTests.execute

    def setUp(self):
        ResumeTests.setUp(self)
        self.execute()
        resume.finalize(self.output, self.provenance, self.host)

    def test_archive_retains_all_lineage_bytes_and_checksums(self):
        archive_path = self.directory / "evidence.tar.gz"
        run.cmd_evidence(self.output, archive_path)
        first = archive_path.read_bytes()
        run.cmd_evidence(self.output, archive_path)
        self.assertEqual(first, archive_path.read_bytes())
        prefix = "ts-frontend-benchmark-continued/"
        with tarfile.open(archive_path) as archive:
            for path in self.output.rglob("*"):
                if path.is_file():
                    self.assertEqual(path.read_bytes(), archive.extractfile(prefix + path.relative_to(self.output).as_posix()).read())
            for line in archive.extractfile(prefix + "SHA256SUMS").read().decode().splitlines():
                expected, relative = line.split("  ", 1)
                self.assertEqual(expected, hashlib.sha256(archive.extractfile(prefix + relative).read()).hexdigest())

    def test_reporting_rejects_missing_lineage_even_with_complete_rounds(self):
        (self.output / "lineage" / "manifest.json").unlink()
        with mock.patch.object(compare.sys, "argv", ["compare.py", str(self.output)]):
            self.assertEqual(1, compare.main())

    def test_archive_rejects_changed_raw_lineage_without_writing_output(self):
        (self.output / "lineage" / "segments" / "example-round-001.json").write_text("{}")
        archive_path = self.directory / "evidence.tar.gz"
        with self.assertRaisesRegex(SystemExit, "checksum changed"):
            run.cmd_evidence(self.output, archive_path)
        self.assertFalse(archive_path.exists())

    def test_reporting_discloses_measurement_pause(self):
        output = io.StringIO()
        with mock.patch.object(compare.sys, "argv", ["compare.py", str(self.output)]), mock.patch.object(compare.sys, "stdout", output):
            self.assertEqual(0, compare.main())
        self.assertIn("measurement pause and split round", output.getvalue())

    def test_archive_rejects_symlinked_unmanifested_lineage(self):
        (self.output / "lineage" / "unmanifested.json").symlink_to(self.original / "metadata.json")
        archive_path = self.directory / "evidence.tar.gz"
        with self.assertRaisesRegex(SystemExit, "cannot contain symlinks"):
            run.cmd_evidence(self.output, archive_path)
        self.assertFalse(archive_path.exists())
