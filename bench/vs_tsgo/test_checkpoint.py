"""Recovery plans never execute, replace, filter or rank recorded measurements."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import shutil

import checkpoint


class CheckpointTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.names = ["tsc", "tsgo", "home", "extra"]
        self.provenance = {"compilers": {
            name: {"command": ["/tools/" + name], "executable": {"sha256": "a" * 64, "size": 1}}
            for name in self.names}}
        self.metadata = {"schema": 3, "schedule": "round-robin interleaved", "validation_schema": 5,
                         "runs": 3, "warmup": 3, "workloads": ["example"],
                         "compilers": {name: "version" for name in self.names},
                         "host": {"os": "Test", "os_release": "1", "architecture": "arm64",
                                  "cpu_model": "Test", "logical_cores": 4},
                         "provenance": {"status": "measuring", "before": self.provenance, "after": None}}
        records = [{"compiler": name, "workload": "example", "kind": "positive", "passed": True,
                    "command": ["/tools/" + name, "--noEmit", "-p", "/project/tsconfig.json"],
                    "exit_code": 0, "stdout": "", "stderr": "", "codes": [],
                    "positive_output": "silent", "expected_codes": None} for name in self.names]
        raw = json.dumps({"schema": 1, "passed": True, "before": self.provenance,
                          "after": self.provenance, "records": records}).encode()
        (self.directory / "admission.jsonl").write_bytes(raw)
        self.metadata["admission"] = {"path": "admission.jsonl", "records": 4,
                                      "sha256": hashlib.sha256(raw).hexdigest()}

    def write_round(self, index, count=4):
        order = self.names[index % 4:] + self.names[:index % 4]
        results = [{"command": name + " example", "times": [0.1], "exit_codes": [0]}
                   for name in order[:count]]
        path = self.directory / f"example-round-{index:03d}.json"
        path.write_text(json.dumps({"results": results}))
        return path

    def plan(self):
        return checkpoint.plan_checkpoint(self.directory, self.metadata, self.provenance)

    def test_empty_checkpoint_contains_only_unrecorded_slots(self):
        plan = self.plan()
        self.assertEqual(12, plan["missing_sample_count"])
        self.assertFalse(plan["ranking_qualified"])
        self.assertFalse(plan["execution_authorized_by_plan"])

    def test_partial_prefix_preserves_observed_samples_and_raw_files(self):
        self.write_round(0)
        partial = self.write_round(1, 1)
        before = {path.name: path.read_bytes() for path in self.directory.iterdir()}
        plan = self.plan()
        self.assertEqual(1, plan["complete_rounds"])
        self.assertEqual(5, plan["recorded_successful_samples"])
        self.assertEqual(["home", "extra", "tsc"], plan["unrecorded_slots"][0]["compiler_order"])
        self.assertEqual(["tsgo"], plan["unrecorded_slots"][0]["already_recorded"])
        self.assertEqual(7, plan["missing_sample_count"])
        self.assertEqual(partial.name, plan["partial_round"])
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.directory.iterdir()})

    def test_missing_round_then_later_round_is_rejected(self):
        self.write_round(1)
        with self.assertRaisesRegex(ValueError, "contiguous prefix"):
            self.plan()

    def test_partial_round_then_later_round_is_rejected(self):
        self.write_round(0, 1)
        self.write_round(1)
        with self.assertRaisesRegex(ValueError, "contiguous prefix"):
            self.plan()

    def test_reordered_or_duplicate_sample_is_rejected(self):
        path = self.write_round(0)
        data = json.loads(path.read_text())
        data["results"][1] = data["results"][0]
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "ordered prefix"):
            self.plan()

    def test_failed_invalid_or_empty_round_is_never_discarded(self):
        path = self.write_round(0)
        original = json.loads(path.read_text())
        for replacement in [[], [{"command": "tsc example", "times": [0.1], "exit_codes": [1]}],
                            [{"command": "tsc example", "times": [True], "exit_codes": [0]}],
                            [{"command": "tsc example", "times": [float("nan")], "exit_codes": [0]}]]:
            path.write_text(json.dumps({"results": replacement}))
            retained = path.read_bytes()
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.plan()
            self.assertEqual(retained, path.read_bytes())
        path.write_text(json.dumps(original))

    def test_changed_provenance_is_rejected(self):
        changed = copy.deepcopy(self.provenance)
        changed["compilers"]["home"]["executable"]["sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "missing or changed"):
            checkpoint.plan_checkpoint(self.directory, self.metadata, changed)

    def test_invalid_admission_hash_is_rejected(self):
        self.metadata["admission"]["sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "admission evidence hash"):
            self.plan()

    def test_complete_checkpoint_requires_normal_verifier(self):
        for index in range(3): self.write_round(index)
        with self.assertRaisesRegex(ValueError, "completed-result verifier"):
            self.plan()

    def test_extra_round_file_is_rejected(self):
        self.write_round(4)
        with self.assertRaisesRegex(ValueError, "unexpected"):
            self.plan()

    def test_malformed_metadata_is_rejected_without_mutation(self):
        for key, value in [("workloads", None), ("workloads", [{}]), ("compilers", []),
                           ("schema", True), ("runs", True), ("warmup", -1), ("host", {})]:
            metadata = copy.deepcopy(self.metadata)
            metadata[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                checkpoint.plan_checkpoint(self.directory, metadata, self.provenance)

    def test_malformed_round_record_is_rejected(self):
        path = self.directory / "example-round-000.json"
        for data in [[], {"results": [None]}, {"results": "invalid"}]:
            path.write_text(json.dumps(data))
            retained = path.read_bytes()
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.plan()
            self.assertEqual(retained, path.read_bytes())

    def test_changed_recorded_after_snapshot_is_rejected(self):
        self.metadata["provenance"]["after"] = {"changed": True}
        with self.assertRaisesRegex(ValueError, "recorded changed"):
            self.plan()

    def test_corrupt_admission_is_not_recovered_as_a_smaller_success(self):
        path = self.directory / "admission.jsonl"
        data = json.loads(path.read_bytes())
        data["records"].pop()
        raw = json.dumps(data).encode()
        path.write_bytes(raw)
        self.metadata["admission"]["sha256"] = hashlib.sha256(raw).hexdigest()
        with self.assertRaisesRegex(ValueError, "record count"):
            self.plan()

    def test_symlinked_round_is_rejected_without_following_it(self):
        external = self.directory / "external.txt"
        external.write_text("not checkpoint evidence")
        (self.directory / "example-round-000.json").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "real file"):
            self.plan()
        self.assertEqual("not checkpoint evidence", external.read_text())

    def test_symlinked_admission_is_rejected(self):
        admission = self.directory / "admission.jsonl"
        external = self.directory / "external.txt"
        external.write_bytes(admission.read_bytes())
        admission.unlink()
        admission.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "admission must be a real file"):
            self.plan()

    def test_symlinked_checkpoint_directory_is_rejected(self):
        link = self.directory / "directory-link"
        link.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "real directory"):
            checkpoint.plan_checkpoint(link, self.metadata, self.provenance)


class LineageTests(unittest.TestCase):
    write_round = CheckpointTests.write_round

    def setUp(self):
        CheckpointTests.setUp(self)
        self.write_round(0)
        self.write_round(1, 1)
        original = self.directory / "lineage" / "original"
        original.mkdir(parents=True)
        original_metadata = json.dumps(self.metadata).encode()
        (original / "metadata.json").write_bytes(original_metadata)
        shutil.copy2(self.directory / "admission.jsonl", original / "admission.jsonl")
        self.sources = []
        for index, count in [(0, 4), (1, 1)]:
            filename = f"example-round-{index:03d}.json"
            shutil.copy2(self.directory / filename, original / filename)
            order = self.names[index % 4:] + self.names[:index % 4]
            self.add_source("lineage/original/" + filename, index, order[:count])
        segments = self.directory / "lineage" / "segments"
        segments.mkdir()
        for index, start in [(1, 1), (2, 0)]:
            order = self.names[index % 4:] + self.names[:index % 4]
            results = [{"command": name + " example", "times": [0.2], "exit_codes": [0]}
                       for name in order[start:]]
            relative = f"lineage/segments/example-round-{index:03d}.json"
            (self.directory / relative).write_text(json.dumps({"results": results}))
            self.add_source(relative, index, order[start:])
            prefix = json.loads((original / f"example-round-{index:03d}.json").read_text())["results"] if start else []
            (self.directory / f"example-round-{index:03d}.json").write_text(json.dumps({"results": prefix + results}))
        self.lineage = {"schema": 1, "original_metadata_sha256": hashlib.sha256(original_metadata).hexdigest(),
                        "sources": self.sources}
        self.manifest = self.directory / "lineage" / "manifest.json"
        self.write_manifest()
        self.metadata["provenance"].update(status="verified", after=self.provenance)
        original_plan = checkpoint.plan_checkpoint(original, json.loads(original_metadata), self.provenance)
        self.metadata["resumption"] = {"schema": 1, "measurement_pause": True,
                                       "source_metadata_sha256": self.lineage["original_metadata_sha256"],
                                       "original_recorded_samples": original_plan["recorded_successful_samples"],
                                       "partial_round": original_plan["partial_round"]}

    def add_source(self, relative, index, order):
        self.sources.append({"path": relative, "sha256": hashlib.sha256((self.directory / relative).read_bytes()).hexdigest(),
                             "workload": "example", "round": index, "compiler_order": order})

    def write_manifest(self):
        self.manifest.write_text(json.dumps(self.lineage))

    def test_disjoint_fragments_preserve_every_sample_and_validate_complete_rounds(self):
        before = {str(path): path.read_bytes() for path in self.directory.rglob("*") if path.is_file()}
        checkpoint.validate_lineage(self.directory, self.metadata)
        self.assertEqual(before, {str(path): path.read_bytes() for path in self.directory.rglob("*") if path.is_file()})

    def test_pause_and_original_checkpoint_descriptor_cannot_be_hidden_or_changed(self):
        for key, value in [("measurement_pause", False), ("source_metadata_sha256", "0" * 64),
                           ("original_recorded_samples", 0), ("partial_round", None)]:
            metadata = copy.deepcopy(self.metadata)
            metadata["resumption"][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "descriptor"):
                checkpoint.validate_lineage(self.directory, metadata)
        metadata = copy.deepcopy(self.metadata)
        metadata.pop("resumption")
        with self.assertRaisesRegex(ValueError, "descriptor"):
            checkpoint.validate_lineage(self.directory, metadata)

    def test_overlap_cannot_repeat_recorded_compiler_sample(self):
        self.sources.append(copy.deepcopy(self.sources[0]))
        self.sources[-1]["path"] = "lineage/segments/duplicate.json"
        shutil.copy2(self.directory / self.sources[0]["path"], self.directory / self.sources[-1]["path"])
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "repeats a recorded"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_assembled_sample_cannot_be_replaced_or_modified(self):
        path = self.directory / "example-round-001.json"
        data = json.loads(path.read_text())
        data["results"][0]["times"] = [0.3]
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "altered its retained"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_missing_original_sample_cannot_be_substituted_by_new_raw_data(self):
        source = self.sources.pop(0)
        replacement = copy.deepcopy(source)
        replacement["path"] = "lineage/segments/replacement.json"
        shutil.copy2(self.directory / source["path"], self.directory / replacement["path"])
        self.sources.append(replacement)
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "omitted or replaced"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_raw_checksum_changes_are_rejected(self):
        (self.directory / self.sources[-1]["path"]).write_text("{}")
        with self.assertRaisesRegex(ValueError, "checksum changed"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_path_escape_and_symlink_are_rejected(self):
        for relative in ["../outside.json", "/outside.json", "lineage/../outside.json"]:
            self.sources[-1]["path"] = relative
            self.write_manifest()
            with self.subTest(relative=relative), self.assertRaisesRegex(ValueError, "path is invalid"):
                checkpoint.validate_lineage(self.directory, self.metadata)

    def test_changed_original_selection_is_rejected(self):
        self.metadata["warmup"] = 4
        with self.assertRaisesRegex(ValueError, "changed its original"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_incomplete_lineage_cannot_be_ranked(self):
        self.sources.pop()
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "cover every sample"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_unverified_completed_metadata_is_rejected(self):
        self.metadata["provenance"]["status"] = "measuring"
        with self.assertRaisesRegex(ValueError, "not verified"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_changed_original_raw_checkpoint_is_rejected(self):
        path = self.directory / "lineage" / "original" / "example-round-000.json"
        data = json.loads(path.read_text())
        data["results"][0]["times"] = [0.8]
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "checksum changed"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_extra_top_level_round_cannot_hide_in_lineage(self):
        self.write_round(4)
        with self.assertRaisesRegex(ValueError, "unexpected round set"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_symlinked_lineage_parent_is_rejected_before_reading_it(self):
        lineage = self.directory / "lineage"
        retained = self.directory / "retained-lineage"
        lineage.rename(retained)
        lineage.symlink_to(retained, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "real directory"):
            checkpoint.validate_lineage(self.directory, self.metadata)

    def test_symlinked_original_parent_is_rejected_before_reading_it(self):
        original = self.directory / "lineage" / "original"
        retained = self.directory / "lineage" / "retained-original"
        original.rename(retained)
        original.symlink_to(retained, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "real directory"):
            checkpoint.validate_lineage(self.directory, self.metadata)
