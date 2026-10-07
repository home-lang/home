import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const temporaryDirectories = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("exact TypeScript conformance runner", () => {
  test("runs only the opt-in corpus test for each bounded slice", () => {
    const temporary = mkdtempSync(join(tmpdir(), "home-ts-conformance-exact-"));
    temporaryDirectories.push(temporary);

    const log = join(temporary, "calls.jsonl");
    const zig = join(temporary, "zig-stub.mjs");
    writeFileSync(
      zig,
      `#!/usr/bin/env bun
import { appendFileSync } from "node:fs";

appendFileSync(process.env.TS_EXACT_LOG, JSON.stringify({
  args: process.argv.slice(2),
  limit: process.env.HOME_TS_CONFORMANCE_LIMIT,
  maxMb: process.env.HOME_RUN_MAX_MB,
  start: process.env.HOME_TS_CONFORMANCE_START,
}) + "\\n");
`,
    );
    chmodSync(zig, 0o755);

    const command = Bun.spawnSync(
      [resolve(import.meta.dir, "../ts-conformance-exact.sh"), "5", "10", "2"],
      {
        cwd: resolve(import.meta.dir, "../.."),
        env: {
          ...process.env,
          HOME_RUN_MAX_MB: "512",
          HOME_TS_CONFORMANCE_TIMEOUT_SECONDS: "30",
          TS_EXACT_LOG: log,
          ZIG_BIN: zig,
        },
      },
    );

    expect(command.exitCode).toBe(0);
    expect(command.stderr.toString()).toBe("");
    expect(command.stdout.toString()).toContain("START=5 LIMIT=2");
    expect(command.stdout.toString()).toContain("START=7 LIMIT=2");
    expect(command.stdout.toString()).toContain("START=9 LIMIT=1");

    const calls = readFileSync(log, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(calls).toEqual([
      {
        args: [
          "build",
          "test",
          "-Dfilter=ts_conformance",
          "-Dts-conformance-test-filter=conformance: opt-in full local TypeScript corpus survey",
        ],
        limit: "2",
        maxMb: "512",
        start: "5",
      },
      {
        args: [
          "build",
          "test",
          "-Dfilter=ts_conformance",
          "-Dts-conformance-test-filter=conformance: opt-in full local TypeScript corpus survey",
        ],
        limit: "2",
        maxMb: "512",
        start: "7",
      },
      {
        args: [
          "build",
          "test",
          "-Dfilter=ts_conformance",
          "-Dts-conformance-test-filter=conformance: opt-in full local TypeScript corpus survey",
        ],
        limit: "1",
        maxMb: "512",
        start: "9",
      },
    ]);
  });
});
