// Copied from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: test/bundler/transpiler/transpiler-stack-overflow.test.ts
// See LICENSE.bun.md for full license text.
import { expect, test } from "bun:test";
import { bunEnv, bunExe, tmpdirSync } from "harness";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "path";

test("long chain of expressions does not cause stack overflow", () => {
  const chain = `globalThis.a = {};` + "\n" + `globalThis.a + globalThis.a +`.repeat(1000000) + `globalThis.a` + "\n";
  const temp_dir = tmpdirSync();
  mkdirSync(temp_dir, { recursive: true });
  writeFileSync(join(temp_dir, "index.js"), chain, "utf-8");
  const { exitCode } = Bun.spawnSync({
    cmd: [bunExe(), "build", "--no-bundle", join(temp_dir, "index.js")],
    cwd: import.meta.dir,
    env: bunEnv,
    stderr: "inherit",
    stdout: Bun.file("/dev/null"),
    stdin: Bun.file("/dev/null"),
  });

  expect(exitCode).toBe(0);
}, 1000000);
