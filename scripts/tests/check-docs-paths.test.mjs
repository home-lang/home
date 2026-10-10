import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { checkDocsPaths, findPersonalHomePaths } from "../check-docs-paths.mjs";

describe("documentation path policy", () => {
  test("rejects contributor-specific macOS, Linux, and Windows homes", () => {
    const source = [
      "macOS: /Users/alice/Code/home",
      "Linux: /home/alice/src/home",
      String.raw`Windows: C:\Users\Alice\Code\home`,
    ].join("\n");

    expect(findPersonalHomePaths(source).map((violation) => violation.path)).toEqual([
      "/Users/alice",
      "/home/alice",
      String.raw`C:\Users\Alice`,
    ]);
  });

  test("allows portable placeholders, URLs, and repository-relative paths", () => {
    const source = [
      "/Users/username/Code/home",
      "/Users/.../Code/home",
      "/home/user/projects/home",
      "https://github.com/home-lang/home/issues/836",
      "../home/packages/parser",
      "packages/runtime/src/home/server",
    ].join("\n");

    expect(findPersonalHomePaths(source)).toEqual([]);
  });

  test("keeps the published documentation corpus portable", () => {
    const root = resolve(import.meta.dir, "../..");
    const result = checkDocsPaths(root);

    expect(result.files.length).toBeGreaterThan(10);
    expect(
      result.files.some((file) => file.endsWith("bun-native-create-accounting-baseline.json")),
    ).toBeTrue();
    expect(result.violations).toEqual([]);
  });

  test("fails the command when a leaked home path reaches JSON documentation", () => {
    const temporary = mkdtempSync(join(tmpdir(), "home-doc-paths-"));
    try {
      mkdirSync(join(temporary, "docs"));
      writeFileSync(join(temporary, "docs", "leak.json"), '{"root":"/Users/alice/Code/home"}\n');

      const command = Bun.spawnSync([
        process.execPath,
        resolve(import.meta.dir, "../check-docs-paths.mjs"),
        temporary,
      ]);

      expect(command.exitCode).toBe(1);
      expect(command.stderr.toString()).toContain("docs/leak.json:1:10 contains /Users/alice");
    } finally {
      rmSync(temporary, { force: true, recursive: true });
    }
  });
});
