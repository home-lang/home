"""Benchmark preflight regressions; run with unittest discovery in this directory."""

import hashlib
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
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


class LatestResultsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.results = Path(temporary.name)

    def write_result(self, name, *, status="verified", rounds=1):
        directory = self.results / name
        directory.mkdir()
        metadata = {
            "runs": rounds,
            "workloads": ["example"],
            "provenance": {"status": status},
        }
        (directory / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        for index in range(rounds):
            (directory / f"example-round-{index:03d}.json").write_text("{}", encoding="utf-8")
        return directory

    def test_ignores_newer_non_benchmark_directory(self):
        expected = self.write_result("20260830T220926Z")
        (self.results / "type-transfer.FHPXSf").mkdir()
        with mock.patch.object(run, "RESULTS", self.results):
            self.assertEqual(expected, run.latest_results())

    def test_ignores_incomplete_or_unverified_result(self):
        expected = self.write_result("20260830T220926Z")
        self.write_result("20260831T000000Z", status="incomplete")
        missing_round = self.write_result("20260901T000000Z", rounds=2)
        (missing_round / "example-round-001.json").unlink()
        with mock.patch.object(run, "RESULTS", self.results):
            self.assertEqual(expected, run.latest_results())


class EvidenceArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "20261007T141452Z"
        self.source.mkdir()
        root_path = str(run.ROOT.resolve())
        snapshot = {"schema": 1, "compilers": {"home": {"path": f"{root_path}/zig-out/bin/home-tsc"}}}
        metadata = {
            "schema": 2,
            "schedule": "round-robin interleaved",
            "runs": 1,
            "warmup": 3,
            "workloads": ["example"],
            "compilers": {name: name for name in ("tsc", "tsgo", "home")},
            "host": {
                "os": "TestOS",
                "os_release": "1",
                "architecture": "arm64",
                "cpu_model": "Test CPU",
                "logical_cores": 4,
            },
            "provenance": {"status": "verified", "before": snapshot, "after": snapshot},
        }
        (self.source / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        self.round_bytes = json.dumps({
            "results": [
                {"command": f"{name} example", "times": [0.1], "exit_codes": [0]}
                for name in ("tsc", "tsgo", "home")
            ]
        }).encode()
        (self.source / "example-round-000.json").write_bytes(self.round_bytes)

    def test_archive_preserves_rounds_normalizes_metadata_and_is_deterministic(self):
        output = self.root / "evidence.tar.gz"
        run.cmd_evidence(self.source, output)
        first_hash = hashlib.sha256(output.read_bytes()).hexdigest()
        run.cmd_evidence(self.source, output)
        self.assertEqual(first_hash, hashlib.sha256(output.read_bytes()).hexdigest())

        prefix = "ts-frontend-benchmark-20261007T141452Z"
        with tarfile.open(output, "r:gz") as archive:
            self.assertEqual(self.round_bytes, archive.extractfile(f"{prefix}/example-round-000.json").read())
            metadata = archive.extractfile(f"{prefix}/metadata.json").read().decode()
            checksums = archive.extractfile(f"{prefix}/SHA256SUMS").read().decode()
        self.assertNotIn(str(run.ROOT.resolve()), metadata)
        self.assertIn("$REPO/zig-out/bin/home-tsc", metadata)
        self.assertIn(hashlib.sha256(self.round_bytes).hexdigest(), checksums)

    def test_incomplete_result_is_not_packaged(self):
        (self.source / "example-round-000.json").unlink()
        with self.assertRaisesRegex(SystemExit, "incomplete or unverified"):
            run.cmd_evidence(self.source, self.root / "evidence.tar.gz")


class HostMetadataTests(unittest.TestCase):
    def test_macos_host_records_cpu_machine_and_core_count(self):
        values = {"machdep.cpu.brand_string": "Apple M3 Pro", "hw.model": "Mac14,9"}
        with mock.patch.object(run.platform, "system", return_value="Darwin"), mock.patch.object(
            run.platform, "release", return_value="25.3.0"
        ), mock.patch.object(run.platform, "machine", return_value="arm64"), mock.patch.object(
            run.os, "cpu_count", return_value=10
        ), mock.patch.object(run, "sysctl_value", side_effect=lambda name: values.get(name)):
            self.assertEqual(
                {
                    "os": "Darwin",
                    "os_release": "25.3.0",
                    "architecture": "arm64",
                    "cpu_model": "Apple M3 Pro",
                    "logical_cores": 10,
                    "machine_model": "Mac14,9",
                },
                run.host_metadata(),
            )

    def test_missing_core_count_stops_before_measurement(self):
        with mock.patch.object(run.os, "cpu_count", return_value=None):
            with self.assertRaisesRegex(SystemExit, "logical core count"):
                run.host_metadata()


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tsc_tools = self.root / "tsc"
        self.tsgo_tools = self.root / "tsgo"
        self.tsc_payload = self.tsc_tools / "node_modules/typescript/lib/_tsc.js"
        self.tsgo_payload = self.tsgo_tools / "node_modules/@typescript/typescript-linux-x64/lib/tsc"
        self.tsc_wrapper = self.tsc_tools / "node_modules/typescript/bin/tsc"
        self.tsc_launcher = self.tsc_tools / "node_modules/.bin/tsc"
        self.tsgo_launcher = self.tsgo_tools / "node_modules/typescript/bin/tsc"
        self.home = self.root / "home-tsc"
        self.node = self.root / "node"
        self.hyperfine = self.root / "hyperfine"
        self.python = self.root / "python3"
        for path, content in (
            (self.tsc_payload, b"javascript compiler"),
            (self.tsgo_payload, b"native compiler"),
            (self.tsc_wrapper, b"tsc wrapper"),
            (self.tsgo_launcher, b"tsgo wrapper"),
            (self.home, b"home compiler"),
            (self.node, b"node runtime"),
            (self.hyperfine, b"hyperfine runtime"),
            (self.python, b"python runtime"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.tsc_launcher.parent.mkdir(parents=True, exist_ok=True)
        self.tsc_launcher.symlink_to(self.tsc_wrapper)
        self.commands = {
            "tsc": [str(self.tsc_launcher)],
            "tsgo": [str(self.tsgo_launcher)],
            "home": [str(self.home)],
        }

    def test_records_resolved_launchers_and_real_payloads(self):
        tools = {"node": self.node, "hyperfine": self.hyperfine}
        with mock.patch.object(run, "TSC_TOOLS", self.tsc_tools), mock.patch.object(
            run, "TSGO_TOOLS", self.tsgo_tools
        ), mock.patch.object(run.platform, "system", return_value="Linux"), mock.patch.object(
            run.platform, "machine", return_value="x86_64"
        ), mock.patch.object(run, "resolved_tool", side_effect=lambda name: tools[name]), mock.patch.object(
            run, "version_output", side_effect=lambda command: f"Version for {Path(command[0]).name}"
        ), mock.patch.object(run.sys, "executable", str(self.python)):
            provenance = run.benchmark_provenance(self.commands)

        compilers = provenance["compilers"]
        self.assertEqual(str(self.tsc_wrapper.resolve()), compilers["tsc"]["launcher"]["resolved_path"])
        self.assertEqual(str(self.tsc_payload.resolve()), compilers["tsc"]["payload"]["resolved_path"])
        self.assertEqual(str(self.tsgo_payload.resolve()), compilers["tsgo"]["payload"]["resolved_path"])
        self.assertEqual(run.sha256_file(self.home), compilers["home"]["executable"]["sha256"])
        self.assertNotEqual(compilers["tsgo"]["launcher"]["sha256"], compilers["tsgo"]["payload"]["sha256"])

    def test_admission_artifact_change_stops_before_result_creation(self):
        results = self.root / "changed-admission-results"
        with mock.patch.object(run, "selected_workloads", return_value=["example"]), mock.patch.object(
            run.shutil, "which", return_value="hyperfine"
        ), mock.patch.object(run, "CORPUS") as corpus, mock.patch.object(
            run, "compiler_commands", return_value=self.commands
        ), mock.patch.object(run, "verified_compiler_versions", return_value={}), mock.patch.object(
            run, "benchmark_provenance", side_effect=[{"hash": "before"}, {"hash": "after"}]
        ), mock.patch.object(run, "validate"), mock.patch.object(run, "RESULTS", results):
            corpus.is_dir.return_value = True
            with self.assertRaisesRegex(SystemExit, "changed during admission"):
                run.cmd_cold(1, 0)
            self.assertEqual([], list(results.glob("*/metadata.json")))
            failures = list((results / "admission").glob("*.json"))
            self.assertEqual(1, len(failures))
            self.assertFalse(json.loads(failures[0].read_text())["passed"])

    def test_measurement_artifact_change_is_retained_but_not_verified(self):
        results = self.root / "results"
        corpus = self.root / "corpus"
        corpus.mkdir()
        before = {"hash": "before"}
        after = {"hash": "after"}
        with mock.patch.object(run, "selected_workloads", return_value=["example"]), mock.patch.object(
            run.shutil, "which", return_value="hyperfine"
        ), mock.patch.object(run, "CORPUS", corpus), mock.patch.object(
            run, "RESULTS", results
        ), mock.patch.object(run, "compiler_commands", return_value=self.commands), mock.patch.object(
            run, "verified_compiler_versions", return_value={name: name for name in self.commands}
        ), mock.patch.object(run, "benchmark_provenance", side_effect=[before, before, after]), mock.patch.object(
            run, "validate"
        ), mock.patch.object(run, "host_metadata", return_value={
            "os": "TestOS", "os_release": "1", "architecture": "test-machine",
            "cpu_model": "test-processor", "logical_cores": 4,
        }), mock.patch.object(run.platform, "platform", return_value="test-system"), mock.patch.object(
            run.platform, "machine", return_value="test-machine"
        ), mock.patch.object(run.platform, "processor", return_value="test-processor"), mock.patch.object(
            run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)
        ):
            with self.assertRaisesRegex(SystemExit, "changed during measurement"):
                run.cmd_cold(1, 0)

        directories = [path for path in results.iterdir() if path.name != "admission"]
        self.assertEqual(1, len(directories))
        metadata = run.json.loads((directories[0] / "metadata.json").read_text(encoding="utf-8"))
        self.assertEqual("changed", metadata["provenance"]["status"])
        self.assertEqual(2, metadata["schema"])
        self.assertEqual(4, metadata["host"]["logical_cores"])
        self.assertEqual(before, metadata["provenance"]["before"])
        self.assertEqual(after, metadata["provenance"]["after"])


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

class CommonJsGraphWorkloadTests(unittest.TestCase):
    def setUp(self):
        config = {"generated": {"commonjs_graph_families": 128}}
        patcher = mock.patch.object(run, "manifest", return_value=config)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_generator_retains_real_edges_unions_and_typed_consumption(self):
        with mock.patch.object(run, "write") as write:
            run.generate_commonjs_graph(run.Path("project"), 3)
        sources = {str(call.args[0]): call.args[1] for call in write.call_args_list}
        app = sources["project/src/index.js"]
        for index in range(3):
            owner = sources[f"project/src/owner-{index:04d}.js"]
            self.assertIn(f"module.exports = new Service{index}()", owner)
            self.assertIn(f"module.exports = new Alternate{index}()", owner)
            self.assertIn(f'require("./owner-{index:04d}")', app)
            self.assertIn(f"service{index}.meta.active", app)
            self.assertIn(f"string | number}} */ const label{index}", app)
        with self.assertRaises(ValueError):
            run.generate_commonjs_graph(run.Path("project"), 0)

    def test_negative_controls_append_to_copy_and_cover_first_middle_last(self):
        complete = "error TS2322: wrong\n" * 3 + "error TS2339: missing\n" * 3
        with mock.patch.object(run.shutil, "copytree") as copy, mock.patch.object(
            run.Path, "read_text", return_value="original source\n"
        ), mock.patch.object(run, "write") as write, mock.patch.object(
            run.subprocess, "run", return_value=subprocess.CompletedProcess([], 2, complete, "")
        ):
            run.validate_commonjs_graph_negatives({"home": ["home"]})
            self.assertEqual(run.CORPUS / "commonjs_graph", copy.call_args.args[0])
            self.assertNotEqual(run.CORPUS / "commonjs_graph/src/index.js", write.call_args.args[0])
            self.assertTrue(write.call_args.args[1].startswith("original source\n"))
            for index in (0, 64, 127):
                self.assertIn(f"service{index}.label", write.call_args.args[1])
                self.assertIn(f"service{index}.missing", write.call_args.args[1])

    def test_negative_controls_reject_partial_errors_acceptance_and_crashes(self):
        complete = "error TS2322: wrong\n" * 3 + "error TS2339: missing\n" * 3
        for code, output in ((0, ""), (0, complete), (1, "error TS2322: wrong\n"), (-11, complete), (3, complete)):
            with mock.patch.object(run.shutil, "copytree"), mock.patch.object(
                run.Path, "read_text", return_value="source\n"
            ), mock.patch.object(run, "write"), mock.patch.object(
                run.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")
            ):
                with self.assertRaisesRegex(SystemExit, "failed commonjs_graph negative controls"):
                    run.validate_commonjs_graph_negatives({"home": ["home"]})

    def test_positive_workload_requires_negative_admission(self):
        commands = {"home": ["home"]}
        with mock.patch.object(
            run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")
        ), mock.patch.object(run, "validate_commonjs_graph_negatives") as negatives:
            run.validate(commands, "commonjs_graph")
            negatives.assert_called_once_with(commands)


class CheckJsWorkloadTests(unittest.TestCase):
    def test_controls_append_only_and_cover_all_five_features_at_three_positions(self):
        complete = "error TS2322: wrong\n" * 9 + "error TS2339: missing\n" * 3 + "error TS2345: argument\n" * 3
        with mock.patch.object(run, "manifest", return_value={"generated": {"checkjs_jsdoc_families": 128}}), mock.patch.object(
            run.shutil, "copytree"
        ) as copy, mock.patch.object(run.Path, "read_text", return_value="original\n"), mock.patch.object(
            run, "write"
        ) as write, mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, complete, "")):
            trace = []
            run.validate_checkjs_jsdoc_negatives({"home": ["home"]}, trace=trace)
            self.assertEqual(run.CORPUS / "checkjs_jsdoc", copy.call_args.args[0])
            self.assertNotEqual(run.CORPUS / "checkjs_jsdoc/src/checkjs-jsdoc.js", write.call_args.args[0])
            source = write.call_args.args[1]
            self.assertTrue(source.startswith("original\n"))
            for index in (0, 64, 127):
                for token in (f"preserved{index}.id", f"preserved{index}.missing", f"project{index}(model{index})",
                              f"store{index}.read(123)", f"Box{index}<Model{index}>"):
                    self.assertIn(token, source)
            self.assertEqual(15, len(trace[0]["expected_codes"]))
            self.assertTrue(trace[0]["passed"])

    def test_controls_reject_partial_diagnostics_silent_success_and_abnormal_exits(self):
        complete = "error TS2322: wrong\n" * 9 + "error TS2339: missing\n" * 3 + "error TS2345: argument\n" * 3
        for code, output in ((0, ""), (0, complete), (1, "error TS2322: wrong\n"), (-11, complete), (3, complete)):
            with mock.patch.object(run, "manifest", return_value={"generated": {"checkjs_jsdoc_families": 128}}), mock.patch.object(
                run.shutil, "copytree"
            ), mock.patch.object(run.Path, "read_text", return_value="original\n"), mock.patch.object(
                run, "write"
            ), mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")):
                with self.assertRaisesRegex(SystemExit, "failed checkjs_jsdoc negative controls"):
                    run.validate_checkjs_jsdoc_negatives({"home": ["home"]})

    def test_positive_jsdoc_cannot_skip_negative_admission(self):
        with mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), mock.patch.object(
            run, "validate_checkjs_jsdoc_negatives"
        ) as negative:
            run.validate({"home": ["home"]}, "checkjs_jsdoc")
            negative.assert_called_once_with({"home": ["home"]})


class NullSafeWorkloadTests(unittest.TestCase):
    def fixture(self, root):
        corpus = root / "corpus"
        run.generate_null_safe_access(corpus / "null_safe_access", 5)
        return corpus

    def test_controls_check_inferred_locals_at_three_positions_without_changing_timed_source(self):
        complete = "error TS2322: wrong\n" * 18 + "error TS2339: missing\n" * 3 + "error TS2345: argument\n" * 3 + "error TS2493: bounds\n" * 3
        with tempfile.TemporaryDirectory() as temporary:
            corpus = self.fixture(Path(temporary))
            source = corpus / "null_safe_access/src/null-safe-access.ts"
            before = source.read_bytes()
            writes = []
            original_write = run.write

            def retain_write(path, content):
                writes.append((path, content))
                original_write(path, content)

            with mock.patch.object(run, "CORPUS", corpus), mock.patch.object(
                run, "manifest", return_value={"generated": {"null_safe_access_families": 5}}
            ), mock.patch.object(run, "write", side_effect=retain_write), mock.patch.object(
                run.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, complete, "")
            ):
                trace = []
                run.validate_null_safe_access_negatives({"home": ["home"]}, trace=trace)
            self.assertEqual(before, source.read_bytes())
            self.assertEqual(1, len(writes))
            self.assertNotEqual(source, writes[0][0])
            content = writes[0][1]
            for index in (0, 2, 4):
                body = content.split(f"function readNullable{index}(", 1)[1].split(f"const nullableInput{index}", 1)[0]
                for token in ("invalidLabel: boolean = label", "invalidScore: string = score",
                              "invalidFormatted: number = formatted", "invalidFallback: number = value!.fallback",
                              "invalidOptionalLabel: string = value?.profile?.label",
                              "invalidOptionalCall: string = value?.profile?.format?.(label)",
                              "format?.(123)", "metrics?.[2]", "profile?.missing"):
                    self.assertIn(token, body)
            self.assertEqual(27, len(trace[0]["expected_codes"]))
            self.assertTrue(trace[0]["passed"])

    def test_controls_reject_partial_diagnostics_silent_success_and_abnormal_exits(self):
        complete = "error TS2322: wrong\n" * 18 + "error TS2339: missing\n" * 3 + "error TS2345: argument\n" * 3 + "error TS2493: bounds\n" * 3
        with tempfile.TemporaryDirectory() as temporary:
            corpus = self.fixture(Path(temporary))
            for code, output in ((0, ""), (0, complete), (1, "error TS2322: wrong\n"), (-11, complete), (3, complete)):
                with self.subTest(code=code, output=output), mock.patch.object(run, "CORPUS", corpus), mock.patch.object(
                    run, "manifest", return_value={"generated": {"null_safe_access_families": 5}}
                ), mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")):
                    with self.assertRaisesRegex(SystemExit, "failed null_safe_access negative controls"):
                        run.validate_null_safe_access_negatives({"home": ["home"]})

    def test_positive_nullsafe_cannot_skip_negative_admission(self):
        with mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), mock.patch.object(
            run, "validate_null_safe_access_negatives"
        ) as negative:
            run.validate({"home": ["home"]}, "null_safe_access")
            negative.assert_called_once_with({"home": ["home"]})

    def test_missing_source_anchor_fails_before_compiler_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            corpus = self.fixture(Path(temporary))
            source = corpus / "null_safe_access/src/null-safe-access.ts"
            source.write_text("export const unrelated = 1;\n")
            with mock.patch.object(run, "CORPUS", corpus), mock.patch.object(
                run, "manifest", return_value={"generated": {"null_safe_access_families": 5}}
            ), mock.patch.object(run.subprocess, "run") as execute:
                with self.assertRaises(ValueError):
                    run.validate_null_safe_access_negatives({"home": ["home"]})
                execute.assert_not_called()


class AdmissionTests(unittest.TestCase):
    def test_predicate_and_destructuring_controls_require_normal_diagnostic_exit(self):
        families = (
            ("type_predicates", "  if (isReady0(value)) {\n  assertReady0(value);\n", ["2322"] * 2 + ["2339"] * 2),
            ("type_predicates_large", "  if (isReady0(value)) {\n  assertReady0(value);\n", ["2322"] * 2 + ["2339"] * 2),
            ("destructuring", "function projectBindings0(input: BindingRecord0): BindingProjection0 {\n"
             "  const { meta: { label, score }, slots: [first, second], active = true, ...identity } = input;\n",
             ["2322"] * 4 + ["2339"]),
        )
        for workload, source, codes in families:
            diagnostics = "".join(f"error TS{code}: invalid control\n" for code in codes)
            for status in (0, 1, 2, 3, 124, -6, -11):
                for output in (diagnostics, "error TS2322: incomplete\n", ""):
                    with self.subTest(workload=workload, status=status, output=output), mock.patch.object(
                        run.shutil, "copytree"
                    ), mock.patch.object(run.Path, "read_text", return_value=source), mock.patch.object(
                        run, "write"
                    ), mock.patch.object(run.subprocess, "run", return_value=subprocess.CompletedProcess([], status, output, "")):
                        def validate():
                            if workload == "destructuring":
                                run.validate_destructuring_negatives({"home": ["home"]})
                            else:
                                run.validate_type_predicate_negatives({"home": ["home"]}, workload)

                        if status in (1, 2) and output == diagnostics:
                            validate()
                        else:
                            with self.assertRaisesRegex(SystemExit, f"failed {workload} negative controls"):
                                validate()

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
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(run, "selected_workloads", return_value=["first", "second"]), mock.patch.object(
            run.shutil, "which", return_value="hyperfine"
        ), mock.patch.object(run, "CORPUS"), mock.patch.object(run, "compiler_commands", return_value={}), mock.patch.object(
            run, "verified_compiler_versions", return_value={}
        ), mock.patch.object(run, "benchmark_provenance", return_value={}
        ), mock.patch.object(run, "validate", side_effect=[None, SystemExit("admission failed")]) as validate, mock.patch.object(
            run, "RESULTS", Path(temporary) / "results"
        ), mock.patch.object(run.subprocess, "run") as process:
            with self.assertRaisesRegex(SystemExit, "admission failed"):
                run.cmd_cold(30, 3)
            self.assertEqual([mock.call({}, "first", profiles={}, trace=[]), mock.call({}, "second", profiles={}, trace=[])], validate.call_args_list)
            self.assertEqual([], list((Path(temporary) / "results").glob("*/metadata.json")))
            failures = list((Path(temporary) / "results/admission").glob("*.json"))
            self.assertEqual(1, len(failures))
            self.assertFalse(json.loads(failures[0].read_text())["passed"])
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
