"""Container benchmark wiring regressions for #464."""

import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


class ContainerHarnessTests(unittest.TestCase):
    def test_image_pins_node_hyperfine_and_download_hashes(self):
        dockerfile = (HERE / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("node:24.18.0-bookworm-slim@sha256:", dockerfile)
        self.assertIn("ARG HYPERFINE_VERSION=1.20.0", dockerfile)
        self.assertIn("hyperfine_sha256=", dockerfile)
        self.assertIn("sha256sum -c -", dockerfile)
        self.assertNotIn("releases/latest", dockerfile)
        self.assertNotIn("|| echo", dockerfile)
        self.assertNotIn("typescript@5.6.3", dockerfile)
        self.assertNotIn("pantry install", dockerfile)

    def test_entrypoint_uses_manifest_setup_and_fails_without_home(self):
        entrypoint = (HERE / "container-entrypoint.sh").read_text(encoding="utf-8")
        self.assertIn('python3 "$runner" setup', entrypoint)
        self.assertIn('python3 "$runner" corpus', entrypoint)
        self.assertIn('if [ ! -x "$home_compiler" ]', entrypoint)
        self.assertIn('exec python3 "$runner" "$@"', entrypoint)
        self.assertNotIn("typescript@", entrypoint)

    def test_workflow_builds_native_release_and_uses_root_context(self):
        workflow = (ROOT / ".github/workflows/ts-frontend-bench.yml").read_text(encoding="utf-8")
        self.assertIn("zig build home-tsc -Doptimize=ReleaseFast", workflow)
        self.assertIn("docker build -f bench/vs_tsgo/Dockerfile", workflow)
        self.assertIn("home-ts-frontend-bench .", workflow)
        self.assertIn("cold --runs 30 --warmup 3", workflow)
        self.assertIn("actions/upload-artifact@v4", workflow)

    def test_root_context_sends_only_the_container_entrypoint(self):
        dockerignore = (ROOT / ".dockerignore").read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            dockerignore,
            [
                "**",
                "!bench/",
                "!bench/vs_tsgo/",
                "!bench/vs_tsgo/container-entrypoint.sh",
            ],
        )


if __name__ == "__main__":
    unittest.main()
